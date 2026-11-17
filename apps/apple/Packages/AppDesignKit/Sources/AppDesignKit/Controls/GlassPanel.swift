import SwiftUI

/// 悬浮毛玻璃面板：材质 + 顶部渐亮 + 渐变描边 + 一道高光。
///
/// ## 为什么不是 `liquidGlassCard`
///
/// `liquidGlassCard` 是给内容卡片用的（不透明感更强、圆角 `Metrics.glassCardRadius`、
/// `.regular` 玻璃）。
/// 登录面板要的是另一种东西：它**浮在一张照片上**，需要更薄的材质、更明显的顶底
/// 亮度差，以及沿上边缘的一道镜面高光——那道高光是「这是一块玻璃」唯一的视觉线索。
/// 两者是两种语义，各留各的实现。
public extension View {
    /// 把内容包成一块悬浮玻璃面板。
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.primary.opacity(0.10), .primary.opacity(0.015)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.primary.opacity(0.45), .primary.opacity(0.06), .primary.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .overlay(alignment: .top) {
                        // 上边缘的镜面高光。
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .primary.opacity(0.55), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 1)
                            .padding(.horizontal, 52)
                    }
            }
    }
}

/// 横向抖动，由关键帧轨道驱动，所以下落与回弹是**显式写出来**的，而不是一串
/// 带延迟的状态写入。
///
/// 用在「输入不合法 / 登录失败」上：抖一下是最快让人意识到「刚才那下没生效」
/// 的反馈，比一行红字先被看见。
public struct ShakeModifier: ViewModifier {
    public let trigger: Int
    public let amplitude: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Values { var x: CGFloat = 0 }

    public init(trigger: Int, amplitude: CGFloat = 11) {
        self.trigger = trigger
        self.amplitude = amplitude
    }

    public func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: Values(), trigger: trigger) { view, value in
                view.offset(x: value.x)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    CubicKeyframe(-amplitude, duration: 0.065)
                    CubicKeyframe(amplitude * 0.82, duration: 0.065)
                    CubicKeyframe(-amplitude * 0.55, duration: 0.065)
                    CubicKeyframe(amplitude * 0.32, duration: 0.065)
                    CubicKeyframe(0, duration: 0.09)
                }
            }
        }
    }
}

public extension View {
    /// 横向抖动反馈（见 `ShakeModifier`）。
    func shake(trigger: Int, amplitude: CGFloat = 11) -> some View {
        modifier(ShakeModifier(trigger: trigger, amplitude: amplitude))
    }
}
