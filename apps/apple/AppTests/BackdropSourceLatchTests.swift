import Foundation
@testable import OcPlayer
import XCTest

/// `BackdropSourceLatch`：详情页背景图的「先解析、再上屏、之后锁定」。
///
/// 背景（2026-11-03 实测）：进「赛博朋克：边缘行者」详情页，一屏里出现三张背景图，
/// URL 依次是 氛围池兜底图 → 服务端 backdrop → `image.tmdb.org`。第 2→3 次那下就是
/// 用户报的「闪另外一张背景图，感觉出来后马上被 tmdb 替代了」——TMDB 图片策略默认
/// 「优先顶替」，而 `tmdbOverlay` 是异步到的，于是详情内容先按服务端图上屏、
/// 随后被 TMDB 图顶掉。
///
/// 这组用例钉住状态机语义（纯值、不碰 SwiftUI、不碰网络）：
/// 解析前不锁、解析后第一张非空图锁定、空结果不锁、宽度档互不顶替。
final class BackdropSourceLatchTests: XCTestCase {

    private let serverURL = URL(string: "http://stub.local/Items/a/Images/Backdrop?maxWidth=800")!
    private let tmdbURL = URL(string: "https://image.tmdb.org/t/p/w1280/p.jpg")!

    private func target(_ url: URL?, _ header: String? = nil) -> BackdropSourceLatch.Target {
        BackdropSourceLatch.Target(url: url, authHeader: header)
    }

    /// 解析前：**一律返回空**，不现算、不写锁定表。
    ///
    /// 这条是「闪图」真正的第二道防线：`DetailView.task` 里 `attach(app)` 是同步的、
    /// `load()` 的第一个 await 才去读 overlay，两者之间视图会渲染——若那时现算，
    /// 得到的就是「服务端图」并被真的画到屏幕上，overlay 回来后换成 TMDB 图，
    /// 用户依然看到一次顶替。返回空让视图回落氛围池兜底图（背景延续设计）。
    func testReturnsEmptyBeforeResolved() {
        var latch = BackdropSourceLatch()
        var calls = 0

        func resolve() -> BackdropSourceLatch.Target {
            calls += 1
            return target(serverURL, "Bearer t")
        }

        XCTAssertEqual(latch.target(for: 800, resolve: resolve), target(nil, nil),
                       "解析完成前不该把任何本条目自己的图交给视图")
        XCTAssertEqual(calls, 0, "解析前连现算都不该做")
        XCTAssertTrue(latch.locked.isEmpty)
        XCTAssertFalse(latch.isResolved)
    }

    /// 解析后的第一张非空图被锁定：之后 overlay 迟到（TMDB 图出现）也不改口。
    /// **这条就是「闪图」的回归用例**。
    func testFirstNonNilAfterResolveIsLocked() {
        var latch = BackdropSourceLatch()
        latch.markResolved()

        // 第一次：只有服务端图（overlay 还没到 / 没缓存）。
        let first = latch.target(for: 800) { self.target(self.serverURL, "Bearer t") }
        XCTAssertEqual(first, target(serverURL, "Bearer t"))

        // 第二次：TMDB overlay 到了，现算规则会给出 TMDB 图 —— 但必须仍然返回旧图。
        let second = latch.target(for: 800) { self.target(self.tmdbURL, nil) }
        XCTAssertEqual(second, target(serverURL, "Bearer t"), "锁定后不得中途换图")
        XCTAssertEqual(latch.locked[800], target(serverURL, "Bearer t"))
    }

    /// 解析完成但当时没有图（详情未落地）：不锁 nil，之后补上的图仍然能出。
    func testNilResultIsNotLocked() {
        var latch = BackdropSourceLatch()
        latch.markResolved()

        XCTAssertEqual(latch.target(for: 800) { self.target(nil, nil) }, target(nil, nil))
        XCTAssertTrue(latch.locked.isEmpty, "空结果不该进锁定表")

        let later = latch.target(for: 800) { self.target(self.serverURL, "Bearer t") }
        XCTAssertEqual(later, target(serverURL, "Bearer t"), "详情落地后应当出图")
        XCTAssertEqual(latch.locked[800], target(serverURL, "Bearer t"))
    }

    /// 宽度档互相独立：清晰层（1600）与模糊层（800）是两个 URL，不能互相顶替。
    func testWidthBucketsAreIndependent() {
        var latch = BackdropSourceLatch()
        latch.markResolved()

        let blur = latch.target(for: 800) { self.target(URL(string: "http://stub.local/b800")!, nil) }
        let sharp = latch.target(for: 1600) { self.target(URL(string: "http://stub.local/b1600")!, nil) }
        XCTAssertNotEqual(blur.url, sharp.url)

        // 各自锁定后仍互不影响。
        XCTAssertEqual(latch.target(for: 800) { self.target(self.tmdbURL, nil) }.url, blur.url)
        XCTAssertEqual(latch.target(for: 1600) { self.target(self.tmdbURL, nil) }.url, sharp.url)
    }

    /// 锁定是**每页**（每个 latch 实例）的事：重新进页会重新解析，命中缓存直接是 TMDB 图。
    func testLockIsPerPageInstance() {
        var firstVisit = BackdropSourceLatch()
        firstVisit.markResolved()
        XCTAssertEqual(
            firstVisit.target(for: 800) { self.target(self.serverURL, nil) }.url,
            serverURL)

        var secondVisit = BackdropSourceLatch()
        secondVisit.markResolved()
        XCTAssertEqual(
            secondVisit.target(for: 800) { self.target(self.tmdbURL, nil) }.url,
            tmdbURL,
            "下一次进页不该继承上一页的锁")
    }

    /// 凭证跟着锁定图一起锁：TMDB 图免鉴权（nil），服务端图带 token，不能串。
    /// 锁定后即便现算规则改口成 TMDB 图（应当无需凭证），返回的仍是**服务端那张**
    /// 及其凭证 —— 图与头必须同源，否则会把 token 发给 CDN 或反之。
    func testAuthHeaderLockedWithURL() {
        var latch = BackdropSourceLatch()
        latch.markResolved()

        let first = latch.target(for: 800) { self.target(self.serverURL, "Bearer t") }
        XCTAssertEqual(first.authHeader, "Bearer t")

        let second = latch.target(for: 800) { self.target(self.tmdbURL, nil) }
        XCTAssertEqual(second.url, serverURL, "锁定后仍是服务端那张")
        XCTAssertEqual(second.authHeader, "Bearer t", "凭证必须跟着锁定的图走，不能变成 TMDB 的 nil")
    }
}
