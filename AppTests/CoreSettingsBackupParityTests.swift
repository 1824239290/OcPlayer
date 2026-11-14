import DanmakuKit
import Foundation
import OcPlayerCore
import XCTest
@testable import OcPlayer

@MainActor
final class CoreSettingsBackupParityTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        if OcpCoreFeature.isEnabled { XCTAssertTrue(ConfigBackupCoordinator.isCoreBackupActive, "Enabled checks must execute Core") }
        let name = "core-backup-parity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
    private func aligned(_ value: AppConfigBackup) -> AppConfigBackup {
        var value = value; value.exportedAt = Date(timeIntervalSince1970: 1_000_000); return value
    }
    private func compareSnapshot(_ prefs: UserDefaults, gateway: String? = nil) throws {
        let tmdb = TMDbCoordinator(defaults: prefs)
        let native = aligned(ConfigBackupCoordinator.nativeMakeBackup(tmdb: tmdb, dandanplayGatewayURL: gateway, defaults: prefs, deviceName: "fixture", appVersion: "fixture"))
        let core = aligned(try ConfigBackupCoordinator.makeBackup(tmdb: tmdb, dandanplayGatewayURL: gateway, defaults: prefs, deviceName: "fixture", appVersion: "fixture"))
        XCTAssertEqual(core, native)
        XCTAssertEqual(try ConfigBackupCoordinator.encode(core), try ConfigBackupCoordinator.nativeEncode(native))
    }
    private func raw(_ extra: String = "", stamp: String = "2026-11-14T00:00:00Z", version: Int = 1) -> String {
        "{\"formatVersion\":\(version),\"exportedAt\":\"\(stamp)\",\"appVersion\":\"fixture\"\(extra)}"
    }
    func testSnapshotMissingAndCoercedFoundationValuesMatchNative() throws {
        let prefs = try defaults(); try compareSnapshot(prefs)
        prefs.set("bad", forKey: SettingsKeys.skipIntro)
        prefs.set("bad", forKey: SettingsKeys.outroRetentionSeconds)
        prefs.set("invalid", forKey: SettingsKeys.subtitleLanguagePreference)
        prefs.set("invalid", forKey: SettingsKeys.lumaUpscaler)
        prefs.set("12", forKey: SettingsKeys.subtitleAlignment)
        prefs.set(-1, forKey: SettingsKeys.subtitleMarginVertical)
        prefs.set(false, forKey: SettingsKeys.subtitleStyleOverrides)
        prefs.set(UInt64.max, forKey: SettingsKeys.subtitlePrimaryColor)
        prefs.set(0, forKey: SettingsKeys.subtitleOutlineColor)
        prefs.set(-0.0, forKey: SettingsKeys.subtitleOutlineWidth)
        prefs.set(0.0, forKey: SettingsKeys.danmakuOpacity)
        prefs.set("0.42", forKey: SettingsKeys.danmakuDisplayArea)
        prefs.set(0.75, forKey: SettingsKeys.bangumiMirrorEnabled)
        prefs.set("\u{200b} mirror.test \u{200b}", forKey: SettingsKeys.bangumiMirrorRootDomain)
        prefs.set(42, forKey: SettingsKeys.homeSections)
        try compareSnapshot(prefs, gateway: "   ")
    }
    func testAllBackupFieldsRestoreToIdenticalPreferenceDomains() throws {
        let native = try defaults(), core = try defaults()
        var config = AppConfigBackup(tmdb: TMDbBackupConfig(apiKey: "new-key", language: "ja-JP", preferText: false, replaceImages: true, showPlaceholders: false, cacheDays: 999),
            playback: PlaybackBackupConfig(skipIntro: false, skipOutro: false, outroRetentionSeconds: -2, subtitleLanguage: "zh-Hant", lumaUpscaler: "artCnnC4F16Ds", subtitleStyleOverrides: false, subtitleAlignment: 9, subtitleMarginVertical: 9007199254740993, subtitlePrimaryColor: UInt32.max, subtitleOutlineColor: 0, subtitleOutlineWidth: -0.0, subtitleBold: false, httpReadAheadMiB: 64, httpBackBufferMiB: -1),
            danmaku: DanmakuBackupConfig(danmakuEnabled: false, opacity: 1.2, displayArea: 0, blockTop: true, blockBottom: true, blockScroll: true, fontSize: 44, autoLoad: false, dandanplayGatewayURL: "https://custom.test"),
            general: GeneralBackupConfig(bangumiEnabled: false, moviepilotEnabled: false, homeSections: "a,-b", episodeSortAscending: false),
            mirror: MirrorBackupConfig(bangumiEnabled: true, bangumiRootDomain: " raw ", tmdbEnabled: true, tmdbAPIBaseURL: "https://api.test", tmdbImageBaseURL: ""))
        config = aligned(config)
        let a = TMDbCoordinator(defaults: native), b = TMDbCoordinator(defaults: core)
        ConfigBackupCoordinator.nativeApplyBackup(config, tmdb: a, dandanplayStore: DandanplaySettingsStore(defaults: native), defaults: native)
        try ConfigBackupCoordinator.applyBackup(config, tmdb: b, dandanplayStore: DandanplaySettingsStore(defaults: core), defaults: core)
        XCTAssertEqual(native.dictionaryRepresentation() as NSDictionary, core.dictionaryRepresentation() as NSDictionary)
        XCTAssertEqual(a.rawAPIKey, b.rawAPIKey); XCTAssertEqual(a.language, b.language); XCTAssertEqual(a.cacheDays, b.cacheDays)
    }
    func testPartialEmptyAndNullPoliciesPreserveTargetCredentialsAndStyle() throws {
        let native = try defaults(), core = try defaults()
        for prefs in [native, core] {
            prefs.set(true, forKey: SettingsKeys.subtitleBold)
            prefs.set("keep", forKey: SettingsKeys.homeSections)
            prefs.set("stale", forKey: SettingsKeys.tmdbMirrorAPIBaseURL)
        }
        let a = TMDbCoordinator(defaults: native), b = TMDbCoordinator(defaults: core)
        a.setAPIKey("keep-key"); b.setAPIKey("keep-key")
        let config = AppConfigBackup(tmdb: TMDbBackupConfig(apiKey: ""), playback: PlaybackBackupConfig(subtitleLanguage: "invalid", lumaUpscaler: "invalid"), general: GeneralBackupConfig(homeSections: ""), mirror: MirrorBackupConfig())
        ConfigBackupCoordinator.nativeApplyBackup(config, tmdb: a, defaults: native)
        try ConfigBackupCoordinator.applyBackup(config, tmdb: b, defaults: core)
        XCTAssertEqual(native.dictionaryRepresentation() as NSDictionary, core.dictionaryRepresentation() as NSDictionary)
        XCTAssertEqual(b.rawAPIKey, "keep-key"); XCTAssertTrue(core.bool(forKey: SettingsKeys.subtitleBold))
        XCTAssertNil(core.object(forKey: SettingsKeys.tmdbMirrorAPIBaseURL))
    }
    func testLegacyMirrorFirstKeysAndIntegralNumbersDecodeLikeNative() throws {
        _ = try defaults()
        let playback = "{\"skipIntro\":true,\"skipOutro\":true,\"outroRetentionSeconds\":1e1,\"subtitleLanguage\":\"off\",\"lumaUpscaler\":\"off\",\"httpReadAheadMiB\":0,\"httpBackBufferMiB\":0,\"subtitleMarginVertical\":9007199254740993.0}"
        let text = raw(",\"mirror\":{\"enabled\":true,\"enabled\":false,\"tmdbEnabled\":null},\"playback\":\(playback),\"unknown\":{\"number\":1e999}")
        let data = Data(text.utf8)
        XCTAssertEqual(try ConfigBackupCoordinator.decode(data), try ConfigBackupCoordinator.nativeDecode(data))
    }
    func testUtfEncodingsAndISODateVariantsMatchNative() throws {
        _ = try defaults()
        for stamp in ["2026-02-30T00:00:00Z", "2026-1-1T0:0:0Z", "2026-01-01T25:61:61Z", "2026-01-01T00:00:00.123456789Z", "2026-01-01T00:00:00+08", "2026-01-01T00:00:00Zextra", "0000-01-01T00:00:00Z"] {
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
                let data = raw(stamp: stamp).data(using: encoding)!
                XCTAssertEqual(try ConfigBackupCoordinator.decode(data), try ConfigBackupCoordinator.nativeDecode(data))
            }
        }
    }
    func testMalformedAndFutureFilesHaveMatchingUserErrors() throws {
        _ = try defaults()
        for text in ["", "{", raw(",\"tmdb\":{}"), raw(",\"mirror\":{\"enabled\":\"bad\",\"tmdbEnabled\":false}"), raw(stamp: "2026-13-01T00:00:00Z"), raw(version: 2)] {
            let data = Data(text.utf8)
            var nativeError: String?, coreError: String?
            do { _ = try ConfigBackupCoordinator.nativeDecode(data) } catch { nativeError = error.localizedDescription }
            do { _ = try ConfigBackupCoordinator.decode(data) } catch { coreError = error.localizedDescription }
            XCTAssertNotNil(nativeError); XCTAssertEqual(coreError, nativeError)
        }
    }
    func testSummaryUnicodeKeysAndEncoderNewVersionCompatibility() throws {
        _ = try defaults()
        for key in ["", " ", "a", "prefix-👩‍👩‍👧‍👦🇨🇳éz"] {
            let config = aligned(AppConfigBackup(formatVersion: 2, deviceName: "fixture", tmdb: TMDbBackupConfig(apiKey: key), mirror: MirrorBackupConfig()))
            XCTAssertEqual(try ConfigBackupCoordinator.summary(of: config), ConfigBackupCoordinator.nativeSummary(of: config))
            XCTAssertEqual(try ConfigBackupCoordinator.encode(config), try ConfigBackupCoordinator.nativeEncode(config))
        }
    }
    func testReadBackupUsesCoreAfterNativeFileAccess() throws {
        _ = try defaults()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("core-backup-file-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = raw(",\"mirror\":{\"enabled\":true}").data(using: .utf16BigEndian)!
        try data.write(to: url)
        XCTAssertEqual(try ConfigBackupCoordinator.readBackup(from: url), try ConfigBackupCoordinator.nativeDecode(data))
    }
}
