import SwiftUI

// MARK: - Liquid Glass 视图修饰符（iOS 26 / macOS 26+）

public extension View {
    /// 通用液态玻璃卡片容器。
    /// 采用原生 Liquid Glass 渲染，对背景内容产生物理级光线折射与半透明采样。
    ///
    /// **圆角默认走 `Metrics.glassCardRadius`（16），不要按页面各写一个值**：
    /// 2026-10-22 统一时清掉了原本散落的 10 / 12 / 14 / 18 —— 相邻区域圆角不一致，
    /// 切页/滚动时同一张卡在不同页里轮廓会跳，观感上就不像「同一套玻璃」。
    /// 嵌在卡内的小卡用 `Metrics.glassNestedRadius`（8，同心圆角）。
    @ViewBuilder
    func liquidGlassCard(
        cornerRadius: CGFloat = Metrics.glassCardRadius,
        isInteractive: Bool = false
    ) -> some View {
        self
            .glassEffect(
                isInteractive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    /// 通用液态玻璃胶囊按钮/标签。
    @ViewBuilder
    func liquidGlassCapsule(
        tint: Color? = nil,
        isInteractive: Bool = true
    ) -> some View {
        if let tint {
            self.glassEffect(
                isInteractive ? .regular.tint(tint).interactive() : .regular.tint(tint),
                in: Capsule()
            )
        } else {
            self.glassEffect(
                isInteractive ? .regular.interactive() : .regular,
                in: Capsule()
            )
        }
    }
}
