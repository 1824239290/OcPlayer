import SwiftUI

// MARK: - 悬停抬升（设计稿 focus 态的桌面版：放大 + 投影，不画焦点环）

private struct HoverLift: ViewModifier {
    let active: Bool
    let reduceMotion: Bool

    /// 比短 bounce spring 更顺：稍长 response + 高阻尼，进出都像被托起来而不是弹一下。
    /// 不用 body 里的 `withAnimation { content… }`——每次 body 重算都会重开事务，悬停进出容易发硬。
    /// 统一走 `Motion.lift` token。
    private var motion: Animation? {
        reduceMotion ? nil : Motion.lift
    }

    private var lifted: Bool { active && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted ? 1.055 : 1)
            .shadow(
                color: .black.opacity(lifted ? 0.28 : 0),
                radius: lifted ? 14 : 0,
                y: lifted ? 8 : 0
            )
            .animation(motion, value: active)
    }
}

public extension View {
    func hoverLift(active: Bool, reduceMotion: Bool) -> some View {
        modifier(HoverLift(active: active, reduceMotion: reduceMotion))
    }
}

// MARK: - 悬停行高亮（列表式卡片用）

/// 列表式卡片（横向排列：小封面 + 信息列）的悬停反馈。
///
/// 和 `hoverLift`（放大 + 投影，给海报/剧照网格卡用）区分开：
/// 行式卡片放大 1.055 会撑出列表边界、和邻居重叠，不适合。
///
/// **底 = 液态玻璃**（2026-10-22 随「全站内容卡统一为下载页同一套玻璃」一起改）：
/// 原先是 `.ultraThinMaterial`（扁平磨砂，没有边缘高光与折射）。换成玻璃后只剩一个
/// 约束——**悬停反馈不能再用一层填充**：玻璃会把它当背景吃掉（实测 `primary .08`
/// 在玻璃上不可见，同 `AppShellSectionGroup.segmentBackground` 的记录），而且
/// 「玻璃上再叠玻璃/材质」违反 WWDC25 323 的取样规则。所以悬停信号改走
/// **accent 描边 + 极轻的内容层提亮**（`content` 层的 `.background` 在玻璃之下，
/// 会被玻璃盖住，因此提亮挂在 `overlay` 里的形状填充上——它画在玻璃之上）。
private struct HoverRowHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        // **半径必须与玻璃卡一致**：早先这里是 `Metrics.cardRadius`(10)，而下面
        // `liquidGlassCard()` 的圆角是 `Metrics.glassCardRadius`(16)——两形状不同半径时，
        // 悬停填充与 accent 描边会在四角**露出玻璃卡之外**、描边与卡缘错位
        // （2026-10-22 review 抓出：「圆角统一」只改了玻璃，没改这层 overlay）。
        let shape = RoundedRectangle(cornerRadius: Metrics.glassCardRadius, style: .continuous)
        return content
            .liquidGlassCard(isInteractive: active)
            .overlay(
                shape
                    .fill(Color.primary.opacity(active ? 0.06 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(
                        active ? Color.accentColor.opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
    }
}

public extension View {
    /// 列表式卡片的悬停高亮：背景提亮 + accent 描边。给行式卡片用，
    /// 不放大（放大会让行撑出列表边界）。海报/剧照网格卡用 `hoverLift`。
    func hoverRowHighlight(active: Bool) -> some View {
        modifier(HoverRowHighlight(active: active))
    }
}
