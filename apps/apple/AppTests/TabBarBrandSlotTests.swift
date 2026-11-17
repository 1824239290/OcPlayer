#if os(iOS)
import XCTest
@testable import OcPlayer

/// iOS 标签栏品牌图标接管层的**槽位匹配**（`TabBarBrandSlot`）。
///
/// `TabBarBrandIconBridge` 能换 `UITabBarItem` 的图，但 SwiftUI 没给 `Tab` 打标识的 API，
/// 唯一稳定的锚是标题；所以「哪些标题被接管」是这条路唯一脆的地方 —— 标题改一个字
/// （本地化、换词）不会报错，只会静默退回单色。这里把当前口径逐条钉住。
final class TabBarBrandSlotTests: XCTestCase {

    /// 三个被接管的标题（与 `AppShellView.compactTabs` 里写死的字符串一致）。
    func testKnownTitlesMapToTheirSlots() {
        XCTAssertEqual(TabBarBrandSlot.slot(forTitle: "首页"), .home)
        XCTAssertEqual(TabBarBrandSlot.slot(forTitle: "Bangumi"), .bangumi)
        XCTAssertEqual(TabBarBrandSlot.slot(forTitle: "MoviePilot"), .moviepilot)
    }

    /// 其余槽位（设置 / 搜索 / 空标题）**不接管**：它们的选中反馈继续走系统前景色亮暗。
    /// 大小写/拼写不同的标题也一律不认——宁可少改一格，也不能把设置齿轮换成品牌图。
    func testOtherTitlesAreLeftToTheSystem() {
        for title in ["设置", "搜索", "", "Home", "home", "bangumi", "Movie Pilot", "MoviePilot "] {
            XCTAssertNil(TabBarBrandSlot.slot(forTitle: title),
                         "「\(title)」不该被接管")
        }
    }

    /// 槽位的 rawValue 就是标签栏项的标题：`slot(forTitle:)` 与它是同一个口径，
    /// 防止以后有人改了 rawValue 却忘了匹配表。
    func testRawValuesAreTheTabTitles() {
        XCTAssertEqual(TabBarBrandSlot.home.rawValue, "首页")
        XCTAssertEqual(TabBarBrandSlot.bangumi.rawValue, "Bangumi")
        XCTAssertEqual(TabBarBrandSlot.moviepilot.rawValue, "MoviePilot")
        for slot in TabBarBrandSlot.allCases {
            XCTAssertEqual(TabBarBrandSlot.slot(forTitle: slot.rawValue), slot)
        }
    }
}
#endif