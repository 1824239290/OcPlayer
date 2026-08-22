import PlaybackKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

enum PlayerHUDInteraction: Hashable {
    case volumeDrag
    case timelineDrag
    case menuTracking
}

/// HUD 的显示计时不属于视图状态。鼠标坐标和 Task 都不参与 Observation，
/// 窗口移动时只重排视频，不会连带整套 Liquid Glass 反复失效。
@MainActor
@Observable
final class PlayerHUDVisibilityCoordinator {
    /// 是否**可见**：控制 `.opacity`，驱动淡入淡出动画（macOS 上 `.opacity`
    /// 属性动画两个方向都可靠，见 PlayerScreen 注释）。
    private(set) var isVisible = true
    /// 是否**挂载**：控制 `if` 卸载。和 `isVisible` 错开一拍——隐藏时先淡出
    /// （isVisible 变 false），动画跑完再把 isMounted 置 false 真正卸载；
    /// 显示时先挂载再淡入。这样既拿到卸载的性能收益，淡出动画也完整。
    private(set) var isMounted = true

    /// 显隐动画档位。**由容器**（PlayerScreen 的 `.animation(value: isVisible)`）
    /// 驱动 `.opacity` 属性动画。这里同时用它决定卸载延时——动画多长就等多久。
    ///
    /// nil = 不动画（减弱动态效果）。协调器拿不到 Environment，由视图解析后灌进来。
    @ObservationIgnored var motionAnimation: Animation? = .easeInOut(duration: 0.2)

    /// 卸载延时：和动画时长一致，动画跑完才真正卸载。reduceMotion（无动画）
    /// 时为 0，直接卸载。由视图随 motionAnimation 一起注入。
    @ObservationIgnored var unmountDelay: Duration = .milliseconds(200)

    /// 显隐过渡任务：淡出后卸载、或挂载后淡入，都用这一个槽位互斥持有。
    /// 任何新的显隐意图先取消它，避免竞态（例如淡入前又触发隐藏）。
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    @ObservationIgnored private var activeInteractions: Set<PlayerHUDInteraction> = []
    @ObservationIgnored private var trackedMenus: Set<ObjectIdentifier> = []
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hideDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var scheduledWake: ContinuousClock.Instant?
    @ObservationIgnored private var hideScheduleID = 0
    @ObservationIgnored private var lastPointerLocation: CGPoint?
    /// 用户主动点击关闭 HUD 后置 true：鼠标移动不再自动唤出，要再点一下才打开。
    /// 自动隐藏（计时到点）不置位，所以自动隐藏后滑动仍能唤出。
    @ObservationIgnored private var userHidden = false

    @ObservationIgnored private let clock = ContinuousClock()
    private let autoHideDelay: Duration

    init(autoHideDelay: Duration = .seconds(3)) {
        self.autoHideDelay = autoHideDelay
    }

    func reveal(canAutoHide: Bool) {
        // 任何主动显示都解除「用户关闭」锁定。
        userHidden = false
        setVisible(true)
        scheduleHide(after: autoHideDelay, canAutoHide: canAutoHide)
    }

    func hide() {
        cancelScheduledHide()
        setVisible(false)
        // 用户主动关闭：标记锁定，鼠标移动不再自动唤出（要再点一下才打开）。
        userHidden = true
    }

    /// 唯一改可见/挂载的入口，两阶段：
    /// - 显示：若已卸载（isMounted=false）先挂载再淡入；若还在淡出中途
    ///   （isMounted=true, isVisible=false）直接反转为可见——动画平滑反向。
    /// - 隐藏：先淡出（isVisible 变 false），动画跑完（unmountDelay）再卸载；
    ///   无动画（unmountDelay 为 0）时直接卸载。
    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        if visible {
            transitionTask?.cancel()
            transitionTask = nil
            if isMounted {
                // 淡出中途唤出：直接反转，容器动画会把透明度平滑拉回。
                isVisible = true
            } else {
                // 已卸载：先挂载（透明），下一帧再变亮出淡入——同帧挂载+变亮
                // SwiftUI 看不到中间态。槽位互斥：若淡入前又触发隐藏，
                // transitionTask 会被取消，不会误亮。
                isMounted = true
                transitionTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(16))
                    guard let self, self.isVisible == false else { return }
                    self.isVisible = true
                    self.transitionTask = nil
                }
            }
        } else {
            isVisible = false
            transitionTask?.cancel()
            transitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.unmountDelay ?? .zero)
                guard let self, self.isVisible == false else { return }
                self.isMounted = false
                self.transitionTask = nil
            }
        }
    }

    func setInteraction(
        _ interaction: PlayerHUDInteraction,
        active: Bool,
        canAutoHide: Bool
    ) {
        if active {
            activeInteractions.insert(interaction)
        } else {
            activeInteractions.remove(interaction)
        }
        reveal(canAutoHide: canAutoHide && activeInteractions.isEmpty)
    }

    /// 原生 Menu 没有公开 isPresented；打开菜单时给足停留时间，选中动作后会恢复正常计时。
    func holdForMenu(canAutoHide: Bool) {
        setVisible(true)
        scheduleHide(after: .seconds(30), canAutoHide: canAutoHide)
    }

    func pointerMoved(to location: CGPoint, canAutoHide: Bool) {
        // 用户主动关闭期间，鼠标移动不唤出（要点击才重新打开）。
        guard !userHidden else { return }
        guard location != lastPointerLocation else { return }
        lastPointerLocation = location
        reveal(canAutoHide: canAutoHide && activeInteractions.isEmpty)
    }

    func pointerExited() {
        lastPointerLocation = nil
    }

    /// 鼠标移出窗口：收起 HUD，但**不置 `userHidden` 锁定**——鼠标移回窗口时
    /// 移动仍能唤出（区别于用户主动点关闭的 `hide()`，那个要再点一下才开）。
    func hideOnPointerExit() {
        guard !userHidden else { return }
        cancelScheduledHide()
        setVisible(false)
    }

    /// SwiftUI Menu 没有公开 isPresented；macOS 用 NSMenu tracking 通知补齐真实生命周期。
    /// 用集合而不是 Bool，嵌套的倍速子菜单结束时不会提前释放父菜单的暂停状态。
    func menuTrackingDidBegin(_ menu: AnyObject, canAutoHide: Bool) {
        trackedMenus.insert(ObjectIdentifier(menu))
        setInteraction(.menuTracking, active: true, canAutoHide: canAutoHide)
    }

    func menuTrackingDidEnd(_ menu: AnyObject, canAutoHide: Bool) {
        trackedMenus.remove(ObjectIdentifier(menu))
        guard trackedMenus.isEmpty else {
            reveal(canAutoHide: false)
            return
        }
        setInteraction(.menuTracking, active: false, canAutoHide: canAutoHide)
    }

    func cancel() {
        cancelScheduledHide()
        transitionTask?.cancel()
        transitionTask = nil
        activeInteractions.removeAll()
        trackedMenus.removeAll()
        lastPointerLocation = nil
        userHidden = false
    }

    private func scheduleHide(after delay: Duration, canAutoHide: Bool) {
        guard canAutoHide, activeInteractions.isEmpty else {
            cancelScheduledHide()
            return
        }

        let deadline = clock.now.advanced(by: delay)
        hideDeadline = deadline

        // 鼠标连续移动通常只会把截止时间往后延。保留当前 sleeper，等它醒来后
        // 再睡到最新 deadline，避免每个像素都取消并创建一个新 Task。
        if let scheduledWake, hideTask != nil, deadline >= scheduledWake {
            return
        }

        startHideTask(wakingAt: deadline)
    }

    private func startHideTask(wakingAt firstWake: ContinuousClock.Instant) {
        hideScheduleID &+= 1
        let scheduleID = hideScheduleID
        hideTask?.cancel()
        scheduledWake = firstWake

        hideTask = Task { @MainActor [weak self] in
            var wake = firstWake
            while let self, !Task.isCancelled {
                do {
                    try await self.clock.sleep(until: wake)
                } catch {
                    break
                }
                guard scheduleID == self.hideScheduleID,
                      self.activeInteractions.isEmpty,
                      let latestDeadline = self.hideDeadline
                else {
                    break
                }

                if self.clock.now < latestDeadline {
                    wake = latestDeadline
                    self.scheduledWake = latestDeadline
                    continue
                }

                self.setVisible(false)
                self.hideDeadline = nil
                self.scheduledWake = nil
                self.hideTask = nil
                return
            }

            guard let self, scheduleID == self.hideScheduleID else { return }
            self.hideTask = nil
            self.hideDeadline = nil
            self.scheduledWake = nil
        }
    }

    private func cancelScheduledHide() {
        guard hideTask != nil || hideDeadline != nil || scheduledWake != nil else { return }
        hideScheduleID &+= 1
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        scheduledWake = nil
    }
}

/// Infuse 式 HUD：对比度由单一全屏暗幕保证，Glass 只用于少量工具分组。
