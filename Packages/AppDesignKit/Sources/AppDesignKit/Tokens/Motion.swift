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
    /// 换页退场：点击后当前页淡出，淡出完成再落地 push（两段式转场第一段，
    /// 第二段是新页 `pageEntrance` 入场）。落地延迟用 `exitSeconds`。
    public static let exit = Animation.easeInOut(duration: 0.45)
    /// 与 `exit` 同节奏的 push 落地延迟秒数（淡出完成 → 落地）。
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

// MARK: - 页面入场

private struct PageEntranceModifier: ViewModifier {
    @State private var appeared: Bool

    /// 路由页默认 `false`：初始隐藏，push 落位即播入场。栈根传 `true`：
    /// 初始可见（启动不播动画），仅被上层页覆盖后重新露出（pop 返回）时重放。
    init(initiallyVisible: Bool = false) {
        _appeared = State(initialValue: initiallyVisible)
    }

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .motion(Motion.standard, value: appeared)
            // 首帧锚定：先让 opacity-0 的首帧提交再翻 appeared——onAppear 直接
            // 翻会跟初始渲染合并成同一帧，动画被吞成硬切。
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Motion.restoreDelay))
                    appeared = true
                }
            }
            // 被覆盖即复位：系统 pop 与 push 同样被吞，「退出过渡」由落点页
            // 重放入场承担（拦截系统返回键换自定义 pop 会丢 iOS 侧滑，不值得）。
            .onDisappear { appeared = false }
    }
}

public extension View {
    /// push 页面的统一入场：内容纯淡入。macOS 的系统 push 会被
    /// 同帧的整窗氛围声明 / 工具栏重建吞掉（实测 1 帧硬切），页面层自保证
    /// 一段可见、统一的过渡；reduceMotion 下 `.motion` 自动直切。
    /// 挂在导航出口（`appRouteView`）或个别直推页面上，整页一份，别叠加两层。
    /// pop 返回时落点页重放入场（栈根用 `initiallyVisible: true`，路由页默认值）。
    func pageEntrance(initiallyVisible: Bool = false) -> some View {
        modifier(PageEntranceModifier(initiallyVisible: initiallyVisible))
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
