import ErikaKit
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
    private(set) var isVisible = true

    /// 显隐动画。**必须**由改 `isVisible` 的这一侧带上：HUD 藏起来时是整棵子树被
    /// 卸载，`.transition` 的 removal 只认改状态那个 transaction 里的动画。把
    /// `.animation(_:value:)` 挂在容器上只能让「出现」渐变，「消失」会瞬间摘掉。
    ///
    /// nil = 不动画（减弱动态效果）。协调器拿不到 Environment，由视图解析后灌进来。
    @ObservationIgnored var motionAnimation: Animation? = .easeInOut(duration: 0.2)

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

    /// 唯一改 `isVisible` 的入口：带上动画 transaction，显隐两个方向都渐变。
    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        withAnimation(motionAnimation) { isVisible = visible }
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
