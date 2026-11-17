import PlaybackKit

/// HUD 显隐的两个判据。**拆开是有意的**，两者只差「缓冲」一项：
///
/// - `revealTrigger`：显隐触发。它变化 = 用户此刻需要看到控件（暂停 / 错误 / 字幕导入 /
///   弹幕选择 / 辅助功能 / 播放起止），这时才把 HUD 唤出来；
/// - `canAutoHide`：自动收起资格。缓冲期间为 false —— HUD 已经在屏上就留住，但
///   **不主动唤出**。
///
/// 此前两者合一（只有一个 `canAutoHideControls`）、且「变化即唤出」，于是每次缓冲
/// 起止都强弹一次 HUD，跟着弹出来的是全屏压暗遮罩（`PlayerHUDReadabilityScrim`）——
/// 网络抖动下就是用户报的「画面基本三十秒闪一次」（issue #2）。
struct PlayerHUDGates: Equatable {
    let revealTrigger: Bool
    let canAutoHide: Bool

    init(
        state: PlaybackState,
        isBuffering: Bool,
        setupError: String?,
        isImportingSubtitle: Bool,
        isSelectingDanmaku: Bool,
        isVoiceOverEnabled: Bool
    ) {
        let playerActive = state == .playing || state == .paused
        let blocked = setupError != nil
            || isImportingSubtitle
            || isSelectingDanmaku
            || isVoiceOverEnabled
        revealTrigger = playerActive && !blocked
        canAutoHide = revealTrigger && !isBuffering
    }
}
