import BangumiKit
import Foundation
import MetadataKit
@testable import OcPlayer
import XCTest

/// 镜像源键名的**跨包契约**。
///
/// 设置页写四个地址类/开关类键，两个域包各读自己那几个；任何一处字面量写错都不会
/// 编译报错，表现只是「开关拨了没反应」或「只有一半生效」——最难查的一类缺陷。
/// 所以两侧的常量必须在同一个用例里被逐个比对。
///
/// 2026-10-30 起镜像按**线路**拆开：Bangumi 的开关/根域在 Bangumi 页、TMDB 的开关与
/// 两个根在 TMDB 页，两个开关是**两个键**（不再共用一个 `mirror.enabled`）。
final class MirrorKeyContractTests: XCTestCase {

    func testBangumiKeysMatchPackageReader() {
        XCTAssertEqual(SettingsKeys.bangumiMirrorEnabled, BangumiURL.mirrorEnabledKey)
        XCTAssertEqual(SettingsKeys.bangumiMirrorRootDomain, BangumiURL.mirrorRootDomainKey)
    }

    func testTMDbKeysMatchPackageReader() {
        XCTAssertEqual(SettingsKeys.tmdbMirrorEnabled, TMDbEndpointSettings.mirrorEnabledKey)
        XCTAssertEqual(SettingsKeys.tmdbMirrorAPIBaseURL, TMDbEndpointSettings.apiMirrorKey)
        XCTAssertEqual(SettingsKeys.tmdbMirrorImageBaseURL, TMDbEndpointSettings.imageMirrorKey)
    }

    /// 两个开关**必须**是不同的键：镜像按线路配，两家镜像常是不同的提供方。
    /// 合并成一个键不会编译报错，症状是「只想关 TMDB 的镜像，Bangumi 也跟着断」。
    func testTheTwoSwitchesAreSeparateKeys() {
        XCTAssertNotEqual(SettingsKeys.bangumiMirrorEnabled, SettingsKeys.tmdbMirrorEnabled)
        XCTAssertNotEqual(BangumiURL.mirrorEnabledKey, TMDbEndpointSettings.mirrorEnabledKey)
    }

    /// 五个键互不相同：粘错一个（例如把图片地址写进 API 键）会让两个读取点共用一份值，
    /// 症状是「改了 API 地址，图片也跟着变」。
    func testKeysAreDistinct() {
        let keys = [
            SettingsKeys.bangumiMirrorEnabled,
            SettingsKeys.bangumiMirrorRootDomain,
            SettingsKeys.tmdbMirrorEnabled,
            SettingsKeys.tmdbMirrorAPIBaseURL,
            SettingsKeys.tmdbMirrorImageBaseURL,
        ]
        XCTAssertEqual(Set(keys).count, keys.count, "镜像源的键有重复：\(keys)")
    }

    /// 镜像不再是独立子页（设置 hub 里没有它）：页数回到 10，且 `mirror` 这个路由键
    /// 认不出来——旧脚本写 `settings.mirror` 会明确报 SKIP，而不是静默落到别的页。
    func testMirrorIsNoLongerASubpage() {
        XCTAssertEqual(SettingsSubpage.allCases.count, 10)
        XCTAssertNil(SettingsSubpage(routeKey: "mirror"))
    }
}

/// `MirrorSettings`：两家的生效值、输入校验、值预览、各自复位。
///
/// 全部用独立 `UserDefaults(suiteName:)`：`.standard` 在测试宿主里是**真实的用户域**，
/// 写进去会污染开发者本机的镜像设置，也会让其它用例随机失败。
final class MirrorSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "MirrorSettingsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 值预览（hub 行尾）

    func testBangumiSummaryIsNilWhenSwitchIsOff() {
        XCTAssertNil(MirrorSettings.bangumiSummary(enabled: false, rawValue: "bangumi.lat"))
        XCTAssertNil(MirrorSettings.bangumiSummary(enabled: false, rawValue: ""))
    }

    func testBangumiSummaryShowsRootDomainOrMissingAddress() {
        XCTAssertEqual(MirrorSettings.bangumiSummary(enabled: true, rawValue: "bangumi.lat"),
                       "镜像：bangumi.lat")
        XCTAssertEqual(MirrorSettings.bangumiSummary(enabled: true, rawValue: ""),
                       "已启用（未填地址）")
        XCTAssertEqual(MirrorSettings.bangumiSummary(enabled: true, rawValue: "https://"),
                       "已启用（未填地址）",
                       "非法地址会被域包退回官方，预览不能说成已镜像")
    }

    func testTMDbSummaryListsOnlyConfiguredRoots() {
        XCTAssertNil(MirrorSettings.tmdbSummary(
            enabled: false, apiRawValue: "https://api.tmdb.org/3", imageRawValue: ""))
        XCTAssertEqual(MirrorSettings.tmdbSummary(
            enabled: true, apiRawValue: "https://api.tmdb.org/3", imageRawValue: ""),
                       "镜像：API")
        XCTAssertEqual(MirrorSettings.tmdbSummary(
            enabled: true, apiRawValue: "https://api.tmdb.org/3",
            imageRawValue: "https://image.tmdb.org/t/p"),
                       "镜像：API + 图片")
        XCTAssertEqual(MirrorSettings.tmdbSummary(enabled: true, apiRawValue: "", imageRawValue: ""),
                       "已启用（未填地址）")
    }

    /// 两家的预览**互不串台**：只开 TMDB 的镜像时，Bangumi 那一行不能显示镜像。
    func testSummariesAreIndependent() {
        XCTAssertNil(MirrorSettings.bangumiSummary(enabled: false, rawValue: "bangumi.lat"))
        XCTAssertEqual(MirrorSettings.tmdbSummary(
            enabled: true, apiRawValue: "https://api.tmdb.org/3", imageRawValue: ""),
                       "镜像：API")
    }

    /// **「（镜像）」标记只在实际生效时出现**：hub 上那个标记存在的理由就是
    /// 「别让用户以为线路已改」，所以「开关开着但地址空 / 填错」必须判成未生效
    /// ——那时域包已经退回官方了。
    func testMirrorActiveRequiresParseableAddress() {
        XCTAssertFalse(MirrorSettings.bangumiMirrorActive(enabled: false, rawValue: "bangumi.lat"))
        XCTAssertFalse(MirrorSettings.bangumiMirrorActive(enabled: true, rawValue: ""))
        XCTAssertFalse(MirrorSettings.bangumiMirrorActive(enabled: true, rawValue: "https://"))
        XCTAssertTrue(MirrorSettings.bangumiMirrorActive(enabled: true, rawValue: "bangumi.lat"))

        XCTAssertFalse(MirrorSettings.tmdbMirrorActive(
            enabled: true, apiRawValue: "", imageRawValue: ""))
        XCTAssertFalse(MirrorSettings.tmdbMirrorActive(
            enabled: true, apiRawValue: "https://", imageRawValue: "https://"))
        // 两项独立：只填一项也算生效（另一项走官方）。
        XCTAssertTrue(MirrorSettings.tmdbMirrorActive(
            enabled: true, apiRawValue: "https://api.tmdb.org/3", imageRawValue: ""))
        XCTAssertTrue(MirrorSettings.tmdbMirrorActive(
            enabled: true, apiRawValue: "", imageRawValue: "https://image.tmdb.org/t/p"))
    }

    // MARK: - 输入校验

    func testEmptyInputIsNotAProblem() {
        XCTAssertNil(MirrorSettings.bangumiProblem(""))
        XCTAssertNil(MirrorSettings.bangumiProblem("   "))
        XCTAssertNil(MirrorSettings.tmdbAPIProblem(""))
        XCTAssertNil(MirrorSettings.tmdbImageProblem(""))
    }

    func testParseableInputIsNotAProblem() {
        XCTAssertNil(MirrorSettings.bangumiProblem("bangumi.lat"))
        XCTAssertNil(MirrorSettings.bangumiProblem("https://bangumi.lat/"))
        XCTAssertNil(MirrorSettings.tmdbAPIProblem("api.tmdb.org"))
        XCTAssertNil(MirrorSettings.tmdbAPIProblem("https://api.tmdb.org/3"))
        XCTAssertNil(MirrorSettings.tmdbImageProblem("https://image.tmdb.org/t/p"))
    }

    func testUnparseableInputIsReported() {
        XCTAssertNotNil(MirrorSettings.bangumiProblem("https://"))
        XCTAssertNotNil(MirrorSettings.tmdbAPIProblem("https://"))
        XCTAssertNotNil(MirrorSettings.tmdbImageProblem("ftp://img.example"))
    }

    // MARK: - 生效值（与域包同一套规则）

    func testBangumiDomainsFollowSwitch() {
        let off = MirrorSettings.bangumiDomains(enabled: false, rawValue: "bangumi.lat")
        XCTAssertEqual(off.api, "api.bgm.tv")
        XCTAssertEqual(off.image, "lain.bgm.tv")

        let on = MirrorSettings.bangumiDomains(enabled: true, rawValue: "https://bangumi.lat/")
        XCTAssertEqual(on.main, "bangumi.lat")
        XCTAssertEqual(on.api, "api.bangumi.lat")
        XCTAssertEqual(on.image, "lain.bangumi.lat")
        XCTAssertEqual(on.next, "next.bangumi.lat")
    }

    func testTMDbEndpointsFallBackPerField() {
        let off = MirrorSettings.tmdbEndpoints(
            enabled: false, apiRawValue: "https://api.tmdb.org/3", imageRawValue: "https://img.example/t/p")
        XCTAssertEqual(off, .official)

        let half = MirrorSettings.tmdbEndpoints(
            enabled: true, apiRawValue: "https://api.tmdb.org/3", imageRawValue: "https://")
        XCTAssertEqual(half.apiBaseURL.absoluteString, "https://api.tmdb.org/3")
        XCTAssertEqual(half.imageBaseURL, TMDbEndpoints.official.imageBaseURL)
    }

    // MARK: - 复位

    /// 「恢复官方直连」**连开关与地址一起清**：只关开关会把旧地址留在盘上，
    /// 下次打开开关时莫名连回一个早已失效的镜像。
    func testResetBangumiClearsItsOwnTwoKeysOnly() {
        defaults.set(true, forKey: SettingsKeys.bangumiMirrorEnabled)
        defaults.set("bangumi.lat", forKey: SettingsKeys.bangumiMirrorRootDomain)
        // TMDB 的镜像配置必须原封不动：两家的复位按钮互不越界。
        defaults.set(true, forKey: SettingsKeys.tmdbMirrorEnabled)
        defaults.set("https://api.tmdb.org/3", forKey: SettingsKeys.tmdbMirrorAPIBaseURL)

        MirrorSettings.resetBangumi(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: SettingsKeys.bangumiMirrorEnabled))
        XCTAssertNil(defaults.object(forKey: SettingsKeys.bangumiMirrorRootDomain))
        XCTAssertEqual(defaults.bool(forKey: SettingsKeys.tmdbMirrorEnabled), true)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.tmdbMirrorAPIBaseURL), "https://api.tmdb.org/3")
    }

    func testResetTMDbClearsItsOwnThreeKeysOnly() {
        defaults.set(true, forKey: SettingsKeys.bangumiMirrorEnabled)
        defaults.set("bangumi.lat", forKey: SettingsKeys.bangumiMirrorRootDomain)
        defaults.set(true, forKey: SettingsKeys.tmdbMirrorEnabled)
        defaults.set("https://api.tmdb.org/3", forKey: SettingsKeys.tmdbMirrorAPIBaseURL)
        defaults.set("https://image.tmdb.org/t/p", forKey: SettingsKeys.tmdbMirrorImageBaseURL)

        MirrorSettings.resetTMDb(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: SettingsKeys.tmdbMirrorEnabled))
        XCTAssertNil(defaults.object(forKey: SettingsKeys.tmdbMirrorAPIBaseURL))
        XCTAssertNil(defaults.object(forKey: SettingsKeys.tmdbMirrorImageBaseURL))
        XCTAssertEqual(defaults.bool(forKey: SettingsKeys.bangumiMirrorEnabled), true)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.bangumiMirrorRootDomain), "bangumi.lat")
    }

    /// 复位之后包里的读取口回到官方（端到端验证「清键 = 官方」）。
    func testResetMakesPackageReadersUseOfficialEndpoints() {
        defaults.set(true, forKey: TMDbEndpointSettings.mirrorEnabledKey)
        defaults.set("https://api.tmdb.org/3", forKey: TMDbEndpointSettings.apiMirrorKey)

        XCTAssertEqual(TMDbEndpointSettings(defaults: defaults).endpoints.apiBaseURL.absoluteString,
                       "https://api.tmdb.org/3")

        MirrorSettings.resetTMDb(defaults: defaults)

        XCTAssertEqual(TMDbEndpointSettings(defaults: defaults).endpoints, .official)
    }

    /// 只开 TMDB 的镜像时，Bangumi 的开关**没有被连带打开**。
    ///
    /// 这条盯的是「两个开关必须是两个键」这件事在**磁盘上**的形态：域包的解析器
    /// （`resolvedMirrorRootDomain`）是 internal 的，App 侧读不到，所以这里读键本身
    /// ——这也正是两个域包各自读的那两个键。
    func testTMDbSwitchDoesNotEnableBangumiMirror() {
        defaults.set(true, forKey: SettingsKeys.tmdbMirrorEnabled)
        defaults.set("https://api.tmdb.org/3", forKey: SettingsKeys.tmdbMirrorAPIBaseURL)

        XCTAssertEqual(defaults.bool(forKey: BangumiURL.mirrorEnabledKey), false)
        XCTAssertNil(defaults.string(forKey: BangumiURL.mirrorRootDomainKey))
        XCTAssertEqual(MirrorSettings.bangumiDomains(enabled: false, rawValue: ""), .official)
    }
}
