import PlaybackKit
import XCTest
@testable import OcPlayer

/// 画质增强（亮度上采样）偏好的读取语义。
///
/// 重点是**兜底方向**：这个能力有 GPU 与显存开销，任何读不出来的情况都必须落到
/// 「关闭」——旧版本从没写过这个键、值被人手改坏、将来某版删掉一个档位，
/// 都不该把一个用户没要过的负担打开。UserDefaults 是测试宿主的真实域，存取后要清理。
@MainActor
final class UpscalerPreferenceTests: XCTestCase {

    private var saved: String?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        saved = defaults.string(forKey: SettingsKeys.lumaUpscaler)
        defaults.removeObject(forKey: SettingsKeys.lumaUpscaler)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let saved {
            defaults.set(saved, forKey: SettingsKeys.lumaUpscaler)
        } else {
            defaults.removeObject(forKey: SettingsKeys.lumaUpscaler)
        }
        super.tearDown()
    }

    /// 键不存在（全新安装 / 升级前从没写过）→ 关闭。
    func testAbsentKeyDefaultsToOff() {
        XCTAssertNil(
            UserDefaults.standard.object(forKey: SettingsKeys.lumaUpscaler),
            "前提：键确实不存在"
        )
        XCTAssertEqual(PlaybackPreferences.lumaUpscaler, .off)
    }

    /// 值被人手改坏 / 将来删过档位 → 关闭，而不是崩或猜。
    func testCorruptedValueFallsBackToOff() {
        UserDefaults.standard.set("artCnnC4F64Turbo", forKey: SettingsKeys.lumaUpscaler)
        XCTAssertEqual(PlaybackPreferences.lumaUpscaler, .off)
    }

    /// 四档都能存取往返（设置页写什么、装配点就读到什么）。
    func testEveryModeRoundTrips() {
        for mode in PlaybackUpscalerMode.allCases {
            PlaybackPreferences.lumaUpscaler = mode
            XCTAssertEqual(
                PlaybackPreferences.lumaUpscaler, mode,
                "\(mode.rawValue) 存取不一致——装配点会建出与设置页不符的引擎"
            )
        }
    }

    /// 存的必须是 rawValue（不是 `displayName` 之类的人类可读串）：改名文案不该
    /// 让用户的旧设置失效。
    func testStoresRawValueNotDisplayName() {
        PlaybackPreferences.lumaUpscaler = .artCnnC4F16Ds
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsKeys.lumaUpscaler),
            "artCnnC4F16Ds"
        )
    }
}
