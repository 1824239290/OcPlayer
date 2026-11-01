import XCTest
@testable import OcPlayer

/// `TorrentRevealWindow` 的语义钉子（纯值类型，不碰 UI）。
///
/// 窗口是「资源搜索列表物化多少条」的唯一判据，回归的表现是**静默的**：
/// 窗口算错只会让用户多滚一次、或者看到一行不该出现的「已展示 X / Y」。
/// 所以这里把每个边界都钉死。
final class TorrentRevealWindowTests: XCTestCase {

    // MARK: - 首窗

    func testInitialWindowIsOnePage() {
        let window = TorrentRevealWindow(pageSize: 60)
        XCTAssertEqual(window.shownCount(total: 1000), 60)
        XCTAssertEqual(window.shownCount(total: 30), 30, "结果不足一窗时只物化实际条数")
        XCTAssertEqual(window.shownCount(total: 0), 0)
    }

    func testDefaultPageSizeIsSixty() {
        XCTAssertEqual(TorrentRevealWindow.defaultPageSize, 60)
        XCTAssertEqual(TorrentRevealWindow().shownCount(total: 1000), 60)
    }

    // MARK: - 触底续载

    func testRevealAddsOnePage() {
        var window = TorrentRevealWindow(pageSize: 60)
        window.reveal(total: 1000)
        XCTAssertEqual(window.shownCount(total: 1000), 120)
        window.reveal(total: 1000)
        XCTAssertEqual(window.shownCount(total: 1000), 180)
    }

    func testRevealClampsToTotal() {
        var window = TorrentRevealWindow(pageSize: 60)
        window.reveal(total: 70)
        XCTAssertEqual(window.shownCount(total: 70), 70, "最后一窗按实际条数收口，不超出 total")
        XCTAssertFalse(window.hasMore(total: 70))
    }

    func testRevealIsNoOpWhenEverythingIsShown() {
        var window = TorrentRevealWindow(pageSize: 60)
        window.reveal(total: 70)
        let afterFirst = window.shownCount(total: 70)
        // 反复滚出/滚回 footer：不能越过数据上界，也不能把 limit 顶到天上去。
        for _ in 0..<5 { window.reveal(total: 70) }
        XCTAssertEqual(window.shownCount(total: 70), afterFirst)
        XCTAssertEqual(window.shownCount(total: 1000), 70, "窗口停在 70；数据变多后从这里继续走")
    }

    func testRevealOnEmptyDataDoesNothing() {
        var window = TorrentRevealWindow(pageSize: 60)
        window.reveal(total: 0)
        XCTAssertEqual(window.shownCount(total: 0), 0)
        XCTAssertFalse(window.hasMore(total: 0))
    }

    // MARK: - 收敛（筛选 / 排序 / 新批次）

    func testClampShrinksToTotalButKeepsOnePageFloor() {
        var window = TorrentRevealWindow(pageSize: 60)
        for _ in 0..<3 { window.reveal(total: 1000) }   // limit = 240
        window.clamp(total: 5)
        XCTAssertEqual(window.shownCount(total: 5), 5, "筛到只剩 5 条时只物化 5 条")
        XCTAssertEqual(window.limit, 60, "窗口不回落到一页以下——用户滚过的深度是他的记忆")
    }

    func testClampKeepsDeepWindowWhenDataStillLarge() {
        var window = TorrentRevealWindow(pageSize: 60)
        for _ in 0..<4 { window.reveal(total: 1000) }   // limit = 300
        window.clamp(total: 800)
        XCTAssertEqual(window.shownCount(total: 800), 300, "数据变少但仍比窗口大：窗口不动")
    }

    func testClampInteriorWhenTotalFallsBetweenRowsOfTheWindow() {
        var window = TorrentRevealWindow(pageSize: 60)
        for _ in 0..<4 { window.reveal(total: 1000) }   // limit = 300
        window.clamp(total: 200)
        XCTAssertEqual(window.shownCount(total: 200), 200)
        XCTAssertFalse(window.hasMore(total: 200))
    }

    func testClampNeverExceedsTotalOnEmptyData() {
        var window = TorrentRevealWindow(pageSize: 60)
        window.clamp(total: 0)
        XCTAssertEqual(window.shownCount(total: 0), 0)
        XCTAssertEqual(window.limit, 60)
    }

    // MARK: - 重置

    func testResetReturnsToFirstPage() {
        var window = TorrentRevealWindow(pageSize: 60)
        for _ in 0..<5 { window.reveal(total: 1000) }
        window.reset()
        XCTAssertEqual(window.shownCount(total: 1000), 60)
    }

    // MARK: - hasMore

    func testHasMoreMatchesVisibleProgress() {
        var window = TorrentRevealWindow(pageSize: 60)
        XCTAssertTrue(window.hasMore(total: 61))
        XCTAssertFalse(window.hasMore(total: 60))
        XCTAssertFalse(window.hasMore(total: 0))
        window.reveal(total: 61)
        XCTAssertFalse(window.hasMore(total: 61))
    }

    // MARK: - 垃圾入参

    func testNonPositivePageSizeFallsBackToOne() {
        let window = TorrentRevealWindow(pageSize: 0)
        XCTAssertEqual(window.shownCount(total: 10), 1, "0 会让窗口永远空转，兜底成 1")
    }

    func testNegativeTotalIsTreatedAsEmpty() {
        let window = TorrentRevealWindow(pageSize: 60)
        XCTAssertEqual(window.shownCount(total: -20), 0)
        XCTAssertFalse(window.hasMore(total: -20))
    }
}
