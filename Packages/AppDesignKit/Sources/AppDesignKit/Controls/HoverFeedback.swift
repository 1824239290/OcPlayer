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
/// 底用 `.ultraThinMaterial`（同 MoviePilotResourceView 的氛围页卡片）：
/// 透出整窗氛围图，与设置页 Form 分组底的半透明观感一致；
/// 悬停在其上做填充提亮 + accentColor 描边。
private struct HoverRowHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
        return content
            // 提亮填充要叠在磨砂底**之上**、内容之下：background 链先声明的更贴内容。
            .background(active ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape
                    .strokeBorder(
                        active ? Color.accentColor.opacity(0.3) : Color.clear,
                        lineWidth: 1
                    )
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
