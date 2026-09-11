import XCTest
@testable import AppDesignKit

final class AppDesignKitTests: XCTestCase {
    func testRuntimeTextFormatting() {
        XCTAssertEqual(RuntimeText.format(87 * 60), "1 小时 27 分")
        XCTAssertEqual(RuntimeText.format(44 * 60), "44 分钟")
        XCTAssertEqual(RuntimeText.format(59 * 60), "59 分钟")
        XCTAssertEqual(RuntimeText.format(0), "1 分钟")
        XCTAssertEqual(RuntimeText.format(60 * 60), "1 小时 0 分")
    }

    func testRailHeightsFollowCardWidth() {
        // 海报轨高度必须跟着卡宽走（紧凑/常规两档），改 Metrics 时这里会炸。
        XCTAssertEqual(
            Metrics.posterRailHeight(compact: false),
            Metrics.posterWidth * 1.5 + 9 + 22 + Metrics.railHoverPadding * 2
        )
        XCTAssertEqual(
            Metrics.stillRailHeight(compact: true),
            Metrics.compactStillWidth * 9 / 16 + 6 + 3 + 10 + 40 + Metrics.railHoverPadding * 2
        )
    }

    func testUIStringsNonEmpty() {
        // 文案集中定义的兜底：空串漏配会让空态/重试按钮渲染成空白。
        for value in [UIStrings.loadFailed, UIStrings.retry, UIStrings.searchFailed, UIStrings.loadMore] {
            XCTAssertFalse(value.isEmpty)
        }
    }
}
