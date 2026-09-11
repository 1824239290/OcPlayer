import SwiftUI

// MARK: - 动效 token（全站统一节奏）

/// 全站唯一的动效语义 token。交互微反馈走短 `fast`，页面/内容过渡走 `standard`，
/// 大区间切换走 `slide`，悬浮抬升走 `lift`，玻璃形变走 `glass`，氛围层走 `ambient`。
/// **不要在代码里再写裸的 `.easeInOut(duration:)` 自定义值**——统一从这里取。
public enum Motion {
    /// 交互微反馈：按压 / 悬停 / 开关 / HUD 淡入淡出。
    public static let fast = Animation.easeOut(duration: 0.12)
    /// 常用标准过渡：面板出现、骨架→内容、行内状态切换。
    public static let standard = Animation.easeInOut(duration: 0.2)
    /// 稍长的切换：大区间 / Tab 切换 / 全屏进出。
    public static let slide = Animation.easeInOut(duration: 0.25)
    /// 沉浸/氛围：仅氛围层（首页轮播），交互不用。
    public static let ambient = Animation.easeInOut(duration: 1.6)
    /// 外观/主题切换（深浅色）的柔和短淡变。
    public static let theme = Animation.easeInOut(duration: 0.5)
    /// 卡片/对象抬升的轻弹簧（悬停 lift、选集高亮）。
    public static let lift = Animation.spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.12)
    /// 玻璃 / Liquid 形变（HUD 面板）。
    public static let glass = Animation.smooth(duration: 0.35)
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

public extension View {
    /// 全站**唯一**动画入口：内部自动感知 `accessibilityReduceMotion`，
    /// UI 层无需再手动传 reduceMotion，也杜绝「忘了关动画」的疏漏。
    /// 减弱动态效果时自动传 nil（SwiftUI 视作无动画、立即切换）。
    /// 用法：`.motion(Motion.standard, value: foo)`
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// 与 `.motion(_:value:)` 同义，但显式传入 `reduceMotion`（供明确需要
    /// 手动控制的调用点使用；新代码优先用 `.motion(_:value:)`）。
    func motionAnimation<V: Equatable>(
        _ animation: Animation,
        value: V,
        reduceMotion: Bool
    ) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - 命名过渡

public extension AnyTransition {
    /// 全屏覆盖层开片（播放器进出）：轻缩放 + 淡入；退出只淡出。
    /// 用纯 transform，不绑定卡片原点，跨 iOS/macOS 稳定。
    /// computed（非存储）以规避 `AnyTransition` 非 Sendable 的并发校验。
    static var cinematic: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 1.04).combined(with: .opacity),
            removal: .opacity
        )
    }
    /// 大区 / 模块平级切换：统一 crossfade。
    static var section: AnyTransition { .opacity }
    /// 面板 / 行内出现：微收缩 + 淡入。
    static var pop: AnyTransition { .scale(scale: 0.96).combined(with: .opacity) }
}
