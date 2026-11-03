import Foundation
import CoreModel
import JellyfinKit
@testable import OcPlayer
import XCTest

/// L1「多候选源 + 打开失败自动换源」的**决策层**契约。
///
/// 这里测的是 `AppModel.handlePlaybackOpenFailure` 这一个函数：它决定「换不换、换到哪条、
/// 换几次停」。控制器只负责把失败类别报上来（`onOpenFailure`），换源决策全在这一层，
/// 所以用例直接喂 `(requestID, kind)`，不经过内核与网络。
///
/// ## 为什么断言的是「新 request id + 新 sessionContext」而不是「uri 变了」
///
/// 换源必须重开一条请求：`mediaSourceID` 绑在 `sessionContext` 上，原地改 uri 会让
/// 进度上报写到上一条源——**这种错在测试里看不出来，只有换设备续播才暴露**。
/// 所以下面每条换源成功用例都同时断言 id 变了、新源的 `mediaSourceID` 正确。
///
/// ## 判据怎么被证伪
///
/// 把 `maximumSourceFailovers` 改大（或删掉上限判断），
/// `testExhaustingAlternatesStopsAtTheNamedLimit` 必须变红；
/// 把换源改成「原地复用旧 sessionContext」，`testFailoverUsesTheAlternateOwnSessionContext` 必须变红。
@MainActor
final class PlaybackSourceFailoverTests: XCTestCase {

    // MARK: - 夹具

    private func session(_ sourceID: String?) -> PlaybackSessionContext {
        PlaybackSessionContext(itemID: "episode-1", mediaSourceID: sourceID)
    }

    private func alternate(_ sourceID: String, uri: String? = nil) -> PlaybackAlternate {
        PlaybackAlternate(
            id: sourceID,
            label: "候选 \(sourceID)",
            uri: uri ?? "https://stub.local/\(sourceID).m3u8",
            authHeader: nil,
            sessionContext: PlaybackSessionContext(itemID: "episode-1", mediaSourceID: sourceID)
        )
    }

    private func request(
        uri: String = "https://stub.local/primary.m3u8",
        alternates: [PlaybackAlternate] = []
    ) -> PlaybackRequest {
        PlaybackRequest(
            title: "测试剧集",
            uri: uri,
            authHeader: nil,
            resumeSeconds: nil,
            sessionContext: PlaybackSessionContext(itemID: "episode-1", mediaSourceID: "primary"),
            alternates: alternates
        )
    }

    /// 造一个装好播放器的 AppModel：`playback` 是 weak，测试必须自己持强引用。
    private func makeApp(controller: PlaybackController) -> AppModel {
        let app = AppModel()
        app.playback = controller
        app.nowPlayingItem = MediaItem(id: "episode-1", name: "第一集", kind: .episode)
        return app
    }

    /// 换源决策把真正的开播丢回主队列，用例要放它跑一拍。
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    // MARK: - 单源 / 不换源

    func testSingleSourceFailureKeepsErrorStateAndRecordsOneAttempt() async {
        let controller = PlaybackController()
        let app = makeApp(controller: controller)
        let original = request(alternates: [])
        app.presentedPlayer = original

        app.handlePlaybackOpenFailure(requestID: original.id, kind: .network)
        await settle()

        XCTAssertEqual(app.sourceFailoverCount, 0, "没有候选源就不该计数")
        XCTAssertEqual(app.sourceFailoverAttempts.count, 1, "失败要记账，即便不换源")
        XCTAssertEqual(app.sourceFailoverAttempts.first?.kind, PlaybackOpenErrorKind.network)
        XCTAssertEqual(app.sourceFailoverAttempts.first?.sourceID, "primary")
        XCTAssertEqual(app.presentedPlayer?.id, original.id, "单源失败必须停在原请求的错误态")
    }

    func testAbortedFailureRecordsButDoesNotFailover() async {
        let controller = PlaybackController()
        let app = makeApp(controller: controller)
        let original = request(alternates: [alternate("alt-1")])
        app.presentedPlayer = original

        app.handlePlaybackOpenFailure(requestID: original.id, kind: .aborted)
        await settle()

        XCTAssertEqual(app.sourceFailoverCount, 0, "主动放弃（换片/取消）不许换源")
        XCTAssertEqual(app.presentedPlayer?.uri, original.uri)
        XCTAssertEqual(app.sourceFailoverAttempts.count, 1, "取消也要记账：它和「源有问题」是两件事")
    }

    func testFailureForAnotherRequestIsIgnored() async {
        let controller = PlaybackController()
        let app = makeApp(controller: controller)
        let original = request(alternates: [alternate("alt-1")])
        app.presentedPlayer = original

        app.handlePlaybackOpenFailure(requestID: UUID(), kind: .network)
        await settle()

        XCTAssertEqual(app.sourceFailoverCount, 0)
        XCTAssertTrue(app.sourceFailoverAttempts.isEmpty, "旧请求的失败与当前播放无关，不该记账")
        XCTAssertEqual(app.presentedPlayer?.id, original.id)
    }

    // MARK: - 换源成功路径

    func testFailoverUsesTheAlternateOwnSessionContext() async {
        let controller = PlaybackController()
        let app = makeApp(controller: controller)
        let alternate1 = alternate("alt-1")
        let alternate2 = alternate("alt-2")
        let original = request(alternates: [alternate1, alternate2])
        app.presentedPlayer = original

        app.handlePlaybackOpenFailure(requestID: original.id, kind: .network)
        await settle()

        let switched = try? XCTUnwrap(app.presentedPlayer)
        XCTAssertEqual(app.sourceFailoverCount, 1)
        XCTAssertNotEqual(switched?.id, original.id, "换源必须重开一条新请求，不能原地改 uri")
        XCTAssertEqual(switched?.uri, alternate1.uri)
        XCTAssertEqual(
            switched?.sessionContext?.mediaSourceID, "alt-1",
            "新请求必须带上新源自己的会话上下文，否则进度会写到上一条源"
        )
        XCTAssertEqual(switched?.alternates.count, 1, "剩下的候选要往下传，供下一次失败继续用")
        XCTAssertEqual(switched?.alternates.first?.id, "alt-2")
    }

    // MARK: - 上限与用尽

    func testExhaustingAlternatesStopsAtTheNamedLimit() async {
        let controller = PlaybackController()
        let app = makeApp(controller: controller)
        let candidates = (1...4).map { alternate("alt-\($0)") }
        app.presentedPlayer = request(alternates: candidates)

        // 反复制造失败，直到不再换源（上限或候选用尽）。
        var rounds = 0
        while rounds < 10, app.playback?.setupError == nil {
            guard let current = app.presentedPlayer else { break }
            app.handlePlaybackOpenFailure(requestID: current.id, kind: .network)
            await settle()
            rounds += 1
        }

        XCTAssertEqual(
            app.sourceFailoverCount, AppModel.maximumSourceFailovers,
            "换源次数必须停在上限（具名常量 \(AppModel.maximumSourceFailovers)），不能无限重试"
        )
        let summary = try? XCTUnwrap(app.playback?.setupError)
        XCTAssertTrue(
            summary?.contains("已试") == true,
            "用尽后必须说清「试过哪几条」，实际文案：\(summary ?? "nil")"
        )
        XCTAssertTrue(
            summary?.contains(PlaybackOpenErrorKind.network.label) == true,
            "文案要带错误类别，用户才能判断该重试还是换片"
        )
        XCTAssertEqual(app.playback?.setupErrorKind, PlaybackOpenErrorKind.network, "最后一次失败的类别要一并落下去")
        XCTAssertEqual(
            app.sourceFailoverAttempts.count, AppModel.maximumSourceFailovers + 1,
            "每次失败都要记账：3 次换源 + 1 次撞上限"
        )
    }

    func testAlternateWithoutSessionContextStopsInsteadOfReusingOldContext() async {
        let controller = PlaybackController()
        let app = makeApp(controller: controller)
        var broken = alternate("alt-1")
        broken = PlaybackAlternate(
            id: broken.id, label: broken.label, uri: broken.uri,
            authHeader: nil, sessionContext: nil
        )
        let original = request(alternates: [broken])
        app.presentedPlayer = original

        app.handlePlaybackOpenFailure(requestID: original.id, kind: .network)
        await settle()

        XCTAssertEqual(app.presentedPlayer?.id, original.id, "拿不到新源上下文时不许换源（宁可停在错误态）")
        XCTAssertNotNil(app.playback?.setupError, "这种情况要落错误态，不能安静地什么都不做")
        XCTAssertEqual(app.playback?.setupErrorKind, PlaybackOpenErrorKind.network)
    }
}
