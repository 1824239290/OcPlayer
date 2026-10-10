import SwiftUI

// MARK: - 海报墙列策略

/// 海报墙的列 / 行距 / 卡宽策略。媒体库网格、全局搜索结果、合集成员三处共用
/// 这一份——它们此前各写一遍同样的三元表达式，改一处就会漂一处。
///
/// **紧凑端（手机）的目标版式对照隔壁 Rex 的媒体库**：一屏 **3 列**。
/// 取值由两张 359×782 的截图像素实测反推（设备 ≈ iPhone 16/17 Pro，402pt）：
/// Rex 单卡 ≈ 118pt、列距 ≈ 10pt、行距 ≈ 16pt；本策略在 402pt 宽下给
/// 3 列 × 112.7pt（页面留白沿用全 App 的 22pt，不为此单独收窄）。
/// 对照：改之前是 **2 列 × 178pt**，而且那 178 是写死的（见 `PosterCard` 的
/// 卡宽语义），比列宽还宽 6pt，卡与卡之间只剩 8pt 缝。
///
/// 为什么用 `.adaptive(minimum:)` 而不是写死三个 `.flexible()`：紧凑宽度不止
/// 手机——iPad 分屏 / 侧拉窗口也是 compact。写死 3 列在 320pt 窗口里会挤成
/// 85pt 的小卡且不留退路；自适应按最小列宽自己定列数，320pt 退回 2 列（132pt）。
public enum PosterGrid {
    /// `LazyVGrid` 的列。`compact` 由调用方按 `horizontalSizeClass` 传入。
    /// **`alignment: .top` 不能省**：每张卡的高度＝图区 + 标题 + 年份，而图区高度随
    /// 各自的图片比例变（实测混排一行 0.667 / 0.70 / 0.75 时卡高 322/321/300pt）。
    /// 不给对齐，`LazyVGrid` 会把同一行里矮的卡在行内**居中**，于是三张卡的顶边
    /// 参差不齐（实测 y=110 / 118 / 129）——一行海报看上去像没对齐的拼贴。
    public static func columns(compact: Bool) -> [GridItem] {
        compact
            ? [GridItem(
                .adaptive(minimum: Metrics.compactGridPosterMinWidth),
                spacing: Metrics.compactGridColumnSpacing,
                alignment: .top
            )]
            : [GridItem(
                .adaptive(minimum: Metrics.posterWidth + 8),
                spacing: Metrics.railSpacing,
                alignment: .top
            )]
    }

    /// 行距（`LazyVGrid(columns:spacing:)` 的 `spacing`）。紧凑端比常规端紧一档：
    /// 卡片小了、行间还留 30pt 的话一屏看不到三行。
    public static func rowSpacing(compact: Bool) -> CGFloat {
        compact ? Metrics.compactGridRowSpacing : Metrics.railSpacing + 8
    }

    /// 卡片宽度：紧凑端 **nil = 跟随网格列宽**（`PosterCard` 此时走两行居中
    /// 标题区），常规端定宽 `Metrics.posterWidth`。
    public static func cardWidth(compact: Bool) -> CGFloat? {
        compact ? nil : Metrics.posterWidth
    }
}
