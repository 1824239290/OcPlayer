import PlaybackKit
import XCTest
@testable import OcPlayer

/// HUD 显隐判据与「缓冲不唤出 HUD」的回归（issue #2：网络抖动时全屏暗幕跟着闪）。
@MainActor
final class PlayerHUDGatesTests: XCTestCase {

    private func gates(
        state: PlaybackState,
        isBuffering: Bool = false,
        setupError: String? = nil,
        isImportingSubtitle: Bool = false,
        isSelectingDanmaku: Bool = false,
        isVoiceOverEnabled: Bool = false
    ) -> PlayerHUDGates {
        PlayerHUDGates(
            state: state,
            isBuffering: isBuffering,
            setupError: setupError,
            isImportingSubtitle: isImportingSubtitle,
            isSelectingDanmaku: isSelectingDanmaku,
            isVoiceOverEnabled: isVoiceOverEnabled
        )
    }

    // MARK: - 判据

    /// 核心回归：缓冲**只**改「能不能自动收起」，绝不动「该不该唤出」。
    /// 两者一旦合一，每轮缓冲起止都会强弹一次 HUD（含全屏压暗遮罩）= 用户看到的闪屏。
    func testBufferingOnlyRevokesAutoHide() {
        let playing = gates(state: .playing)
        let buffering = gates(state: .playing, isBuffering: true)

        XCTAssertTrue(playing.revealTrigger)
        XCTAssertTrue(playing.canAutoHide)

        XCTAssertTrue(buffering.revealTrigger, "缓冲不该进唤出判据")
        XCTAssertFalse(buffering.canAutoHide, "缓冲期间不自动收起（HUD 在屏上就留住）")
    }

    /// 暂停不改变任何判据：暂停的 HUD 由交互路径唤出，不走这条规则。
    func testPauseKeepsBothGatesUnchanged() {
        let playing = gates(state: .playing)
        let paused = gates(state: .paused)

        XCTAssertEqual(paused, playing)
    }

    /// 需要用户看到控件的状态变化：翻唤出判据（也顺带翻收起资格）。
    func testBlockingConditionsFlipRevealTrigger() {
        XCTAssertFalse(gates(state: .playing, setupError: "解析失败").revealTrigger)
        XCTAssertFalse(gates(state: .playing, isImportingSubtitle: true).revealTrigger)
        XCTAssertFalse(gates(state: .playing, isSelectingDanmaku: true).revealTrigger)
        XCTAssertFalse(gates(state: .playing, isVoiceOverEnabled: true).revealTrigger)
    }

    /// 起播与结束/出错：两个判据一起翻（结束/出错时该把控件露出来）。
    func testPlayerLifecycleFlipsBothGates() {
        for state: PlaybackState in [.idle, .opening, .ready, .stopped, .error] {
            let value = gates(state: state)
            XCTAssertFalse(value.revealTrigger, "\(state) 不该触发唤出")
            XCTAssertFalse(value.canAutoHide, "\(state) 不该允许自动收起")
        }
    }

    // MARK: - 协调器：只续期，不弹窗

    /// 缓冲期间取消待收起；恢复后按正常延时重新计时。
    func testRefreshAutoHideHoldsVisibleThenResumes() async throws {
        let hud = PlayerHUDVisibilityCoordinator(autoHideDelay: .milliseconds(40))
        XCTAssertTrue(hud.isVisible, "HUD 初值可见")

        hud.refreshAutoHide(canAutoHide: false)      // 进缓冲：只取消收起
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(hud.isVisible, "缓冲期间不自动收起")

        hud.refreshAutoHide(canAutoHide: true)       // 缓冲结束：恢复计时
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(hud.isVisible, "恢复后按正常延时收起")
    }

    /// 已经收起的 HUD 不会因为缓冲起止被弹出来（issue #2 的直接回归）。
    func testRefreshAutoHideNeverPopsHiddenHUD() async throws {
        let hud = PlayerHUDVisibilityCoordinator(autoHideDelay: .milliseconds(20))
        hud.hide()
        XCTAssertFalse(hud.isVisible)

        hud.refreshAutoHide(canAutoHide: false)
        hud.refreshAutoHide(canAutoHide: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(hud.isVisible, "缓冲起止不该唤出 HUD")
    }
}
