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
        // 「最近添加」是 16:9 横版、没有进度轨：比剧照栏矮一档，但装得下自己的
        // 卡片（16:9 图 + 10 间距 + 两行文案 ≈36pt）。
        XCTAssertEqual(
            Metrics.latestRailHeight(compact: true),
            Metrics.compactLatestWidth * 9 / 16 + 10 + 40 + Metrics.railHoverPadding * 2
        )
        XCTAssertLessThan(Metrics.latestRailHeight(compact: true), Metrics.stillRailHeight(compact: true))
        XCTAssertLessThan(Metrics.latestRailHeight(compact: false), Metrics.stillRailHeight(compact: false))
        let compactCard = Metrics.compactLatestWidth * 9 / 16 + 10 + 36
        XCTAssertLessThanOrEqual(compactCard + Metrics.railHoverPadding, Metrics.latestRailHeight(compact: true))
    }

    /// 栏位节奏的三个留白 token 是照着 Rex 的对照截图定的（见 `RailRhythmTests`）。
    /// 这条守住「别悄悄改回 28 / 24 / 14」——那组值会让首页栏位之间空出 60.5pt。
    func testRailRhythmTokensStayTight() {
        XCTAssertEqual(Metrics.railHoverPadding, 16)
        XCTAssertEqual(Metrics.railTopInset, 18)
        XCTAssertEqual(Metrics.railHeaderSpacing, 10)
        // 悬停抬升（×1.055）的余量：最高的常规海报卡（178 × 1.5）抬起来上下各多 7.4pt，
        // 悬停内边距至少要把这一份让出来，否则抬起时卡片会压到栏位标题上。
        XCTAssertGreaterThanOrEqual(Metrics.railHoverPadding, Metrics.posterWidth * 1.5 * 0.055 / 2)
    }

    func testUIStringsNonEmpty() {
        // 文案集中定义的兜底：空串漏配会让空态/重试按钮渲染成空白。
        for value in [UIStrings.loadFailed, UIStrings.retry, UIStrings.searchFailed, UIStrings.loadMore] {
            XCTAssertFalse(value.isEmpty)
        }
    }
}
