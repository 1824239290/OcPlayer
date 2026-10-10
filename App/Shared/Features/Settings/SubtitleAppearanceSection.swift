import AppDesignKit
import PlaybackKit
import SwiftUI

/// 设置 → 播放 → 字幕外观。
///
/// 内核（Erika）的 `erika_presenter_set_subtitle_style` 从 v0.1.9 起就在，21 个字段
/// 加 8 位 `override_mask`，而 App 此前**一个字都没用**——字幕能调的只有「整体缩放」
/// 一个旋钮，于是「字幕贴边」「亮场景看不清」这类抱怨完全没有出口。
///
/// 两个设计要点：
/// - **每一项都有「不设置」态**：字幕默认交给片源自带的 ASS 排版，用户没动过的项
///   必须保持 nil，否则「只填空缺」模式下会替用户改字幕。
/// - **覆盖开关默认关**：关着时上面这些值只填脚本没指定的部分（片源自带的排版与
///   特效字体全部保留）；打开才变成替换，`override_mask` 随之置位。文案要把这个
///   区别说清楚，因为打开之后 ASS 特效字体是会被顶掉的。
struct SubtitleAppearanceSection: View {
    @Environment(PlaybackController.self) private var controller

    @AppStorage(SettingsKeys.subtitleAlignment) private var storedAlignment = 0
    @AppStorage(SettingsKeys.subtitleMarginVertical) private var storedMarginVertical = 0
    @AppStorage(SettingsKeys.subtitlePrimaryColor) private var storedPrimaryColor = Self.defaultColorValue
    @AppStorage(SettingsKeys.subtitleOutlineColor) private var storedOutlineColor = Self.defaultColorValue
    @AppStorage(SettingsKeys.subtitleOutlineWidth) private var storedOutlineWidth = 0.0
    @AppStorage(SettingsKeys.subtitleStyleOverrides) private var overridesEnabled = false

    /// 「加粗」是三态：键不存在 = 不干预。用 `@AppStorage` 的 Optional 语义会丢掉
    /// 「明确关掉」与「从未设过」的区别——这个区别在覆盖模式下有意义（明确关掉会把
    /// 片源自带的粗体一起压平），所以自己读，并给一个「还原为不设置」的出口。
    @State private var bold: Bool?

    /// 颜色用 `0` 表示「不设置」（`PlaybackPreferences` 的读取口径），
    /// 而 `ColorPicker` 必须有个具体颜色——用白色当占位展示。
    private static let defaultColorValue = 0
    private static let unsetPlaceholder = Color.white

    var body: some View {
        Section("字幕外观") {
            Picker("位置", selection: alignmentBinding) {
                Text("不设置").tag(0)
                ForEach(Self.alignmentOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Stepper(value: marginBinding, in: 0...200, step: 10) {
                KeyValueRow(
                    label: "上下边距",
                    value: storedMarginVertical == 0 ? "不设置" : "\(storedMarginVertical)"
                )
            }

            colorRow(
                label: "字幕颜色",
                stored: $storedPrimaryColor,
                key: SettingsKeys.subtitlePrimaryColor
            )
            colorRow(
                label: "描边颜色",
                stored: $storedOutlineColor,
                key: SettingsKeys.subtitleOutlineColor
            )

            Stepper(value: outlineBinding, in: 0...32, step: 1) {
                KeyValueRow(
                    label: "描边粗细",
                    value: storedOutlineWidth == 0
                        ? "不设置"
                        : String(format: "%.0f", storedOutlineWidth)
                )
            }

            HStack {
                Toggle("加粗", isOn: boldBinding)
                Spacer(minLength: 8)
                if bold != nil {
                    Button("还原") { resetBold() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            Toggle("覆盖字幕自带样式", isOn: $overridesEnabled)
                .onChange(of: overridesEnabled) { _, _ in controller.applySubtitleStyle() }
            Text(overridesEnabled
                 ? "已打开：上面改过的项会**替换**字幕自带的排版，包括 ASS 特效字体。"
                 : "关闭时以上设置只用于填补字幕没指定的部分，片源自带的排版与特效字体原样保留。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let engine = controller.engine, !engine.supportsSubtitleStyle {
                // 说清楚「没生效」的原因，而不是让用户以为设置坏了。
                // 按适配器自报的能力判断，不按内核 id 硬编码。
                Label {
                    Text("当前播放内核不支持字幕外观设置，以上选项不会生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsRowBackground()
        .onAppear { syncBoldFromDefaults() }
    }

    // MARK: - 绑定

    /// 位置：存 0 表示不干预；改回 0 会把内核设置一并还原。
    private var alignmentBinding: Binding<Int> {
        Binding(
            get: { storedAlignment },
            set: { newValue in
                storedAlignment = newValue
                controller.applySubtitleStyle()
            }
        )
    }

    private var marginBinding: Binding<Int> {
        Binding(
            get: { storedMarginVertical },
            set: { newValue in
                storedMarginVertical = newValue
                controller.applySubtitleStyle()
            }
        )
    }

    private var outlineBinding: Binding<Double> {
        Binding(
            get: { storedOutlineWidth },
            set: { newValue in
                storedOutlineWidth = newValue
                controller.applySubtitleStyle()
            }
        )
    }

    /// 三态加粗：第一次打开＝设为「加粗」，之后正常切换；「还原」回到不设置。
    private var boldBinding: Binding<Bool> {
        Binding(
            get: { bold ?? false },
            set: { newValue in
                bold = newValue
                PlaybackPreferences.subtitleBold = newValue
                controller.applySubtitleStyle()
            }
        )
    }

    private func resetBold() {
        bold = nil
        PlaybackPreferences.subtitleBold = nil
        controller.applySubtitleStyle()
    }

    private func syncBoldFromDefaults() {
        bold = PlaybackPreferences.subtitleBold
    }

    private func colorRow(label: String, stored: Binding<Int>, key: String) -> some View {
        HStack {
            KeyValueRow(
                label: label,
                value: stored.wrappedValue == 0 ? "不设置" : Self.hex(stored.wrappedValue)
            )
            Spacer(minLength: 8)
            if stored.wrappedValue != 0 {
                Button("还原") {
                    stored.wrappedValue = Self.defaultColorValue
                    UserDefaults.standard.removeObject(forKey: key)
                    controller.applySubtitleStyle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            ColorPicker(
                "",
                selection: Binding(
                    get: { Self.color(from: stored.wrappedValue) },
                    set: { newValue in
                        stored.wrappedValue = Self.rgba(from: newValue)
                        controller.applySubtitleStyle()
                    }
                ),
                supportsOpacity: true
            )
            .labelsHidden()
        }
    }

    // MARK: - 纯转换（可单测）

    /// 九宫格（小键盘布局，1…9）。只给常用四档 + 完整九档太多，用户真正会调的
    /// 是「底部居中 / 顶部居中 / 底部靠左 / 底部靠右」。
    static let alignmentOptions: [(value: Int, label: String)] = [
        (2, "底部居中"),
        (1, "左下角"),
        (3, "右下角"),
        (8, "顶部居中"),
    ]

    /// `0xRRGGBBAA` → `Color`。0（= 不设置）在 UI 里显示为白色占位。
    static func color(from rgba: Int) -> Color {
        guard rgba > 0 else { return unsetPlaceholder }
        let value = UInt32(truncatingIfNeeded: rgba)
        return Color(
            .sRGB,
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255
        )
    }

    /// `Color` → `0xRRGGBBAA`（与内核的 `primary_color_rgba` 同口径）。
    ///
    /// 两端取分量的 API 不一样（`NSColor` 有 `redComponent`，`UIColor` 没有、
    /// 必须走 `getRed(_:green:blue:alpha:)`），所以在各自平台的分支里就地取好再算，
    /// 而不是先统一成一个类型——`NSColor` / `UIColor` 在双端同源文件里没法共用。
    static func rgba(from color: Color) -> Int {
        var red: Double = 1
        var green: Double = 1
        var blue: Double = 1
        var alpha: Double = 1
        #if os(macOS)
        let native = NSColor(color).usingColorSpace(.sRGB) ?? .white
        red = Double(native.redComponent)
        green = Double(native.greenComponent)
        blue = Double(native.blueComponent)
        alpha = Double(native.alphaComponent)
        #else
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            red = Double(r)
            green = Double(g)
            blue = Double(b)
            alpha = Double(a)
        }
        // getRed 失败（颜色不在 RGB 空间，例如系统动态色）就用上面的白色兜底：
        // 宁可能写成默认值，也不要把一个无意义的 0 写进偏好。
        #endif
        let red8 = UInt32((red.clamped01 * 255).rounded())
        let green8 = UInt32((green.clamped01 * 255).rounded())
        let blue8 = UInt32((blue.clamped01 * 255).rounded())
        let alpha8 = UInt32((alpha.clamped01 * 255).rounded())
        return Int((red8 << 24) | (green8 << 16) | (blue8 << 8) | alpha8)
    }

    /// `0xRRGGBBAA` → `#RRGGBBAA` 文案。
    static func hex(_ rgba: Int) -> String {
        String(format: "#%08X", UInt32(truncatingIfNeeded: rgba))
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
