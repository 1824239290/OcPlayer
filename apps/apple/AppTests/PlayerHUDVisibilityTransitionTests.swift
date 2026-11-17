import XCTest
@testable import OcPlayer

/// HUD 两阶段显隐过渡的竞态回归。
///
/// 复现路径（issue：窗口失焦→重获焦点、鼠标不在窗口内，HUD 永久常显）：
/// 窗口失焦时 AppKit 重估跟踪区，合成的 `mouseEntered` 先唤出 HUD（挂载、
/// `isVisible` 仍是 false、pending 16ms 淡入任务），几十毫秒后的 `mouseExited`
/// 触发 `hideOnPointerExit`——此时 `setVisible(false)` 被 `isVisible != visible`
/// 守卫吞掉，pending 淡入未被取消，稍后照样把 HUD 亮起；而隐藏计时已被清掉、
/// 鼠标不在窗口内，HUD 就此没有任何路径可再隐藏。
@MainActor
final class PlayerHUDVisibilityTransitionTests: XCTestCase {

    /// reveal 的「挂载未亮」过渡是 16ms，断言可见前等它落地。
    private func settleAfterReveal() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    /// 挂载未亮的过渡窗口内收到隐藏意图：淡入任务必须被取消并直接卸载，
    /// 不得稍后把 `isVisible` 拉回 true。
    func testHideDuringMountTransitionCancelsPendingFadeIn() async throws {
        let hud = PlayerHUDVisibilityCoordinator(autoHideDelay: .seconds(3))

        // 协调器初始即「挂载且可见」；先 hide 并等卸载任务（200ms）跑完，
        // 到达「已卸载」基态，reveal 才会走「挂载未亮」过渡。
        hud.hide()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(hud.isVisible)
        XCTAssertFalse(hud.isMounted)

        // reveal：进入「挂载未亮」过渡，16ms 后的淡入任务已排上。
        hud.reveal(canAutoHide: false)
        XCTAssertFalse(hud.isVisible)
        XCTAssertTrue(hud.isMounted)

        // 背靠背立即隐藏——主 actor 同步执行，必然落在 16ms 过渡窗口内。
        hud.hideOnPointerExit()
        XCTAssertFalse(hud.isVisible)
        XCTAssertFalse(hud.isMounted, "隐藏意图应取消 pending 淡入并直接卸载")

        // 若淡入任务没被取消，它会在这段等待里把 isVisible 拉回 true（即本 bug）。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(hud.isVisible, "pending 淡入任务把 HUD 亮了回来")
        XCTAssertFalse(hud.isMounted)
    }

    /// 淡出中途重复隐藏仍是幂等 no-op：不能把 pending 卸载任务提前打断，
    /// 否则淡出动画会被截断。
    func testRepeatedHideDuringFadeOutIsNoOp() async throws {
        let hud = PlayerHUDVisibilityCoordinator(autoHideDelay: .seconds(3))

        hud.reveal(canAutoHide: false)
        try await settleAfterReveal()
        XCTAssertTrue(hud.isVisible)
        XCTAssertTrue(hud.isMounted)

        hud.hide()
        XCTAssertFalse(hud.isVisible)
        XCTAssertTrue(hud.isMounted, "淡出动画期间应保持挂载")

        // 淡出中途（unmountDelay 默认 200ms 内）再次隐藏：无操作。
        hud.hide()
        XCTAssertFalse(hud.isVisible)

        // 卸载任务到点后正常完成。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(hud.isMounted)
        XCTAssertFalse(hud.isVisible)
    }

    /// 淡出中途唤出：直接反转为可见（原有行为，防止修复波及）。
    func testRevealDuringFadeOutReversesToVisible() async throws {
        let hud = PlayerHUDVisibilityCoordinator(autoHideDelay: .seconds(3))

        hud.reveal(canAutoHide: false)
        try await settleAfterReveal()
        XCTAssertTrue(hud.isVisible)

        hud.hide()
        XCTAssertFalse(hud.isVisible)
        XCTAssertTrue(hud.isMounted, "淡出动画期间应保持挂载")

        hud.reveal(canAutoHide: false)
        XCTAssertTrue(hud.isVisible)
        XCTAssertTrue(hud.isMounted)
    }
}
