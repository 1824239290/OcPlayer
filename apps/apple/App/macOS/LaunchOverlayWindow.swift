import AppDesignKit
import AppKit
import DiagnosticsKit
import QuartzCore
import SwiftUI

// MARK: - 启动动画的窗口级覆盖层（macOS）

/// 把启动动画放进一扇**独立的无边框覆盖窗口**，主窗口的系统 chrome（工具栏、
/// 红绿灯、标题）**全程一次都不碰**。
///
/// ## 为什么不用工具栏可见性开关（两条路都试过，都失败）
///
/// * SwiftUI `.toolbar(.hidden→.visible)`：销毁并重建 NSToolbar，顶栏比首页晚 ~1s；
/// * AppKit `NSToolbar.isVisible` 直控：窗口刚出现时工具栏会闪一下才收起、动画中途
///   被壳层重建重新弹回、退场时恢复还可能落空（用户实机三连报的就是这三个）。
///
/// 根因是「让活的窗口 chrome 来回变」——任何时序都堵不住所有重置点。覆盖窗口把
/// 问题从「改主窗口」变成「在主窗口上面盖一层」：主窗口的工具栏、条目、红绿灯
/// 自始至终在场且不被触碰，交棒时启动层淡出、透明窗口下的主窗口（顶栏 + 首页
/// 已经是成品）作为**一张图**被揭开，没有任何 chrome 跳变。
///
/// ## 实现要点
///
/// * 子窗口（`addChildWindow`）：自动随主窗口移动 / 最小化 / Space 切换跟随，
///   生命周期跟着主窗口；**尺寸与全屏状态不自动跟**——`didResize` / 进出全屏
///   通知里同步 frame 与圆角（全屏无圆角）。`ignoresMouseEvents` 让用户能穿过
///   覆盖层拖主窗口边缘，这条同步就是为那个瞬间兜底的。
/// * 主窗口 willClose 即拆链撤窗：子窗口虽会随父 orderOut，但单例还持着整条
///   窗口链（hosting controller 又强持 presenter），不摘会滞留到进程退出。
/// * `isOpaque = false` + 透明底：交棒淡出的是**内容**（启动层自身的 opacity），
///   内容透明处直接露出主窗口；
/// * `ignoresMouseEvents`：纯展示，绝不拦点击（与窗口内 overlay 的
///   `allowsHitTesting(false)` 同一条口径）；
/// * `collectionBehavior`：不进 Mission Control / 窗口循环，不做全屏辅助。
@MainActor
final class LaunchOverlayWindow {
    static let shared = LaunchOverlayWindow()

    private var window: NSWindow?
    private weak var parent: NSWindow?
    private weak var hostView: NSView?

    /// 覆盖层需要跟随的主窗口状态变化通知（尺寸 / 进出全屏）。
    private static let parentFrameSyncNotifications: [Notification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
    ]

    /// 盖到主窗口上。主窗口找不到（窗口尚未建好）时记一条可诊断的 warning 并
    /// 跳过——静默失败会让「动画没播」在生产日志里无迹可寻；下一帧的
    /// `isVisible` 变化/onAppear 兜底会再试。
    func present(presenter: LaunchPresenter) {
        guard window == nil else { return }
        guard let parent = Self.mainWindow() else {
            AppDiagnostics.logWarning("启动覆盖窗口未找到主窗口，本次 present 跳过")
            return
        }
        let rect = parent.frame
        let radius = Self.cornerRadius(of: parent)
        let overlay = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        overlay.isOpaque = false
        // 窗口本身保持全透明：可见的底色由 contentView 的 backing layer 负责，
        // 这样底色也跟着圆角一起裁切（建在窗口底色上会露出直角）。
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        overlay.title = ""
        // 用 NSHostingController 而不是裸 NSHostingView：前者会完整走窗口内容
        // 生命周期（挂窗口、布局、环境注入），裸 NSHostingView 在独立窗口里
        // 曾出现内容树始终不建（sublayers 恒 nil、整窗只剩底色）。
        let controller = NSHostingController(rootView: LaunchExperienceView(presenter: presenter))
        overlay.contentViewController = controller
        overlay.setContentSize(rect.size)
        let host = controller.view
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.wantsLayer = true
        // 与主窗口同款圆角：覆盖层盖住了标题栏，若不裁切就会在四角露出直角，
        // 和下面圆角的主窗口对不上。26 是 macOS 26 窗口实测圆角（`_cornerRadius`）。
        host.layer?.cornerRadius = radius
        host.layer?.masksToBounds = true
        // SwiftUI 首帧迟到时的底色兜底：同款底色、同样被圆角裁切。
        host.layer?.backgroundColor = Self.backdropColor(for: overlay.effectiveAppearance).cgColor
        parent.addChildWindow(overlay, ordered: .above)
        overlay.setFrame(rect, display: false)
        overlay.orderFrontRegardless()
        window = overlay
        self.parent = parent
        self.hostView = host
        let center = NotificationCenter.default
        for name in Self.parentFrameSyncNotifications {
            center.addObserver(
                self, selector: #selector(syncFrameToParent), name: name, object: parent)
        }
        // object: nil：除主窗口外也兜住「覆盖窗口自身被关」的旁路。
        center.addObserver(
            self, selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification, object: nil)
        presenter.onExitStart = { [weak self] in self?.beginHandoff() }
        presenter.onExitScheduled = { [weak self] exitStartMs, timelineStart in
            self?.scheduleHandoff(exitStartMs: exitStartMs, timelineStart: timelineStart)
        }
        // pendingReady 回放路径里，首次排定发生在 begin() 同步链上、早于 present：
        // 这里补一次预提交（scheduleDismiss 重排时会再回调，重复调用无害）。
        if let exitStartMs = presenter.scheduledExitStartMs {
            scheduleHandoff(exitStartMs: exitStartMs, timelineStart: presenter.startDate)
        }
    }

    /// 覆盖层跟随主窗口：同步 frame 与圆角。幂等，重复调用无害。
    @objc private func syncFrameToParent() {
        guard let window, let parent else { return }
        window.setFrame(parent.frame, display: false)
        let radius = Self.cornerRadius(of: parent)
        if let hostView, hostView.layer?.cornerRadius != radius {
            hostView.layer?.cornerRadius = radius
        }
    }

    /// 主窗口（或覆盖窗口自身）要关：立刻拆链，防止单例滞留已关窗口。
    @objc private func handleWindowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow,
              closing === parent || closing === window else { return }
        dismiss()
    }

    /// **预提交**交棒淡出：给 contentView 的根层挂一个 `beginTime` 指向未来的
    /// CA opacity 动画。commit 在当前这次 runloop 里就完成，之后主线程哪怕被
    /// 首页装配堵死几秒，淡出也由**渲染服务器**在排定时刻准点执行——
    /// 实测不做这一步，交棒被主线程拥堵顺延了 ~2.4s（排定 2.46s、实际 4.9s）。
    ///
    /// 整层淡出包含 contentView 的底色兜底，主窗口作为一张图被揭开；
    /// 重排（ambience 把退场提前）时先摘旧动画再挂新的。
    func scheduleHandoff(exitStartMs: Double, timelineStart: Date) {
        guard let layer = hostView?.layer else { return }
        let delay = max(0, exitStartMs / 1000 - Date.now.timeIntervalSince(timelineStart))
        AppDiagnostics.logInfo("启动覆盖窗口预提交淡出", fields: [
            "delayMs": .integer(Int64(delay * 1000)),
        ])
        layer.removeAnimation(forKey: Self.handoffAnimationKey)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + delay
        fade.duration = LaunchTimeline.exitDuration / 1000
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: Self.handoffAnimationKey)
    }

    private static let handoffAnimationKey = "launchHandoffFade"

    /// 兜底：预提交的淡出被 SwiftUI 的层重建摘掉了（`animation(forKey:)` 查不到）
    /// 才就地把整扇窗口 alpha 淡出。预提交动画还在（待播或正在播）时什么都不做
    /// ——不能看 presentation opacity：onExitStart 与动画 beginTime 同时到时
    /// presentation 还是 1，会被误判成「没生效」而叠一条冗余淡出。
    func beginHandoff() {
        guard let window, let layer = hostView?.layer else { return }
        guard layer.animation(forKey: Self.handoffAnimationKey) == nil else { return }
        AppDiagnostics.logWarning("启动覆盖窗口兜底淡出（预提交动画丢失）")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = LaunchTimeline.exitDuration / 1000
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }
    }

    private static func backdropColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(LaunchStyle.backdrop(for: isDark ? .dark : .light))
    }

    /// 主窗口圆角（macOS 26 实测 `NSWindow._cornerRadius` = 26pt）；全屏窗口不裁。
    private static func cornerRadius(of window: NSWindow) -> CGFloat {
        window.styleMask.contains(.fullScreen) ? 0 : 26
    }

    /// 交棒淡出结束（启动层 opacity 已到 0）时撤除覆盖层；主窗口关闭时也走这里
    /// 拆链（willClose），单例不滞留已关窗口。重复调用幂等。
    func dismiss() {
        guard let window else { return }
        let center = NotificationCenter.default
        for name in Self.parentFrameSyncNotifications {
            center.removeObserver(self, name: name, object: nil)
        }
        center.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        self.window = nil
        parent = nil
        hostView = nil
    }

    /// 主窗口 = `Window("OcPlayer", id: "main")` 的那扇。依次按 SwiftUI 场景标识
    /// （`id:` 若落在 `NSWindow.identifier`）、窗口标题匹配，最后退到 key 窗口；
    /// 覆盖窗口自身 title 为空，不会被误匹配。
    private static func mainWindow() -> NSWindow? {
        let shared = NSApplication.shared
        return shared.windows.first {
            $0.contentViewController != nil
                && ($0.identifier?.rawValue == "main" || $0.title == "OcPlayer")
        } ?? shared.keyWindow
    }
}
