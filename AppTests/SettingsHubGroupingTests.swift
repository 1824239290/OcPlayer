import AppDesignKit
import XCTest
@testable import OcPlayer

/// 设置 hub **分段表**的契约测试。
///
/// 这套用例解决的是「新增一个设置子页，忘了挂到 hub」：子页编译通过、氛围契约
/// （`RouteAmbienceCoverageTests` 遍历 `allCases`）也通过，但**界面上的入口不存在**
/// ——hub 是唯一入口，漏挂等于那个子页从产品里消失。改前 hub 是四个手写的
/// `Section {}`，漏挂没有任何东西拦得住；现在分组是一份数据（`SettingsHub.groups`），
/// 这一页就能把它钉住。
final class SettingsHubGroupingTests: XCTestCase {

    /// 每个子页**恰好出现一次**：漏挂与重复挂都是同一类缺陷（重复会让同一个入口
    /// 出现两行、用户点哪一行都不知道差别）。
    func testEverySubpageAppearsExactlyOnce() {
        let grouped = SettingsHub.groups.flatMap(\.subpages)
        for subpage in SettingsSubpage.allCases {
            let count = grouped.filter { $0 == subpage }.count
            XCTAssertEqual(
                count, 1,
                "「\(subpage.title)」在 hub 分段表里出现了 \(count) 次，应为 1 次"
                + "（0 = 漏挂，界面上没有入口；≥2 = 重复行）")
        }
        XCTAssertEqual(
            grouped.count, SettingsSubpage.allCases.count,
            "分段表里的行数应等于子页总数：多出来的行是已删除子页的残留")
    }

    /// 段标题非空且唯一——空标题会渲染成一段没有名字的卡（正是改前最后一段的样子），
    /// 重名则让「我在哪一段」失去意义。
    func testGroupTitlesAreNonEmptyAndUnique() {
        let titles = SettingsHub.groups.map(\.title)
        for title in titles {
            XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty, "段标题不能为空")
        }
        XCTAssertEqual(Set(titles).count, titles.count, "段标题重复：\(titles)")
    }

    /// 段序稳定：段序即展示序（服务 → 播放与界面 → 应用），是对照产品口径定的
    /// （外部依赖先配、本机体验其次、维护与元信息最后）。这条防止无意间重排。
    func testGroupOrderIsStable() {
        XCTAssertEqual(
            SettingsHub.groups.map(\.title), ["服务", "播放与界面", "应用"],
            "分段顺序变了：改前请先确认新顺序比「外部依赖 → 本机体验 → 应用」更好")
    }

    /// 没有空段：空段会在界面上渲染成一张没有行的卡（`Section` 标题还在）。
    func testNoEmptyGroup() {
        for group in SettingsHub.groups {
            XCTAssertFalse(group.subpages.isEmpty, "「\(group.title)」段是空的")
        }
    }

    /// 每页都有图标，且**互不重复**：hub 是图标列一遍扫下来的，
    /// 两个子页用同一个图标会让它们看起来是一类东西。
    func testEverySubpageHasAUniqueIcon() {
        var seen: [String: SettingsSubpage] = [:]
        for subpage in SettingsSubpage.allCases {
            let key = Self.iconKey(subpage.icon)
            XCTAssertFalse(key.isEmpty, "「\(subpage.title)」没有配图标")
            if let other = seen[key] {
                XCTFail("「\(subpage.title)」与「\(other.title)」用了同一个图标 \(key)")
            }
            seen[key] = subpage
        }
    }

    /// 图标名**不复用 `routeKey` 的命名空间**：`routeKey` 是写进脚本与
    /// `verify-ambience.sh` 的 PAGES 表的稳定 ASCII 标识，图标是给人看的呈现。
    /// 这条钉住两者互不干扰——改了图标不该动自动化通道（同一条口径见 `routeKey` 注释）。
    func testIconNamesDoNotLeakAutomationKeys() {
        for subpage in SettingsSubpage.allCases {
            XCTAssertNotEqual(
                Self.iconKey(subpage.icon), subpage.routeKey,
                "「\(subpage.title)」的图标名撞上了自动化键（两者是两个命名空间）")
        }
    }

    /// 三个品牌图各自的**宽高比**必须与资产里的内容包围盒一致
    /// （Bangumi 0.94 / MoviePilot 0.86 / TMDB 2.33，2026-10-13 实测）。
    ///
    /// 为什么值得钉：图标框是 22 × 18，`fittedSize` 靠这个比例决定「按宽还是按高」——
    /// 填错方向的后果是**字标溢出图标列、把标题挤走**（TMDB 的 2.33:1 wordmark
    /// 若按高约束就是 42pt 宽，比列宽宽近一倍）。
    func testBrandIconAspectRatiosArePinned() {
        let expected: [SettingsSubpage: CGFloat] = [
            .bangumi: 0.94,
            .moviepilot: 0.86,
            .tmdb: 2.33,
        ]
        for (subpage, aspect) in expected {
            guard case .brand(let name, let actual) = subpage.icon else {
                XCTFail("「\(subpage.title)」应当是品牌图（用户口径：用 SVG）")
                continue
            }
            XCTAssertEqual(
                actual, aspect, accuracy: 0.01,
                "「\(subpage.title)」的 \(name) 比例应是 \(aspect)")
        }
        // 其余七个仍是 SF Symbol（没品牌资产的不要硬编）。
        let brandCount = SettingsSubpage.allCases.filter {
            if case .brand = $0.icon { return true } else { return false }
        }.count
        XCTAssertEqual(brandCount, 3, "品牌图恰好三个（Bangumi / MoviePilot / TMDB）")
    }

    /// 「Jellyfin」这个名字**不再出现在 hub 入口上**（用户口径：改成「媒体服务器」）。
    ///
    /// 本 App 同时支持 Jellyfin 与 Emby，拿其中一家的名字当整类功能的入口名对 Emby
    /// 用户是误导。同时钉住 `routeKey` **没跟着改**——自动化通道与
    /// `verify-ambience.sh` 的 PAGES 表依赖它。
    func testJellyfinEntryIsNamedAsMediaServer() {
        XCTAssertEqual(SettingsSubpage.jellyfin.title, "媒体服务器")
        XCTAssertEqual(
            SettingsSubpage.jellyfin.routeKey, "jellyfin",
            "routeKey 是自动化通道的稳定键，不许跟着显示名一起改")
    }

    private static func iconKey(_ icon: SettingsRowIconSource) -> String {
        switch icon {
        case .symbol(let name): name
        case .brand(let name, _): name
        }
    }
}
