import SwiftUI

/// 设置分段的**卡底**：半透明纯色叠加，铺在氛围图之上。
///
/// ## 为什么是纯色叠加，不是 material / glassEffect
///
/// 对照产品 Rex 的设置页就是一张卡：实测页面底色 lum 49.7 → 卡内 71.6（Δ≈22），
/// 反解出来就是 `Color.white.opacity(0.098)`。而本仓 2026-10-13 的实测结论是
/// material / glassEffect 都自带一层**模式色纱**，跟 `.home` 遮罩叠出来是死白
/// （见 `settingsCard()` 的注释）——纯色叠加没有这层纱，氛围图仍从卡下透出来，
/// 与「氛围背景铺满全部界面」这条设计不冲突。
///
/// 用法：挂在 `Section` 上的 `listRowBackground`（见 App 层 `View.settingsCard()`）。
/// `insetGrouped` 的段背景是**连续**的（从标题一直包到页脚），所以逐行铺同一个
/// 半透明色，观感就是一张整卡——圆角与首尾行形状都由系统给，我们不必自绘，
/// 也就不会跟系统的圆角体系打架（iOS 26 段圆角比上一代更大）。
public struct SettingsCardFill: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        Color.white.opacity(
            colorScheme == .dark
                ? SettingsMetrics.cardFillDarkOpacity
                : SettingsMetrics.cardFillLightOpacity
        )
    }
}
