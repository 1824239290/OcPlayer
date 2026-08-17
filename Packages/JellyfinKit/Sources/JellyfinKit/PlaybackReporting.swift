import Foundation
import JellyfinAPI

/// Jellyfin 播放进度上报（M2）：PlaybackStart → Progress（10s 心跳）→ Stopped。
/// 服务器据此记录 `UserData.PlaybackPositionTicks`，换设备续播靠它。
///
/// 上报是尽力而为：失败不影响播放（本地文件 / 离线时静默跳过）。
extension JellyfinServer {

    /// 秒 → Jellyfin tick（1 tick = 100 ns）。
    static func ticks(_ seconds: Double) -> Int {
        Int(seconds * 10_000_000)
    }

    /// 开始播放。
    public func reportPlaybackStart(itemID: String, positionSeconds: Double) async {
        let body = PlaybackStateInfo(
            canSeek: true,
            itemID: itemID,
            playMethod: .directPlay,
            positionTicks: Self.ticks(positionSeconds)
        )
        try? await client.send(Paths.reportPlaybackStart(body))
    }

    /// 播放心跳（约 10 秒一次；暂停时也报，带 isPaused）。
    public func reportPlaybackProgress(itemID: String, positionSeconds: Double, isPaused: Bool) async {
        let body = PlaybackStateInfo(
            canSeek: true,
            isPaused: isPaused,
            itemID: itemID,
            playMethod: .directPlay,
            positionTicks: Self.ticks(positionSeconds)
        )
        try? await client.send(Paths.reportPlaybackProgress(body))
    }

    /// 停止播放（退出播放器 / 换片）。服务器把 positionTicks 记成续播位置。
    public func reportPlaybackStopped(itemID: String, positionSeconds: Double) async {
        let body = PlaybackStopInfo(
            itemID: itemID,
            positionTicks: Self.ticks(positionSeconds)
        )
        try? await client.send(Paths.reportPlaybackStopped(body))
    }
}
