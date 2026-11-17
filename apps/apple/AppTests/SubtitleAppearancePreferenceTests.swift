import PlaybackKit
import SwiftUI
import XCTest
@testable import OcPlayer

/// 字幕外观偏好：三态语义、非法存量值兜底、以及「只把设过的项带出去」。
///
/// 这里守的是一个很容易被顺手做错的区别：**「没设过」与「明确设成默认值」不是一回事**。
/// 内核的样式接口在「只填空缺」模式下会拿宿主给的值去填脚本空缺，所以用户从没动过
/// 的项必须保持 nil——否则一进设置页就把全片字幕的字重/位置改了。
@MainActor
final class SubtitleAppearancePreferenceTests: XCTestCase {

    private static let keys = [
        SettingsKeys.subtitleAlignment,
        SettingsKeys.subtitleMarginVertical,
        SettingsKeys.subtitlePrimaryColor,
        SettingsKeys.subtitleOutlineColor,
        SettingsKeys.subtitleOutlineWidth,
        SettingsKeys.subtitleBold,
        SettingsKeys.subtitleStyleOverrides,
    ]

    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.keys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.keys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    /// 全新安装 / 升级前：一个字都没设过 → 样式是**空**的（不下发任何东西）。
    func testNothingSetProducesEmptyStyle() {
        let style = PlaybackPreferences.subtitleStyle()
        XCTAssertTrue(style.isEmpty, "没设过任何项时不该带出样式，否则等于替用户改字幕")
        XCTAssertFalse(PlaybackPreferences.subtitleStyleOverrides, "覆盖开关默认关")
        XCTAssertTrue(PlaybackPreferences.subtitleStyleOverridesMask().isEmpty)
    }

    /// 只设了颜色：带出去的只有颜色，位置 / 边距 / 描边仍是 nil。
    func testOnlyTouchedFieldsAreForwarded() {
        PlaybackPreferences.subtitlePrimaryColorRGBA = 0xFFCC_00FF
        let style = PlaybackPreferences.subtitleStyle()
        XCTAssertEqual(style.primaryColorRGBA, 0xFFCC_00FF)
        XCTAssertNil(style.alignment)
        XCTAssertNil(style.marginVertical)
        XCTAssertNil(style.outlineWidth)
        XCTAssertNil(style.bold)
    }

    /// 加粗是三态：没设过 ≠ 明确关掉。这个区别在覆盖模式下会真的改变画面
    /// （明确关掉会把片源自带的粗体一起压平）。
    func testBoldIsThreeState() {
        XCTAssertNil(PlaybackPreferences.subtitleBold, "默认是「不设置」")
        XCTAssertNil(PlaybackPreferences.subtitleStyle().bold)

        PlaybackPreferences.subtitleBold = false
        XCTAssertEqual(PlaybackPreferences.subtitleBold, false, "明确关掉要存得住")
        XCTAssertEqual(PlaybackPreferences.subtitleStyle().bold, false)

        PlaybackPreferences.subtitleBold = true
        XCTAssertEqual(PlaybackPreferences.subtitleBold, true)

        // 还原 → 回到「不设置」，键被清掉。
        PlaybackPreferences.subtitleBold = nil
        XCTAssertNil(PlaybackPreferences.subtitleBold)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: SettingsKeys.subtitleBold),
            "还原后键要真的消失，而不是留一个 false"
        )
        XCTAssertNil(PlaybackPreferences.subtitleStyle().bold)
    }

    /// 0 是「不设置」的哨兵：位置 0 / 边距 0 / 描边 0 都不该被当成有效值带出去。
    func testZeroMeansUnsetForNumericFields() {
        PlaybackPreferences.subtitleAlignment = 0
        PlaybackPreferences.subtitleMarginVertical = 0
        PlaybackPreferences.subtitleOutlineWidth = 0
        let style = PlaybackPreferences.subtitleStyle()
        XCTAssertNil(style.alignment, "对齐 0 是非法值，只能是「不设置」")
        XCTAssertNil(style.marginVertical)
        XCTAssertNil(style.outlineWidth)
    }

    /// 非法存量值（人手改坏 / 旧版本写过别的语义）→ 回落「不设置」。
    ///
    /// 注意这里刻意**不是钳制**：描边宽度 999 若被钳成 32，就变成一个用户没要过的
    /// 有效设置，等于替他改了字幕。三态字段的垃圾值只能当成「没设」。
    func testCorruptedValuesFallBackToUnset() {
        UserDefaults.standard.set(99, forKey: SettingsKeys.subtitleAlignment)
        UserDefaults.standard.set(-5, forKey: SettingsKeys.subtitleMarginVertical)
        UserDefaults.standard.set(999.0, forKey: SettingsKeys.subtitleOutlineWidth)

        XCTAssertEqual(PlaybackPreferences.subtitleAlignment, 0)
        XCTAssertEqual(PlaybackPreferences.subtitleMarginVertical, 0)
        XCTAssertEqual(PlaybackPreferences.subtitleOutlineWidth, 0, "非法值不该被钳成有效设置")
        XCTAssertTrue(PlaybackPreferences.subtitleStyle().isEmpty)
    }

    /// 合法边界要保住：0…32 是内核接受的范围，32 本身是有效设置。
    func testOutlineWidthBoundaryIsHonored() {
        PlaybackPreferences.subtitleOutlineWidth = 32
        XCTAssertEqual(PlaybackPreferences.subtitleOutlineWidth, 32)
        XCTAssertEqual(PlaybackPreferences.subtitleStyle().outlineWidth, 32)

        // 越界一点点就按「没设」处理。
        UserDefaults.standard.set(32.1, forKey: SettingsKeys.subtitleOutlineWidth)
        XCTAssertEqual(PlaybackPreferences.subtitleOutlineWidth, 0)
        UserDefaults.standard.set(-0.1, forKey: SettingsKeys.subtitleOutlineWidth)
        XCTAssertEqual(PlaybackPreferences.subtitleOutlineWidth, 0)
    }

    /// 覆盖开关：关着是空掩码，打开才把本仓库涉及的五类全置位。
    func testOverrideMaskFollowsSwitch() {
        XCTAssertTrue(PlaybackPreferences.subtitleStyleOverridesMask().isEmpty)
        PlaybackPreferences.subtitleStyleOverrides = true
        XCTAssertEqual(PlaybackPreferences.subtitleStyleOverridesMask(), .all)
    }

    // MARK: - 颜色转换（设置页 UI ↔ 存储值）

    /// `0xRRGGBBAA` 往返：ColorPicker 改一下颜色再存回来，不该丢精度到看不出。
    func testColorRoundTripsThroughRGBA() {
        for value in [0xFFCC_00FF, 0x1122_3388, 0xFFFF_FFFF] as [UInt32] {
            let color = SubtitleAppearanceSection.color(from: Int(value))
            let back = SubtitleAppearanceSection.rgba(from: color)
            XCTAssertEqual(
                UInt32(back), value,
                "颜色往返丢精度：\(SubtitleAppearanceSection.hex(Int(value))) → \(SubtitleAppearanceSection.hex(back))"
            )
        }
    }

    /// 0（不设置）在 UI 里显示成白色占位，但存储值仍是 0——别把占位色写回偏好。
    func testUnsetColorPlaceholderIsNotStored() {
        let placeholder = SubtitleAppearanceSection.color(from: 0)
        XCTAssertEqual(placeholder, .white)
        XCTAssertEqual(PlaybackPreferences.subtitlePrimaryColorRGBA, nil)
    }

    /// 十六进制文案：8 位大写，便于和内核日志对照。
    func testHexFormatting() {
        XCTAssertEqual(SubtitleAppearanceSection.hex(0xFFCC_00FF), "#FFCC00FF")
        XCTAssertEqual(SubtitleAppearanceSection.hex(0x0000_007F), "#0000007F")
    }

    /// 位置选项只给合法九宫格值（1…9，numpad 布局）。
    func testAlignmentOptionsAreValid() {
        XCTAssertFalse(SubtitleAppearanceSection.alignmentOptions.isEmpty)
        for option in SubtitleAppearanceSection.alignmentOptions {
            XCTAssertTrue(
                (1...9).contains(option.value),
                "对齐值 \(option.value) 超出九宫格范围——内核按 numpad 布局解释"
            )
            XCTAssertFalse(option.label.isEmpty)
        }
    }
}
