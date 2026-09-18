import Foundation
import JellyfinAPI

/// Jellyfin 播放进度上报（M2）：PlaybackStart → Progress（10s 心跳）→ Stopped。
/// 服务器据此记录 `UserData.PlaybackPositionTicks`，换设备续播靠它。
///
/// 上报是尽力而为：失败不影响播放（本地文件 / 离线时静默跳过）。
///
/// **Emby 会话 id 兜底**：`/Sessions/Playing` 与 `/Sessions/Playing/Progress`
/// 在 body 缺 `PlaySessionId` 时必拒 400（`Value cannot be null.
/// (Parameter 'key')`，plezy 实测 Emby 4.9.5；OhMyCine 记录了同病症），
/// `/Sessions/Playing/Stopped` 容忍缺失；Jellyfin 三个端点都接受缺失。
/// 回退直连等拿不到协商会话的场景（`PlaybackInfo` 失败 → 裸 URL 播放）
/// 以前在这台服务器上 100% 400——续播位置全部丢失。所以只对 Emby 档案、
/// 且没有协商会话时按 `itemId` 合成一个**确定性** id：同一 item 的
/// start/progress/stopped 三段落在服务端同一会话行（照 plezy 的
/// `_resolvePlaySessionId` 模式）。Jellyfin 档案一字不动。
extension JellyfinServer {

    /// 秒 → Jellyfin tick（1 tick = 100 ns）。
    static func ticks(_ seconds: Double) -> Int {
        Int(seconds * 10_000_000)
    }

    /// 上报 body 的会话 id：协商过用协商值；Emby 档案没协商过则合成；
    /// Jellyfin 档案没协商过保持 nil（SDK `encodeIfPresent` 会把 nil 整键省略）。
    ///
    /// 合成必须确定性（itemId 派生）而非随机：随机 id 会让同一片源的
    /// start / progress / stopped 在服务端散成三条孤儿会话。
    func resolvedPlaySessionID(_ context: PlaybackSessionContext) -> String? {
        if let session = context.playSessionID { return session }
        guard profile.kind == .emby else { return nil }
        return "ocplayer-\(context.itemID)"
    }

    /// 开始播放。
    public func reportPlaybackStart(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async {
        let session = resolvedPlaySessionID(context)
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

    /// Compatibility entry point for callers that did not obtain PlaybackInfo.
    public func reportPlaybackStart(itemID: String, positionSeconds: Double) async {
        await reportPlaybackStart(
            context: PlaybackSessionContext(itemID: itemID),
            positionSeconds: positionSeconds
        )
    }

    /// 播放心跳（约 10 秒一次；暂停时也报，带 isPaused）。
    public func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        let session = resolvedPlaySessionID(context)
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

    /// Compatibility entry point for callers that did not obtain PlaybackInfo.
    public func reportPlaybackProgress(
        itemID: String,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        await reportPlaybackProgress(
            context: PlaybackSessionContext(itemID: itemID),
            positionSeconds: positionSeconds,
            isPaused: isPaused
        )
    }

    /// 停止播放（退出播放器 / 换片）。服务器把 positionTicks 记成续播位置。
    public func reportPlaybackStopped(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async {
        let body = PlaybackStopInfo(
            itemID: context.itemID,
            mediaSourceID: context.mediaSourceID,
            playSessionID: resolvedPlaySessionID(context),
            positionTicks: Self.ticks(positionSeconds)
        )
        do {
            _ = try await client.send(Paths.reportPlaybackStopped(body))
        } catch {
            NetworkLog.reportFailed("PlaybackStopped item=\(context.itemID)", error: error)
        }
    }

    /// Compatibility entry point for callers that did not obtain PlaybackInfo.
    public func reportPlaybackStopped(itemID: String, positionSeconds: Double) async {
        await reportPlaybackStopped(
            context: PlaybackSessionContext(itemID: itemID),
            positionSeconds: positionSeconds
        )
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
