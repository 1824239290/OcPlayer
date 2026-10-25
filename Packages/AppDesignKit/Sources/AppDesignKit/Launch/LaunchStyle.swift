import SwiftUI

// MARK: - 启动体验的调色板

/// 启动动画的色板。**底色刻意与登录墙同一块**（`LoginWallStyle.backdrop`）：
/// iOS 的系统启动屏（`LaunchBackground` colorset，同一组色值）消失后的第一帧、
/// 启动动画、退场后露出的登录墙，三段共用同一块底，全程无跳色。
///
/// 标志渐变不是拍的脑袋：两块 AppIcon 本身就是**垂直渐变**（顶部亮、底部深，
/// x 向斜率实测 ≈ 0），这里逐外观落成 token，渐变 span 用描摹坐标系的
/// `OcMark.contentBBox` 纵向范围（168 → 861），全局一份、所有标志片段共用，
/// 保证头部/胡须/三角颜色连续（等价于 SVG 的 `gradientUnits="userSpaceOnUse"`）。
public enum LaunchStyle {
    /// 启动底色 = 登录墙底色（夜间近黑 / 日间暖白）。
    public static func backdrop(for scheme: ColorScheme) -> Color {
        LoginWallStyle.backdrop(for: scheme)
    }

    /// 底色的中心提亮（启动层的径向 vignette，预览同款）：夜间略抬、日间略暖。
    public static func backdropLift(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 247 / 255, green: 245 / 255, blue: 248 / 255)  // #F7F5F8
            : Color(red: 20 / 255, green: 17 / 255, blue: 25 / 255)     // #141119
    }

    /// 标志渐变顶部色（描摹自 AppIcon 顶部实测）。
    public static func markTop(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 254 / 255, green: 145 / 255, blue: 8 / 255)   // #FE9108
            : Color(red: 252 / 255, green: 143 / 255, blue: 5 / 255)   // #FC8F05
    }

    /// 标志渐变底部色。
    public static func markBottom(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 254 / 255, green: 103 / 255, blue: 5 / 255)   // #FE6705
            : Color(red: 253 / 255, green: 96 / 255, blue: 2 / 255)    // #FD6002
    }

    /// 标志渐变在描摹坐标系里的纵向 span（与拟合时一致，改动需连 colorset 一起重验）。
    public static let markGradientTopY: CGFloat = 168
    public static let markGradientBottomY: CGFloat = 861

    /// 光晕 / 品牌橙（两外观共用，取自 Light 图标顶部实测）。
    public static let glow = Color(red: 254 / 255, green: 138 / 255, blue: 3 / 255)  // #FE8A03
}
