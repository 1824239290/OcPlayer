import Foundation
@testable import OcPlayer
import XCTest

/// 「打开播放源」失败的**分类**（L2）与它对换源的分派契约。
///
/// 这一层没有异步、没有宿主、没有内核：纯值进、纯值出。它要锁的是三件事：
/// 1. 每一类错误都能被分到正确的桶（分类错了，用户看到的是错的徽章）；
/// 2. `allowsSourceFailover` 的真值表（L1 自动换源就靠它分派：
///    `.auth` 换源无效、`.aborted` 换源违背用户意图）；
/// 3. `.aborted` 的重试语义（用户刚取消的东西不能被「重试」再拉起来）。
///
/// ## 判据自身的证伪方式
///
/// 把 `classify` 里「网络超时」的映射改成 `.format`，
/// `testNetworkTimeoutIsNeverClassifiedAsFormat` 与
/// `testClassifiesMessageTextIntoEveryKind` 必须同时变红。
/// 只断言「能分出六类」不够——那在映射写反时也能过。
final class PlaybackOpenErrorTests: XCTestCase {

    // MARK: - 分类：错误对象优先（domain + code）

    func testClassifiesNetworkErrorsFromErrorDomain() {
        let codes = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed,
        ]
        for code in codes {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(error), .network,
                "URLError code \(code) 应判 .network"
            )
        }
    }

    func testCancellationIsAbortedNotNetwork() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(PlaybackOpenErrorKind.classify(cancelled), .aborted)
        // 取消不是失败：既不重试，也不换源。
        XCTAssertFalse(PlaybackOpenErrorKind.aborted.isRetryable)
        XCTAssertFalse(PlaybackOpenErrorKind.aborted.allowsSourceFailover)
    }

    func testAuthenticationURLErrorIsAuth() {
        for code in [NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(PlaybackOpenErrorKind.classify(error), .auth, "code \(code) 应判 .auth")
        }
    }

    // MARK: - 分类：消息文本（当前生产路径主要走这条）

    /// 按桶分开断言，而不是塞进一个循环里。
    ///
    /// 原因：文本分类的缺口是**按词**漏的（实测已经漏过英文 `connection`、中文 `令牌`），
    /// 混在一个方法里时，一次只暴露第一个缺词，要跑 N 轮才能补齐 N 个洞。
    /// 分成 5 个方法后，一轮就能把所有缺词摊出来。
    func testClassifiesChineseNetworkMessages() {
        for message in ["连接媒体服务器超时", "网络不可用", "拒绝连接"] {
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(message: message), .network,
                "中文网络文案「\(message)」应判 .network"
            )
        }
    }

    func testClassifiesEnglishNetworkMessages() {
        for message in ["The network connection was lost", "request timed out", "host unreachable"] {
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(message: message), .network,
                "英文网络文案「\(message)」应判 .network"
            )
        }
    }

    func testClassifiesAuthMessages() {
        // 「令牌」中文这一侧曾经漏过：鉴权桶当时只有 401/403/鉴权/认证/token，没有「令牌」。
        for message in ["401 Unauthorized", "令牌已过期", "认证失败"] {
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(message: message), .auth,
                "鉴权文案「\(message)」应判 .auth"
            )
        }
    }

    func testClassifiesFormatMessages() {
        for message in ["无法解码：容器不受支持", "demux failed", "unsupported format"] {
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(message: message), .format,
                "格式文案「\(message)」应判 .format"
            )
        }
    }

    func testClassifiesServerMessages() {
        for message in ["服务器 503", "Internal Server Error"] {
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(message: message), .server,
                "服务端文案「\(message)」应判 .server"
            )
        }
    }

    func testClassifiesAbortedMessages() {
        for message in ["用户取消", "代次让位", "cancelled by user"] {
            XCTAssertEqual(
                PlaybackOpenErrorKind.classify(message: message), .aborted,
                "放弃文案「\(message)」应判 .aborted"
            )
        }
    }

    func testUnknownMessageFallsBackToUnknown() {
        XCTAssertEqual(PlaybackOpenErrorKind.classify(message: ""), .unknown)
        XCTAssertEqual(PlaybackOpenErrorKind.classify(message: "量子纠缠"), .unknown)
        // 归不出来时按可重试处理：宁可多试一次，不要卡死在未知。
        XCTAssertTrue(PlaybackOpenErrorKind.unknown.isRetryable)
    }

    // MARK: - 关键反例：这件事今晚定过判据，写进用例才不会再犯

    func testNetworkTimeoutIsNeverClassifiedAsFormat() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertNotEqual(
            PlaybackOpenErrorKind.classify(timedOut), .format,
            "把超时判成格式不支持，徽章会劝用户换内核，而真正该做的是换网/换源"
        )
        XCTAssertEqual(
            PlaybackOpenErrorKind.classify(message: "连接媒体服务器超时"), .network,
            "文案里带「超时」必须落在网络类，不能被后置的「格式」分支吃掉"
        )
    }

    // MARK: - L1 的分派契约

    func testFailoverDispatchTableIsTheDocumentedOne() {
        // 换源可能有效：多版本条目常常是不同路径/协议，一条通不了另一条常常通。
        XCTAssertTrue(PlaybackOpenErrorKind.network.allowsSourceFailover)
        XCTAssertTrue(PlaybackOpenErrorKind.format.allowsSourceFailover)
        XCTAssertTrue(PlaybackOpenErrorKind.server.allowsSourceFailover)
        XCTAssertTrue(PlaybackOpenErrorKind.unknown.allowsSourceFailover)
        // 换源无效或违背意图。
        XCTAssertFalse(PlaybackOpenErrorKind.auth.allowsSourceFailover)
        XCTAssertFalse(PlaybackOpenErrorKind.aborted.allowsSourceFailover)
    }

    func testRetryabilityExcludesOnlyAborted() {
        for kind in PlaybackOpenErrorKind.allCases {
            XCTAssertEqual(kind.isRetryable, kind != .aborted, "\(kind.rawValue) 的重试语义不对")
        }
    }

    // MARK: - 分类在界面上必须可见：标签互不相同

    func testTaxonomyIsTheSixDocumentedKinds() {
        XCTAssertEqual(
            Set(PlaybackOpenErrorKind.allCases.map(\.rawValue)),
            ["network", "format", "auth", "server", "aborted", "unknown"],
            "分类枚举变了就要同步更新分派与文案，这条是故意的硬约束"
        )
    }

    func testEveryKindHasDistinctNonEmptyLabel() {
        let labels = PlaybackOpenErrorKind.allCases.map(\.label)
        XCTAssertFalse(labels.contains(where: \.isEmpty), "每一类都要有可读标签")
        XCTAssertEqual(Set(labels).count, labels.count, "标签必须互不相同，否则界面分不出是哪一类")
    }

    // MARK: - 落进 setupError 的文案

    func testDecoratePrefixesLabelExceptUnknown() {
        XCTAssertEqual(
            PlaybackOpenErrorKind.network.decorate(rawMessage: "超时"),
            "网络：超时"
        )
        XCTAssertEqual(
            PlaybackOpenErrorKind.auth.decorate(rawMessage: "401"),
            "鉴权失败：401"
        )
        // .unknown 没提供任何信息，加前缀只是噪音。
        XCTAssertEqual(
            PlaybackOpenErrorKind.unknown.decorate(rawMessage: "量子纠缠"),
            "量子纠缠"
        )
    }
}
