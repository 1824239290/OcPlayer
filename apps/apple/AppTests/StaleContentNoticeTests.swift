@testable import OcPlayer
import CoreModel
import Foundation
import JellyfinKit
import XCTest

/// 「内容可能不是最新」这条提示的判定与文案。
///
/// 这个类型小，但它是**离线体验唯一的出口**——摆错了会变成「明明有网却说离线」
/// 或「断网了却什么都不说」，两条都让用户不知道该不该信眼前的内容。
@MainActor
final class StaleContentNoticeTests: XCTestCase {

    // MARK: - 文案

    func testOfflineWordingWithKnownTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let notice = StaleContentNotice(fetchedAt: now.addingTimeInterval(-180), causedByConnectivity: true)
        XCTAssertEqual(notice.text(now: now), "离线 · 数据更新于 3 分钟前")
    }

    /// 本会话拉过、但这次刷新没成功：不知道确切时间就别编一个，
    /// 说「正在显示已加载的内容」比「更新于 0 分钟前」诚实。
    func testOfflineWordingWithoutTimestamp() {
        let notice = StaleContentNotice(fetchedAt: nil, causedByConnectivity: true)
        XCTAssertEqual(notice.text(), "离线 · 正在显示已加载的内容")
    }

    /// **服务端答复了但出错（5xx / 401）时不许说「离线」**：那会把人引去查网络，
    /// 而问题在服务端。这是本类型存在的核心理由之一。
    func testServerErrorWordingDoesNotClaimOffline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let withDate = StaleContentNotice(fetchedAt: now.addingTimeInterval(-7200), causedByConnectivity: false)
        XCTAssertEqual(withDate.text(now: now), "内容可能不是最新 · 数据更新于 2 小时前")
        XCTAssertFalse(withDate.text(now: now).contains("离线"))

        let withoutDate = StaleContentNotice(fetchedAt: nil, causedByConnectivity: false)
        XCTAssertEqual(withoutDate.text(), "内容可能不是最新 · 刷新失败")
        XCTAssertFalse(withoutDate.text().contains("离线"))
    }

    func testRelativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func rel(_ seconds: TimeInterval) -> String {
            StaleContentNotice.relative(now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(rel(10), "刚刚")
        XCTAssertEqual(rel(59), "刚刚")
        XCTAssertEqual(rel(60), "1 分钟前")
        XCTAssertEqual(rel(3599), "59 分钟前")
        XCTAssertEqual(rel(3600), "1 小时前")
        XCTAssertEqual(rel(86_399), "23 小时前")
        XCTAssertEqual(rel(90_000), "昨天")
        XCTAssertEqual(rel(3 * 86_400), "3 天前")
    }

    /// 未来时间（时钟回拨 / 服务端时间偏）不能被算成负数。
    func testFutureTimestampClampsToJustNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(StaleContentNotice.relative(now.addingTimeInterval(3600), now: now), "刚刚")
    }

    // MARK: - 首页提示的判定

    private func makeHome(
        resume: [MediaItem] = [],
        error: String? = nil,
        cachedFetchedAt: Date? = nil,
        connectivity: Bool = false,
        isLoading: Bool = false
    ) -> AppModel.HomeData {
        var home = AppModel.HomeData()
        home.resume = resume
        home.error = error
        home.cachedFetchedAt = cachedFetchedAt
        home.refreshFailureWasConnectivity = connectivity
        home.isLoading = isLoading
        return home
    }

    /// 有内容 + 刷新失败（连不上）→ 提示「离线」。
    func testHomeNoticeAppearsWhenRefreshFailedWithCachedContent() {
        let app = AppModel()
        app.home = makeHome(resume: [MediaItem(id: "r1", name: "续播", kind: .movie)],
                            cachedFetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            connectivity: true)
        let notice = app.homeStaleNotice
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.causedByConnectivity == true)
        XCTAssertEqual(notice?.fetchedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// **断网冷启动**（有缓存内容 + 三条 rail 全挂 = `home.error` 也置位）时提示必须出现。
    ///
    /// 这是本判定最容易写错的一处：`home.error` 与「有内容」并不互斥——断网冷启动
    /// 正是「error 已置位、但页面靠磁盘缓存照常渲染」的形态（`HomeView` 只在
    /// `latest.isEmpty` 时才走错误页）。若用 `error == nil` 去 guard 这条提示，
    /// 结果就是**显示着缓存内容却一个字都不提示**，用户根本不知道这是旧数据。
    func testHomeNoticeShowsOnOfflineColdStartWithCachedContent() {
        let app = AppModel()
        app.home = makeHome(resume: [MediaItem(id: "r1", name: "续播", kind: .movie)],
                            error: "无法连接服务器",
                            connectivity: true)
        let notice = app.homeStaleNotice
        XCTAssertNotNil(notice, "有缓存内容时即使 error 置位也要提示")
        XCTAssertTrue(notice?.causedByConnectivity == true)
    }

    /// 而「什么都没拿到」时不该提示：那时页面走的是整页错误态，
    /// 再叠一条「离线 · 正在显示已加载的内容」会自相矛盾（没有内容可显示）。
    func testHomeNoticeHiddenWhenThereIsNothingToShow() {
        let app = AppModel()
        app.home = makeHome(error: "无法连接服务器", connectivity: true)
        XCTAssertNil(app.homeStaleNotice, "没有内容就没有可标注的对象")
    }

    /// 没有任何内容时不提示（此时页面是别的状态）。
    func testHomeNoticeSuppressedWithoutContent() {
        let app = AppModel()
        app.home = makeHome(cachedFetchedAt: Date(timeIntervalSince1970: 1_700_000_000), connectivity: true)
        let notice = app.homeStaleNotice
        XCTAssertNil(notice)
    }

    /// 还在首次加载（isLoading）时提示会闪一下，要 suppress。
    func testHomeNoticeSuppressedWhileLoading() {
        let app = AppModel()
        app.home = makeHome(resume: [MediaItem(id: "r1", name: "续播", kind: .movie)],
                            cachedFetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            connectivity: true, isLoading: true)
        let notice = app.homeStaleNotice
        XCTAssertNil(notice)
    }

    /// 内容全是本会话网络拉的、且没有失败过 → 不提示（这是正常状态）。
    func testHomeNoticeAbsentOnHealthySession() {
        let app = AppModel()
        app.home = makeHome(resume: [MediaItem(id: "r1", name: "续播", kind: .movie)])
        let notice = app.homeStaleNotice
        XCTAssertNil(notice)
    }

    // MARK: - 错误分类

    /// 「连不上」的两种 kind 判为离线；服务端答复的错误不算。
    func testConnectivityClassification() {
        XCTAssertTrue(JellyfinError(.noNetwork).isConnectivityFailure)
        XCTAssertTrue(JellyfinError(.serverUnreachable).isConnectivityFailure)
        XCTAssertFalse(JellyfinError(.http(status: 500)).isConnectivityFailure)
        XCTAssertFalse(JellyfinError(.unauthorized).isConnectivityFailure)
        XCTAssertFalse(JellyfinError(.forbidden).isConnectivityFailure)
        XCTAssertFalse(JellyfinError(.other("boom")).isConnectivityFailure)
    }
}
