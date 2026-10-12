import XCTest
@testable import OcPlayer

/// `OCPLAYER_START_ROUTE` 的语法解析。
///
/// 这条通道是**验收台的输入**：解析错了，脚本会在 `--dry-run` 里显示成"能跑"、
/// 实跑时却落到别的页面——那种假通过比报错更难查。所以每一种写法都钉一条，
/// 不合法的写法也钉（认不出必须返回 nil，让脚本报 SKIP 而不是静默乱跳）。
final class LaunchRouteTests: XCTestCase {

    // MARK: - 合法写法

    func testParsesSimpleTargets() {
        XCTAssertEqual(LaunchRoute.parse("library"), .library)
        XCTAssertEqual(LaunchRoute.parse("detail"), .detail)
        XCTAssertEqual(LaunchRoute.parse("search"), .search)
        XCTAssertEqual(LaunchRoute.parse("bangumi.profile"), .bangumiProfile)
        XCTAssertEqual(LaunchRoute.parse("bangumi.calendar"), .bangumiCalendar)
    }

    func testParsesBangumiSubjectWithID() {
        XCTAssertEqual(LaunchRoute.parse("bangumi.subject.123"), .bangumiSubject(id: 123))
    }

    func testParsesAllSettingsSubpages() {
        for subpage in SettingsSubpage.allCases {
            XCTAssertEqual(
                LaunchRoute.parse("settings.\(subpage.routeKey)"),
                .settings(subpage, leaf: nil),
                "子页键 \(subpage.routeKey) 必须能被解析")
        }
    }

    func testParsesPresentedLeaves() {
        XCTAssertEqual(
            LaunchRoute.parse("settings.jellyfin.servers"),
            .settings(.jellyfin, leaf: .servers))
        XCTAssertEqual(
            LaunchRoute.parse("settings.about.licenses"),
            .settings(.about, leaf: .licenses))
    }

    /// 大小写与空白容错：环境变量是人手敲的（终端里常带首尾空格）。
    func testToleratesCaseAndWhitespace() {
        XCTAssertEqual(LaunchRoute.parse("  LIBRARY  "), .library)
        XCTAssertEqual(LaunchRoute.parse("Settings.About.Licenses"), .settings(.about, leaf: .licenses))
        XCTAssertEqual(LaunchRoute.parse("BANGUMI.Subject.7"), .bangumiSubject(id: 7))
    }

    // MARK: - 非法写法

    func testRejectsUnknownTargets() {
        for text in ["", "   ", "home", "settings", "settings.nope", "bangumi", "bangumi.nope",
                     "library.extra", "detail.extra"] {
            XCTAssertNil(LaunchRoute.parse(text), "「\(text)」不该被解析成目标页")
        }
    }

    /// 叶子页必须挂在**正确的**宿主子页下：`settings.about.servers` 是"配置写错了"，
    /// 判非法（脚本会 SKIP），而不是落到关于页却什么都不展开——那种"点了没反应"
    /// 会让验收者以为页面本身有问题。
    func testRejectsLeafUnderWrongParent() {
        XCTAssertNil(LaunchRoute.parse("settings.about.servers"))
        XCTAssertNil(LaunchRoute.parse("settings.jellyfin.licenses"))
        XCTAssertNil(LaunchRoute.parse("settings.playback.servers"))
    }

    func testRejectsMalformedSubjectID() {
        for text in ["bangumi.subject", "bangumi.subject.abc", "bangumi.subject.0",
                     "bangumi.subject.-3", "bangumi.subject.1.2"] {
            XCTAssertNil(LaunchRoute.parse(text), "「\(text)」不该被解析成条目详情")
        }
    }

    // MARK: - 键的往返与稳定性

    /// 键是**写进脚本与 PAGES 表**的东西，必须稳定且唯一：改标题（`title`）不能
    /// 影响它，两个子页也不能撞键。
    func testRouteKeysAreStableAndUnique() {
        let keys = SettingsSubpage.allCases.map(\.routeKey)
        XCTAssertEqual(Set(keys).count, keys.count, "子页键重复会让深链落到错误的页")
        for key in keys {
            XCTAssertFalse(key.isEmpty)
            XCTAssertTrue(key.allSatisfy { $0.isLetter && $0.isLowercase },
                          "键要能直接写进 shell 命令：\(key)")
        }
        // 往返
        for subpage in SettingsSubpage.allCases {
            XCTAssertEqual(SettingsSubpage(routeKey: subpage.routeKey), subpage)
        }
        XCTAssertNil(SettingsSubpage(routeKey: "nope"))
    }

    /// `title` 是给人看的、随文案改；键不能跟着变（这条钉住"别拿标题当键"）。
    func testRouteKeyIsIndependentFromDisplayTitle() {
        XCTAssertEqual(SettingsSubpage.tmdb.routeKey, "tmdb")
        XCTAssertNotEqual(SettingsSubpage.tmdb.routeKey, SettingsSubpage.tmdb.title)
    }
}
