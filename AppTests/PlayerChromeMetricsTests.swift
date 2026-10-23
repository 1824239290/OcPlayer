import SwiftUI
import XCTest
@testable import OcPlayer

/// HUD 让位公式回归（灵动岛/圆角禁区适配）。
///
/// 最关键的属性：**横屏正常态（insets 全零）所有公式必须等于旧固定常量**——
/// 这是在无禁区机型/姿态上视觉零回归的保证；禁区出现时让位值按安全区平移。
final class PlayerChromeMetricsTests: XCTestCase {

    private let zero = EdgeInsets()

    // MARK: - 无系统禁区（回归保护）

    func testZeroInsetsKeepLegacyConstants() {
        XCTAssertEqual(PlayerChromeMetrics.topBarTopPadding(zero, isNarrow: true), 14)
        XCTAssertEqual(PlayerChromeMetrics.topBarTopPadding(zero, isNarrow: false), 22)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(zero, isNarrow: true), 16)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(zero, isNarrow: false), 28)
        XCTAssertEqual(PlayerChromeMetrics.infoPanelTopPadding(zero, isNarrow: true), 70)
        XCTAssertEqual(PlayerChromeMetrics.infoPanelTopPadding(zero, isNarrow: false), 82)
        XCTAssertEqual(PlayerChromeMetrics.osdTopPadding(zero), 14)
    }

    // MARK: - 竖屏灵动岛（顶部药丸带约 59pt）

    func testPortraitTopInsetShiftsTopAnchors() {
        // top 有禁区时顶部锚点平移让位量，呼吸间距保留。
        let portrait = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        XCTAssertEqual(PlayerChromeMetrics.topBarTopPadding(portrait, isNarrow: true), 73)
        XCTAssertEqual(PlayerChromeMetrics.topBarTopPadding(portrait, isNarrow: false), 81)
        XCTAssertEqual(PlayerChromeMetrics.infoPanelTopPadding(portrait, isNarrow: true), 129)
        XCTAssertEqual(PlayerChromeMetrics.infoPanelTopPadding(portrait, isNarrow: false), 141)
        XCTAssertEqual(PlayerChromeMetrics.osdTopPadding(portrait), 73)
        // 竖屏左右无禁区，水平边距维持原值。
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(portrait, isNarrow: true), 16)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(portrait, isNarrow: false), 28)
    }

    // MARK: - 横屏灵动岛（侧边禁区约 59pt，顶部归零）

    func testLandscapeSideInsetOnlyShiftsSideAnchors() {
        let landscape = EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(landscape, isNarrow: true), 59)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(landscape, isNarrow: false), 59)
        // 顶部归零：顶部锚点维持旧常量（横屏现状不回归）。
        XCTAssertEqual(PlayerChromeMetrics.topBarTopPadding(landscape, isNarrow: false), 22)
        XCTAssertEqual(PlayerChromeMetrics.infoPanelTopPadding(landscape, isNarrow: false), 82)
        XCTAssertEqual(PlayerChromeMetrics.osdTopPadding(landscape), 14)
    }

    // MARK: - 不对称侧边（转屏过渡 / 单侧禁区更宽的机型）

    func testSidePaddingTakesTheWiderSide() {
        let asymmetric = EdgeInsets(top: 0, leading: 47, bottom: 0, trailing: 62)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(asymmetric, isNarrow: false), 62)
        // 禁区比呼吸间距还窄时维持呼吸间距。
        let tiny = EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(tiny, isNarrow: false), 28)
    }

    // MARK: - 底部不进任何公式（契约钉死）

    /// home indicator 已被 `persistentSystemOverlays(.hidden)` 藏掉、无实体遮挡，
    /// 底部锚点维持原常量。钉死这一点，防将来「顺手」给底部也加让位造成双重让位。
    func testBottomInsetNeverEntersFormulas() {
        let bottomHeavy = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 0)
        XCTAssertEqual(PlayerChromeMetrics.topBarTopPadding(bottomHeavy, isNarrow: false), 22)
        XCTAssertEqual(PlayerChromeMetrics.sidePadding(bottomHeavy, isNarrow: false), 28)
        XCTAssertEqual(PlayerChromeMetrics.infoPanelTopPadding(bottomHeavy, isNarrow: false), 82)
        XCTAssertEqual(PlayerChromeMetrics.osdTopPadding(bottomHeavy), 14)
    }
}
