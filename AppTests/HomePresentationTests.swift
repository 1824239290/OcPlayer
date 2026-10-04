import CoreModel
import Foundation
import JellyfinKit
@testable import OcPlayer
import XCTest

/// 首页三态判定（`AppModel.homePresentation`）。
///
/// 这个文件的存在理由是**一次真实事故**：判定原先内联在 `HomeView` 的 `if` 链里，
/// 用 `home.latest.isEmpty` 单独一条 rail 当「有没有内容」的判据。而服务器可以没有
/// 「最近添加」（`railPresence` 就是为它存在的），那种服务器上 `latest` 恒为空——
/// 于是**缓存已经把内容读进内存了，界面还是只转骨架屏**（用户实测离线冷启动：
/// 磁盘读出 resume=3 / nextUp=6，屏幕上却一直只有骨架）。判定留在视图里，
/// 这件事就没有任何用例挡得住。
@MainActor
final class HomePresentationTests: XCTestCase {

    private func makeHome(
        resume: [MediaItem] = [],
        nextUp: [MediaItem] = [],
        latest: [MediaItem] = [],
        isLoading: Bool = false,
        error: String? = nil
    ) -> AppModel.HomeData {
        var home = AppModel.HomeData()
        home.resume = resume
        home.nextUp = nextUp
        home.latest = latest
        home.isLoading = isLoading
        home.error = error
        return home
    }

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, kind: .movie)
    }

    // MARK: - 事故回归：有内容时永远显示内容

    /// **用户实测的那个场景**：磁盘缓存有内容 + 正在加载（网络在重试）+ 三条 rail
    /// 后来全挂。必须显示内容，不能是骨架屏、也不能是错误页。
    func testCachedContentWinsOverLoadingAndError() {
        let app = AppModel()
        // 关键：`latest` 为空——这台服务器没有「最近添加」，正是判据写错时踩的形态。
        app.home = makeHome(resume: [item("r1"), item("r2"), item("r3")],
                            nextUp: (0..<6).map { item("n\($0)") },
                            isLoading: true,
                            error: "无法连接服务器")

        XCTAssertEqual(app.homePresentation, .content,
                       "有缓存内容时必须显示内容——转骨架屏正是用户报的那个 bug")
    }

    /// 加载中但已有内容（磁盘预热刚填完、网络还在跑）→ 立刻显示内容，不闪骨架。
    func testCachedContentShowsImmediatelyWhileStillLoading() {
        let app = AppModel()
        app.home = makeHome(resume: [item("r1")], isLoading: true)
        XCTAssertEqual(app.homePresentation, .content)
    }

    /// 「只有继续观看有内容、最近添加为空」是这台服务器的常态形态，单独钉一次。
    func testContentWithEmptyLatestStillCounts() {
        let app = AppModel()
        app.home = makeHome(resume: [item("r1")])
        XCTAssertEqual(app.homePresentation, .content)
        XCTAssertTrue(app.hasAnyHomeContent)

        // 反过来：只有 nextUp 也算有内容。
        let onlyNextUp = AppModel()
        onlyNextUp.home = makeHome(nextUp: [item("n1")])
        XCTAssertEqual(onlyNextUp.homePresentation, .content)
    }

    // MARK: - 没有内容时的三态

    /// 全新安装 / 清了缓存 + 正在加载 → 骨架屏（原有行为）。
    func testLoadingShownOnlyWithoutContent() {
        let app = AppModel()
        app.home = makeHome(isLoading: true)
        XCTAssertEqual(app.homePresentation, .loading)
        XCTAssertFalse(app.hasAnyHomeContent)
    }

    /// 没有缓存 + 网络全挂 → 整页错误（原有行为，不该被这次改动弄丢）。
    func testErrorShownOnlyWithoutContent() {
        let app = AppModel()
        app.home = makeHome(error: "首页加载失败")
        XCTAssertEqual(app.homePresentation, .error("首页加载失败"))
    }

    /// 三条 rail 都成功返回空（空库 / 新服务器）→ 内容分支，由「暂无可展示内容」
    /// 空态承接，而不是错误页。
    func testEmptyLibraryFallsThroughToContent() {
        let app = AppModel()
        app.home = makeHome()
        XCTAssertEqual(app.homePresentation, .content)
    }

    /// 加载中**且**已经有错误、但没内容：先骨架（加载还没结束），
    /// 加载结束才轮错误页——顺序与原实现一致。
    func testLoadingPrecedesError() {
        let app = AppModel()
        app.home = makeHome(isLoading: true, error: "上一轮的错误")
        XCTAssertEqual(app.homePresentation, .loading)
    }

    // MARK: - 与离线提示的配合

    /// 有内容 + 刷新失败（连不上）→ 内容 + 离线提示，两者同时成立。
    func testContentPresentationPairsWithStaleNotice() {
        let app = AppModel()
        var home = makeHome(resume: [item("r1")], error: "无法连接服务器")
        home.cachedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        home.refreshFailureWasConnectivity = true
        app.home = home

        XCTAssertEqual(app.homePresentation, .content, "该显示内容")
        let notice = app.homeStaleNotice
        XCTAssertNotNil(notice, "该同时给出离线提示")
        XCTAssertTrue(notice?.causedByConnectivity == true)
    }
}
