import DanmakuKit
import Foundation
import XCTest
@testable import OcPlayer

/// 配置备份的导出 / 解析 / 恢复。
///
/// 这一层几乎全是**静默失败**：键名写错、类型写错（`UInt32` 颜色存成 String）、
/// 三态写成默认值，都不会编译报错，只表现为「导入了但设置没搬过去」。
/// 所以用例的重点不是「能跑通」，而是逐项盯住键与形态。
///
/// 全部用独立 `UserDefaults(suiteName:)`：`.standard` 在测试宿主里是**真实的用户域**，
/// 写进去会污染本机设置、也会让其它用例随机失败（同 `TMDbCoordinatorTests`）。
@MainActor
final class ConfigBackupTests: XCTestCase {

    private var suiteNames: [String] = []

    /// 造一个独立 suite，并在 `tearDown` 里连域一起清掉。
    private func makeDefaults(_ prefix: String) throws -> UserDefaults {
        let name = "ConfigBackupTests-\(prefix)-\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDown() async throws {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
    }

    // MARK: - TMDB：导出 → 序列化 → 恢复

    func testExportAndImportTMDbConfig() throws {
        let source = try makeDefaults("tmdb-source")
        let original = TMDbCoordinator(defaults: source)
        original.setAPIKey("test-tmdb-key-987654321")
        original.setLanguage("zh-HK")
        original.setPreferText(false)
        original.setReplaceImages(true)
        original.setShowPlaceholders(false)
        original.setCacheDays(7)

        let backup = ConfigBackupCoordinator.makeBackup(
            tmdb: original,
            defaults: source,
            deviceName: "MacBook Test",
            appVersion: "0.2.1"
        )

        XCTAssertEqual(backup.formatVersion, ConfigBackupCoordinator.formatVersion)
        XCTAssertEqual(backup.deviceName, "MacBook Test")
        XCTAssertEqual(backup.appVersion, "0.2.1")
        XCTAssertEqual(backup.tmdb?.apiKey, "test-tmdb-key-987654321")
        XCTAssertEqual(backup.tmdb?.language, "zh-HK")
        XCTAssertEqual(backup.tmdb?.preferText, false)
        XCTAssertEqual(backup.tmdb?.replaceImages, true)
        XCTAssertEqual(backup.tmdb?.showPlaceholders, false)
        XCTAssertEqual(backup.tmdb?.cacheDays, 7)

        // 序列化往返。时间戳按 ISO8601（秒精度）落盘，所以只按秒比对——
        // **不比对整个结构体**，否则这条用例会因为毫秒被截断而随机变红（与功能无关）。
        let data = try ConfigBackupCoordinator.encode(backup)
        let decoded = try ConfigBackupCoordinator.decode(data)
        XCTAssertEqual(decoded.formatVersion, backup.formatVersion)
        XCTAssertEqual(decoded.appVersion, backup.appVersion)
        XCTAssertEqual(decoded.deviceName, backup.deviceName)
        XCTAssertEqual(decoded.tmdb, backup.tmdb)
        XCTAssertEqual(
            decoded.exportedAt.timeIntervalSince1970,
            backup.exportedAt.timeIntervalSince1970,
            accuracy: 1,
            "ISO8601 只精确到秒")

        // 恢复到全新环境：Key 与全部策略都要到位。
        let target = try makeDefaults("tmdb-target")
        let targetTMDb = TMDbCoordinator(defaults: target)
        XCTAssertFalse(targetTMDb.isConfigured, "前置条件：目标环境本来没配")

        ConfigBackupCoordinator.applyBackup(decoded, tmdb: targetTMDb, defaults: target)

        XCTAssertTrue(targetTMDb.isConfigured)
        XCTAssertEqual(targetTMDb.rawAPIKey, "test-tmdb-key-987654321")
        XCTAssertEqual(targetTMDb.language, "zh-HK")
        XCTAssertEqual(targetTMDb.preferText, false)
        XCTAssertEqual(targetTMDb.replaceImages, true)
        XCTAssertEqual(targetTMDb.showPlaceholders, false)
        XCTAssertEqual(targetTMDb.cacheDays, 7)
    }

    /// 备份里没有 Key（用户没配 TMDB）时导入，**不能清掉目标设备已有的 Key**：
    /// 「备份里没有凭据」不等于「用户想登出」。
    func testImportWithoutAPIKeyKeepsExistingKey() throws {
        let source = try makeDefaults("nokey-source")
        let backup = ConfigBackupCoordinator.makeBackup(
            tmdb: TMDbCoordinator(defaults: source), defaults: source)
        XCTAssertNil(backup.tmdb?.apiKey)

        let target = try makeDefaults("nokey-target")
        let targetTMDb = TMDbCoordinator(defaults: target)
        targetTMDb.setAPIKey("existing-key")

        ConfigBackupCoordinator.applyBackup(backup, tmdb: targetTMDb, defaults: target)
        XCTAssertEqual(targetTMDb.rawAPIKey, "existing-key")
    }

    // MARK: - 播放与常规偏好

    func testExportAndImportPlaybackAndGeneralPreferences() throws {
        let source = try makeDefaults("playback-source")
        let tmdb = TMDbCoordinator(defaults: source)
        source.set(false, forKey: SettingsKeys.skipIntro)
        source.set(30, forKey: SettingsKeys.outroRetentionSeconds)
        source.set("zh-Hant", forKey: SettingsKeys.subtitleLanguagePreference)
        source.set("artCnnC4F16", forKey: SettingsKeys.lumaUpscaler)
        source.set(64, forKey: SettingsKeys.httpReadAheadMiB)
        source.set(false, forKey: SettingsKeys.bangumiEnabled)

        let backup = ConfigBackupCoordinator.makeBackup(tmdb: tmdb, defaults: source)

        let target = try makeDefaults("playback-target")
        ConfigBackupCoordinator.applyBackup(
            backup, tmdb: TMDbCoordinator(defaults: target), defaults: target)

        XCTAssertEqual(target.bool(forKey: SettingsKeys.skipIntro), false)
        XCTAssertEqual(target.integer(forKey: SettingsKeys.outroRetentionSeconds), 30)
        XCTAssertEqual(target.string(forKey: SettingsKeys.subtitleLanguagePreference), "zh-Hant")
        XCTAssertEqual(target.string(forKey: SettingsKeys.lumaUpscaler), "artCnnC4F16")
        XCTAssertEqual(target.integer(forKey: SettingsKeys.httpReadAheadMiB), 64)
        XCTAssertEqual(target.bool(forKey: SettingsKeys.bangumiEnabled), false)
    }

    /// 局部备份（只有 TMDB）不能碰目标设备的其它设置。
    func testPartialBackupPreservesUntouchedSettings() throws {
        let target = try makeDefaults("partial-target")
        let targetTMDb = TMDbCoordinator(defaults: target)
        target.set(128, forKey: SettingsKeys.httpReadAheadMiB)

        let partial = AppConfigBackup(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "0.2.1",
            deviceName: "iPhone",
            tmdb: TMDbBackupConfig(apiKey: "partial-key", language: "ja-JP")
        )

        ConfigBackupCoordinator.applyBackup(partial, tmdb: targetTMDb, defaults: target)

        XCTAssertEqual(targetTMDb.rawAPIKey, "partial-key")
        XCTAssertEqual(targetTMDb.language, "ja-JP")
        XCTAssertEqual(target.integer(forKey: SettingsKeys.httpReadAheadMiB), 128, "没带的模块保持现状")
    }

    // MARK: - 落盘形态：这几条盯着「不会编译报错、只会静默失效」的坑

    /// 字幕颜色在 `UserDefaults` 里是 **UInt32 整数**（`PlaybackPreferences.storedColor`），
    /// 不是字符串。存成 String 不会编译报错，只会让颜色搬不过去。
    func testSubtitleColorsSurviveRoundTripAsIntegers() throws {
        let source = try makeDefaults("color-source")
        let tmdb = TMDbCoordinator(defaults: source)
        let primary: UInt32 = 0xFF00FF00   // 不透明绿
        let outline: UInt32 = 0x80000000   // 半透明黑
        source.set(Int(primary), forKey: SettingsKeys.subtitlePrimaryColor)
        source.set(Int(outline), forKey: SettingsKeys.subtitleOutlineColor)

        let backup = ConfigBackupCoordinator.makeBackup(tmdb: tmdb, defaults: source)
        XCTAssertEqual(backup.playback?.subtitlePrimaryColor, primary)
        XCTAssertEqual(backup.playback?.subtitleOutlineColor, outline)

        let target = try makeDefaults("color-target")
        ConfigBackupCoordinator.applyBackup(
            try ConfigBackupCoordinator.decode(ConfigBackupCoordinator.encode(backup)),
            tmdb: TMDbCoordinator(defaults: target),
            defaults: target
        )
        XCTAssertEqual(target.integer(forKey: SettingsKeys.subtitlePrimaryColor), Int(primary))
        XCTAssertEqual(target.integer(forKey: SettingsKeys.subtitleOutlineColor), Int(outline))
    }

    /// 字幕外观是**三态**：「没设过」导出成 nil，导入时**不写**。
    /// 写成 0 / 默认值等于替用户改了字幕（ASS 特效字体被顶掉）。
    func testUnsetSubtitleStyleStaysUnsetAfterImport() throws {
        let source = try makeDefaults("tristate-source")
        let tmdb = TMDbCoordinator(defaults: source)
        let backup = ConfigBackupCoordinator.makeBackup(tmdb: tmdb, defaults: source)

        XCTAssertNil(backup.playback?.subtitleAlignment, "没设过就该是 nil")
        XCTAssertNil(backup.playback?.subtitlePrimaryColor)
        XCTAssertNil(backup.playback?.subtitleBold)
        XCTAssertNil(backup.playback?.subtitleOutlineWidth)

        // 目标设备自己设过加粗：导入一份「没设过」的备份不能把它冲掉。
        let target = try makeDefaults("tristate-target")
        target.set(true, forKey: SettingsKeys.subtitleBold)
        ConfigBackupCoordinator.applyBackup(
            backup, tmdb: TMDbCoordinator(defaults: target), defaults: target)
        XCTAssertEqual(target.bool(forKey: SettingsKeys.subtitleBold), true, "nil 不该覆盖既有设置")

        // 反过来：明确设过 false（「就是不加粗」）必须原样搬过去。
        source.set(false, forKey: SettingsKeys.subtitleBold)
        let explicit = ConfigBackupCoordinator.makeBackup(tmdb: tmdb, defaults: source)
        XCTAssertEqual(explicit.playback?.subtitleBold, false, "明确关掉 ≠ 没设过")

        let explicitTarget = try makeDefaults("tristate-explicit")
        ConfigBackupCoordinator.applyBackup(
            explicit, tmdb: TMDbCoordinator(defaults: explicitTarget), defaults: explicitTarget)
        XCTAssertEqual(explicitTarget.object(forKey: SettingsKeys.subtitleBold) as? Bool, false)
    }

    /// 枚举档位导出的是 rawValue：字幕语言是 `zh-Hans`（不是 `chi`）、
    /// 画质增强是 `artCnnC4F16`。形态写错不会崩，只会让设置页显示「设了」但实际不生效。
    func testEnumPreferencesUseRawValues() throws {
        let source = try makeDefaults("enum-source")
        let tmdb = TMDbCoordinator(defaults: source)
        source.set("zh-Hant", forKey: SettingsKeys.subtitleLanguagePreference)
        source.set("artCnnC4F16", forKey: SettingsKeys.lumaUpscaler)

        let backup = ConfigBackupCoordinator.makeBackup(tmdb: tmdb, defaults: source)
        XCTAssertEqual(backup.playback?.subtitleLanguage, "zh-Hant")
        XCTAssertEqual(backup.playback?.lumaUpscaler, "artCnnC4F16")

        // 未设置时导出的是**可解析的**默认 rawValue。
        let fresh = try makeDefaults("enum-fresh")
        let freshBackup = ConfigBackupCoordinator.makeBackup(
            tmdb: TMDbCoordinator(defaults: fresh), defaults: fresh)
        XCTAssertEqual(freshBackup.playback?.subtitleLanguage, "zh-Hans")
        XCTAssertEqual(freshBackup.playback?.lumaUpscaler, "off")

        // 坏值不许写进目标域。
        let target = try makeDefaults("enum-bad")
        var broken = backup
        broken.playback?.subtitleLanguage = "chi"
        broken.playback?.lumaUpscaler = "not-a-mode"
        ConfigBackupCoordinator.applyBackup(
            broken, tmdb: TMDbCoordinator(defaults: target), defaults: target)
        XCTAssertNil(target.string(forKey: SettingsKeys.subtitleLanguagePreference), "坏档位不写")
        XCTAssertNil(target.string(forKey: SettingsKeys.lumaUpscaler), "坏档位不写")
    }

    /// 导出时的默认值必须与 App 真实默认一致，否则会把「没设过」变成「设成了默认值」。
    /// 显示区域这里尤其容易写错（真实默认 0.75，不是 0.5）。
    func testDanmakuDefaultsMatchAppDefaults() throws {
        let fresh = try makeDefaults("danmaku-fresh")
        let backup = ConfigBackupCoordinator.makeBackup(
            tmdb: TMDbCoordinator(defaults: fresh), defaults: fresh)

        XCTAssertEqual(backup.danmaku?.displayArea, 0.75)
        XCTAssertEqual(backup.danmaku?.opacity, 0.85)
        XCTAssertEqual(backup.danmaku?.fontSize, 22)
        XCTAssertEqual(backup.danmaku?.danmakuEnabled, true)
        XCTAssertEqual(backup.danmaku?.autoLoad, true)
        XCTAssertEqual(backup.danmaku?.blockTop, false)
    }

    /// 弹弹play 网关：**从没设过时不能导出内置默认网关**（那是个内置常量，
    /// 写进用户文件毫无意义，还会在将来换默认值时把旧地址钉死在设备上）。
    func testDandanplayGatewayOnlyExportedWhenCustomized() throws {
        let source = try makeDefaults("gateway-source")
        let tmdb = TMDbCoordinator(defaults: source)
        var store = DandanplaySettingsStore(defaults: source)

        let untouched = ConfigBackupCoordinator.makeBackup(
            tmdb: tmdb,
            dandanplayGatewayURL: store.gatewayURLString,
            defaults: source)
        XCTAssertNil(untouched.danmaku?.dandanplayGatewayURL, "未自定义就不该导出内置默认网关")

        let custom = try XCTUnwrap(URL(string: "https://my-gateway.example.com"))
        store.gatewayURL = custom
        let customized = ConfigBackupCoordinator.makeBackup(
            tmdb: tmdb,
            dandanplayGatewayURL: store.gatewayURLString,
            defaults: source)
        XCTAssertEqual(customized.danmaku?.dandanplayGatewayURL, custom.absoluteString)

        // 搬回另一台设备：自定义网关要到位，且**不能连带改写 API Key**
        // （Key 的 getter 会回落内置公共 Key，写回去等于把它变成用户显式设置）。
        let target = try makeDefaults("gateway-target")
        var targetStore = DandanplaySettingsStore(defaults: target)
        targetStore.apiKey = "user-own-key"
        ConfigBackupCoordinator.applyBackup(
            customized,
            tmdb: TMDbCoordinator(defaults: target),
            dandanplayStore: targetStore,
            defaults: target)
        XCTAssertEqual(targetStore.gatewayURLString, custom.absoluteString)
        XCTAssertEqual(targetStore.apiKey, "user-own-key", "备份里没有 Key，就不该动目标设备的 Key")
    }

    // MARK: - 损坏文件防御

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try ConfigBackupCoordinator.decode(Data())) { error in
            XCTAssertEqual(error as? ConfigBackupError, .emptyData)
        }

        let garbage = Data("{\"formatVersion\": not-json}".utf8)
        XCTAssertThrowsError(try ConfigBackupCoordinator.decode(garbage)) { error in
            guard case .invalidFormat = (error as? ConfigBackupError) else {
                XCTFail("应抛 invalidFormat，实际为 \(error)")
                return
            }
        }

        // 明文文本（用户选错了文件）同样要拦住，不能半途解码出一半对象。
        XCTAssertThrowsError(try ConfigBackupCoordinator.decode(Data("这不是 JSON".utf8))) { error in
            guard case .invalidFormat = (error as? ConfigBackupError) else {
                XCTFail("应抛 invalidFormat，实际为 \(error)")
                return
            }
        }

        let future = Data("""
        {"formatVersion": 999, "exportedAt": "2026-10-25T12:00:00Z", "appVersion": "9.9.9"}
        """.utf8)
        XCTAssertThrowsError(try ConfigBackupCoordinator.decode(future)) { error in
            XCTAssertEqual(error as? ConfigBackupError, .unsupportedVersion(999))
        }
    }

    /// 读文件失败要给出可读话术（设置页直接把它显示给用户）。
    func testReadMissingFileReportsFriendlyMessage() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-there-\(UUID().uuidString).json")
        XCTAssertThrowsError(try ConfigBackupCoordinator.readBackup(from: missing)) { error in
            guard let backupError = error as? ConfigBackupError,
                  case .unreadableFile = backupError
            else {
                XCTFail("应抛 unreadableFile，实际为 \(error)")
                return
            }
            XCTAssertFalse(backupError.errorDescription?.isEmpty ?? true)
        }
    }

    // MARK: - 摘要与文档

    func testBackupSummary() {
        let backup = AppConfigBackup(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "0.2.1",
            deviceName: "MacBook Pro M3",
            tmdb: TMDbBackupConfig(apiKey: "tmdb-secret-abcd-1234", language: "zh-CN"),
            playback: PlaybackBackupConfig()
        )

        let summary = ConfigBackupCoordinator.summary(of: backup)
        XCTAssertTrue(summary.hasTMDb)
        XCTAssertEqual(summary.tmdbKeyTail, "••••1234", "只回显尾 4 位")
        XCTAssertEqual(summary.tmdbLanguage, "zh-CN")
        XCTAssertTrue(summary.hasPlayback)
        XCTAssertFalse(summary.hasDanmaku)
        XCTAssertFalse(summary.hasGeneral)
        XCTAssertEqual(summary.deviceName, "MacBook Pro M3")
        XCTAssertFalse(summary.exportedAtFormatted.isEmpty)
    }

    /// 没配 TMDB 的备份，摘要不能谎称有 Key。
    func testSummaryWithoutKey() throws {
        let source = try makeDefaults("summary-nokey")
        let backup = ConfigBackupCoordinator.makeBackup(
            tmdb: TMDbCoordinator(defaults: source), defaults: source)
        let summary = ConfigBackupCoordinator.summary(of: backup)
        XCTAssertFalse(summary.hasTMDb)
        XCTAssertNil(summary.tmdbKeyTail)
    }

    /// `FileDocument` 承载的就是序列化后的 JSON。
    ///
    /// 不直接调 `fileWrapper(configuration:)`：`WriteConfiguration`
    /// （`FileDocumentWriteConfiguration`）的构造器不是 public，测试里造不出来。
    /// 这里验的是同一份数据源，足以覆盖导出路径。
    func testConfigBackupDocumentCarriesJSON() throws {
        let backup = AppConfigBackup(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "0.2.1",
            deviceName: "Test",
            tmdb: TMDbBackupConfig(apiKey: "key1")
        )

        let document = try ConfigBackupDocument(backup: backup)
        XCTAssertFalse(document.data.isEmpty)

        let decoded = try ConfigBackupCoordinator.decode(document.data)
        XCTAssertEqual(decoded.tmdb?.apiKey, "key1")
        XCTAssertEqual(
            document.data,
            try ConfigBackupDocument(backup: decoded).data,
            "同一份配置应产出逐字节相同的 JSON（sortedKeys 的意义）")
    }

    func testSuggestedFileNameIsJSON() {
        let name = ConfigBackupCoordinator.suggestedFileName()
        XCTAssertTrue(name.hasSuffix(".json"), "扩展名不对会让系统选择器按错误类型处理")
        XCTAssertTrue(name.hasPrefix("OcPlayer-配置备份-"))
    }
}
