import Foundation
import JellyfinAPI

/// Jellyfin 播放进度上报（M2）：PlaybackStart → Progress（10s 心跳）→ Stopped。
/// 服务器据此记录 `UserData.PlaybackPositionTicks`，换设备续播靠它。
///
/// 上报是尽力而为：失败不影响播放（本地文件 / 离线时静默跳过）。
///
/// Jellyfin 的三个端点都接受 body 缺 `PlaySessionId`（SDK 的 `encodeIfPresent`
/// 会把 nil 整键省略）。Emby 不接受缺失，由 `EmbyServer` 自己合成 —— 见那里的
/// `resolvedPlaySessionID` 注释。
extension JellyfinServer {

    /// 秒 → Jellyfin tick（1 tick = 100 ns）。
    static func ticks(_ seconds: Double) -> Int {
        Int(seconds * 10_000_000)
    }

    /// 开始播放。
    public func reportPlaybackStart(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async {
        let session = context.playSessionID
        let body = PlaybackStateInfo(
            canSeek: true,
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playMethod: context.deliveryMethod.jellyfinValue,
            playSessionID: session,
            positionTicks: Self.ticks(positionSeconds),
            sessionID: session
        )
        do {
            _ = try await client.send(Paths.reportPlaybackStart(body))
        } catch {
            NetworkLog.reportFailed("PlaybackStart item=\(context.itemID)", error: error)
        }
    }

    /// 播放心跳（约 10 秒一次；暂停时也报，带 isPaused）。
    public func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        let session = context.playSessionID
        let body = PlaybackStateInfo(
            canSeek: true,
            isPaused: isPaused,
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playMethod: context.deliveryMethod.jellyfinValue,
            playSessionID: session,
            positionTicks: Self.ticks(positionSeconds),
            sessionID: session
        )
        do {
            _ = try await client.send(Paths.reportPlaybackProgress(body))
        } catch {
            NetworkLog.reportFailed("PlaybackProgress item=\(context.itemID)", error: error)
        }
    }

    /// 停止播放（退出播放器 / 换片）。服务器把 positionTicks 记成续播位置。
    public func reportPlaybackStopped(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async {
        let body = PlaybackStopInfo(
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playSessionID: context.playSessionID,
            positionTicks: Self.ticks(positionSeconds)
        )
        do {
            _ = try await client.send(Paths.reportPlaybackStopped(body))
        } catch {
            NetworkLog.reportFailed("PlaybackStopped item=\(context.itemID)", error: error)
        }
    }
}

private extension PlaybackDeliveryMethod {
    var jellyfinValue: PlayMethod {
        switch self {
        case .directPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcode
        }
    }
}
