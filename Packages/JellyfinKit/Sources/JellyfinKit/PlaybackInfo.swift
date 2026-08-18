import CoreModel
import Foundation
import Get
import JellyfinAPI

/// PlaybackInfo 返回的单个 MediaSource 域模型。
public struct PlaybackMediaSource: Hashable, Sendable {
    public let id: String
    public let name: String?
    public let path: String?
    public let size: Int?
    public let container: String?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let supportsTranscoding: Bool?
    public let bitrate: Int?
    public let runTimeSeconds: Double?

    init(_ source: MediaSourceInfo, fallbackID: String) {
        self.id = source.id ?? fallbackID
        self.name = source.name
        self.path = source.path
        self.size = source.size
        self.container = source.container
        self.supportsDirectPlay = source.isSupportsDirectPlay
        self.supportsDirectStream = source.isSupportsDirectStream
        self.supportsTranscoding = source.isSupportsTranscoding
        self.bitrate = source.bitrate
        self.runTimeSeconds = source.runTimeTicks.map { Double($0) / 10_000_000 }
    }
}

public enum PlaybackDeliveryMethod: String, Hashable, Sendable {
    case directPlay
    case directStream
    case transcode
}

/// A single Jellyfin playback session carried from PlaybackInfo through the
/// player request and every playback report. The media-source metadata is also
/// the stable input used by later episode matching (for example, danmaku).
public struct PlaybackSessionContext: Hashable, Sendable {
    public let itemID: String
    public let playSessionID: String?
    public let mediaSourceID: String?
    public let mediaSourceName: String?
    public let mediaSourcePath: String?
    public let mediaSourceSize: Int?
    public let durationSeconds: Double?
    public let deliveryMethod: PlaybackDeliveryMethod

    public init(
        itemID: String,
        playSessionID: String? = nil,
        mediaSourceID: String? = nil,
        mediaSourceName: String? = nil,
        mediaSourcePath: String? = nil,
        mediaSourceSize: Int? = nil,
        durationSeconds: Double? = nil,
        deliveryMethod: PlaybackDeliveryMethod = .directPlay
    ) {
        self.itemID = itemID
        self.playSessionID = playSessionID
        self.mediaSourceID = mediaSourceID
        self.mediaSourceName = mediaSourceName
        self.mediaSourcePath = mediaSourcePath
        self.mediaSourceSize = mediaSourceSize
        self.durationSeconds = durationSeconds
        self.deliveryMethod = deliveryMethod
    }
}

/// `/Items/{id}/PlaybackInfo` 的收口结果，避免 JellyfinAPI 类型漏到 App 层。
public struct PlaybackInfo: Hashable, Sendable {
    public let playSessionID: String?
    public let mediaSources: [PlaybackMediaSource]

    init(playSessionID: String?, mediaSources: [PlaybackMediaSource]) {
        self.playSessionID = playSessionID
        self.mediaSources = mediaSources
    }

    public func sessionContext(
        itemID: String,
        selectedSource: PlaybackMediaSource?
    ) -> PlaybackSessionContext {
        PlaybackSessionContext(
            itemID: itemID,
            playSessionID: playSessionID,
            mediaSourceID: selectedSource?.id,
            mediaSourceName: selectedSource?.name,
            mediaSourcePath: selectedSource?.path,
            mediaSourceSize: selectedSource?.size,
            durationSeconds: selectedSource?.runTimeSeconds,
            deliveryMethod: Self.deliveryMethod(for: selectedSource)
        )
    }

    private static func deliveryMethod(
        for source: PlaybackMediaSource?
    ) -> PlaybackDeliveryMethod {
        if source?.supportsDirectPlay == true { return .directPlay }
        if source?.supportsDirectStream == true { return .directStream }
        if source?.supportsTranscoding == true { return .transcode }
        return .directPlay
    }
}

extension JellyfinServer {

    /// 当前客户端声明支持的直连能力。
    /// 目标：能直连的尽量直连，不让服务端主动转码。
    static var directPlayDeviceProfile: DeviceProfile {
        DeviceProfile(
            directPlayProfiles: [
                DirectPlayProfile(
                    audioCodec: "aac,ac3,eac3,dts,truehd,flac,opus",
                    container: "mkv,mp4,ts,m2ts",
                    type: .video,
                    videoCodec: "h264,hevc,av1,vc1"
                ),
                DirectPlayProfile(
                    container: "mp4,m4a,flac,opus,aac,ac3,eac3",
                    type: .audio
                ),
            ],
            maxStreamingBitrate: 120_000_000,
            name: "OcPlayer"
        )
    }

    /// 获取条目 PlaybackInfo，带回可用的 MediaSource 列表。
    /// 使用 POST + DeviceProfile，让服务端按 OcPlayer 的直连能力返回播放信息。
    public func playbackInfo(itemID: String) async throws -> PlaybackInfo {
        let dto = PlaybackInfoDto(
            allowAudioStreamCopy: true,
            allowVideoStreamCopy: true,
            deviceProfile: Self.directPlayDeviceProfile,
            enableDirectPlay: true,
            enableDirectStream: true,
            enableTranscoding: false,
            userID: profile.userID
        )
        let request = Request<PlaybackInfoResponse>(
            path: "/Items/\(itemID)/PlaybackInfo",
            method: .post,
            query: [("userId", profile.userID)],
            body: dto,
            id: "GetPlaybackInfo"
        )
        let response = try await send(request)
        let sources = (response.mediaSources ?? []).map {
            PlaybackMediaSource($0, fallbackID: itemID)
        }
        return PlaybackInfo(playSessionID: response.playSessionID, mediaSources: sources)
    }
}
