import Foundation
import OcPlayerCore
import XCTest
@testable import OcPlayer

@MainActor
final class CoreRuntimePreferenceParityTests: XCTestCase {
    private let keys = [SettingsKeys.httpReadAheadMiB, SettingsKeys.httpBackBufferMiB, SettingsKeys.skipIntro, SettingsKeys.skipOutro, SettingsKeys.outroRetentionSeconds, SettingsKeys.subtitleLanguagePreference, SettingsKeys.lumaUpscaler, SettingsKeys.subtitleAlignment, SettingsKeys.subtitleMarginVertical, SettingsKeys.subtitlePrimaryColor, SettingsKeys.subtitleOutlineColor, SettingsKeys.subtitleOutlineWidth, SettingsKeys.subtitleBold, SettingsKeys.subtitleStyleOverrides, SettingsKeys.danmakuDiagnostics, SettingsKeys.playbackRate, SettingsKeys.playbackVolume, SettingsKeys.playbackMuted, SettingsKeys.playbackSubtitleScale, SettingsKeys.danmakuEnabled, SettingsKeys.danmakuOpacity, SettingsKeys.danmakuDisplayArea, SettingsKeys.danmakuBlockTop, SettingsKeys.danmakuBlockBottom, SettingsKeys.danmakuBlockScroll, SettingsKeys.danmakuUseOverlayRenderer, SettingsKeys.danmakuMergeDuplicates, SettingsKeys.danmakuAllowStacking, SettingsKeys.danmakuFontSize]
    private func projection() -> [String: String] {
        [
            "rate": String(describing: PlaybackPreferences.rate),
            "volume": String(describing: PlaybackPreferences.volume),
            "muted": String(describing: PlaybackPreferences.muted),
            "subtitleScale": String(describing: PlaybackPreferences.subtitleScale),
            "subtitleLanguagePreference": String(describing: PlaybackPreferences.subtitleLanguagePreference),
            "lumaUpscaler": String(describing: PlaybackPreferences.lumaUpscaler),
            "subtitleAlignment": String(describing: PlaybackPreferences.subtitleAlignment),
            "subtitleMarginVertical": String(describing: PlaybackPreferences.subtitleMarginVertical),
            "subtitlePrimaryColorRGBA": String(describing: PlaybackPreferences.subtitlePrimaryColorRGBA),
            "subtitleOutlineColorRGBA": String(describing: PlaybackPreferences.subtitleOutlineColorRGBA),
            "subtitleOutlineWidth": String(describing: PlaybackPreferences.subtitleOutlineWidth),
            "subtitleBold": String(describing: PlaybackPreferences.subtitleBold),
            "subtitleStyleOverrides": String(describing: PlaybackPreferences.subtitleStyleOverrides),
            "danmakuUseOverlayRenderer": String(describing: PlaybackPreferences.danmakuUseOverlayRenderer),
            "danmakuEnabled": String(describing: PlaybackPreferences.danmakuEnabled),
            "danmakuOpacity": String(describing: PlaybackPreferences.danmakuOpacity),
            "danmakuDisplayArea": String(describing: PlaybackPreferences.danmakuDisplayArea),
            "danmakuBlockTop": String(describing: PlaybackPreferences.danmakuBlockTop),
            "danmakuBlockBottom": String(describing: PlaybackPreferences.danmakuBlockBottom),
            "danmakuBlockScroll": String(describing: PlaybackPreferences.danmakuBlockScroll),
            "danmakuMergeDuplicates": String(describing: PlaybackPreferences.danmakuMergeDuplicates),
            "danmakuAllowStacking": String(describing: PlaybackPreferences.danmakuAllowStacking),
            "danmakuFontSize": String(describing: PlaybackPreferences.danmakuFontSize),
            "danmakuDiagnosticsEnabled": String(describing: PlaybackPreferences.danmakuDiagnosticsEnabled),
            "httpReadAheadMiB": String(describing: PlaybackPreferences.httpReadAheadMiB),
            "httpBackBufferMiB": String(describing: PlaybackPreferences.httpBackBufferMiB),
            "skipIntroEnabled": String(describing: PlaybackPreferences.skipIntroEnabled),
            "skipOutroEnabled": String(describing: PlaybackPreferences.skipOutroEnabled),
            "outroRetentionSeconds": String(describing: PlaybackPreferences.outroRetentionSeconds)
        ]
    }
    func testAllRuntimePreferencesMatchOriginalPolicyForNativeCastFacts() throws {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let override = PlaybackPreferences.coreEnabledOverride
        defer {
            PlaybackPreferences.coreEnabledOverride = override
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        PlaybackPreferences.coreEnabledOverride = true
        XCTAssertTrue(PlaybackPreferences.runtimeCoreActive, "fixture requires the real Rust library")
        let samples: [Any?] = [nil, false, true, 0, 5, 10, 32, 128, 999, -1,
                              0.75, "garbage", "zh-Hant", "artCnnC4F16Ds", UInt32.max,
                              Double.nan, Double.infinity, -Double.infinity]
        for sample in samples {
            for key in keys {
                if let sample { UserDefaults.standard.set(sample, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            PlaybackPreferences.coreEnabledOverride = false
            let reference = projection()
            PlaybackPreferences.coreEnabledOverride = true
            let count = PlaybackPreferences.coreResolutionCount
            XCTAssertEqual(projection(), reference, "native facts: \(String(describing: sample))")
            XCTAssertEqual(PlaybackPreferences.coreResolutionCount - count, 29, "every getter must execute Core")
        }
    }
}
