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
    /// `standard` 的秒数：给不能收 `Animation` 的计时口（卸载延时、看门狗）用，
    /// 保证「等动画跑完」永远跟着 token 走，不写散落的魔法数。
    public static let standardSeconds: Double = 0.2
    /// 稍长的切换：大区间 / Tab 切换 / 全屏进出。
    public static let slide = Animation.easeInOut(duration: 0.25)
    /// 换页退场：点击后当前页淡出，淡出完成再落地 push（两段式转场第一段，
    /// 第二段是落地后 routeExiting 复位的回弹淡入——新页以隐藏态出生，复位
    /// 时正好有 from-state，入场淡入由 `RouteExitFader` 唯一承担）。落地延迟
    /// 用 `exitSeconds`。
    public static let exit = Animation.easeInOut(duration: 0.45)
    /// 与 `exit` 同节奏的落地延迟秒数（淡出完成 → 落地）。push / pop 同拍，
    /// 落地后不再为任何「系统过渡」加等（实测弹栈落地即撤页）。
    public static let exitSeconds: Double = 0.45
    /// 落地后的恢复前置拍：新页必须先以「隐藏态」提交至少一帧，透明度恢复
    /// 才有 from-state 可动画（同帧出生即恢复 = 硬切无动画）。
    public static let restoreDelay: Double = 0.05
    /// 沉浸/氛围：仅氛围层（首页轮播），交互不用。
    public static let ambient = Animation.easeInOut(duration: 1.6)
    /// 外观/主题切换（深浅色）的柔和短淡变。
    public static let theme = Animation.easeInOut(duration: 0.5)
    /// 卡片/对象抬升的轻弹簧（悬停 lift、选集高亮）。
    public static let lift = Animation.spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.12)
    /// 玻璃 / Liquid 形变（HUD 面板）。
    public static let glass = Animation.smooth(duration: 0.35)
    /// 指针驱动的景深跟随（登录页海报墙的 3D 倾斜）。要**明显慢于**指针本身，
    /// 否则墙像贴在光标上被拖着走，而不是「一面墙被倾斜」。
    public static let pointerTilt = Animation.smooth(duration: 0.42)
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
}
