import SwiftUI

// MARK: - Liquid Glass 视图修饰符（iOS 26 / macOS 26+）

public extension View {
    /// 通用液态玻璃卡片容器。
    /// 采用原生 Liquid Glass 渲染，对背景内容产生物理级光线折射与半透明采样。
    @ViewBuilder
    func liquidGlassCard(
        cornerRadius: CGFloat = 18,
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
