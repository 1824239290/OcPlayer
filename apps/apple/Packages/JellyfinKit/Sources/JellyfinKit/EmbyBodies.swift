import Foundation

// Emby 的请求体。
//
// 显式写出 `CodingKeys` 而不是复用 SDK 的 `PlaybackStateInfo` / `DeviceProfile`：
// Emby 侧刻意不依赖 `jellyfin-sdk-swift`（见 `MediaServer` 的文档注释），
// 而字段名两家同形，写死在这里反而更稳。

/// `/Sessions/Playing` 与 `/Sessions/Playing/Progress` 的请求体。
/// `PlaySessionId` 与 `SessionId` 同值，对齐 Swiftfin 的上报形状。
struct EmbyPlaybackStateBody: Encodable {
    let canSeek: Bool
    let itemID: String
    let mediaSourceID: String?
    let playMethod: String?
    let playSessionID: String?
    let positionTicks: Int
    let sessionID: String?
    let isPaused: Bool?

    enum CodingKeys: String, CodingKey {
        case canSeek = "CanSeek"
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playMethod = "PlayMethod"
        case playSessionID = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case sessionID = "SessionId"
        case isPaused = "IsPaused"
    }
}

/// `/Sessions/Playing/Stopped` 的请求体。服务器把 positionTicks 记成续播位置。
struct EmbyPlaybackStopBody: Encodable {
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let positionTicks: Int

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case mediaSourceID = "MediaSourceId"
        case playSessionID = "PlaySessionId"
        case positionTicks = "PositionTicks"
    }
}

/// `POST /Items/{id}/PlaybackInfo` 的请求体。
/// 目标：能直连的尽量直连，不让服务端主动转码（`EnableTranscoding: false`）。
struct EmbyPlaybackInfoBody: Encodable {
    let allowAudioStreamCopy = true
    let allowVideoStreamCopy = true
    let enableDirectPlay = true
    let enableDirectStream = true
    let enableTranscoding = false
    let userID: String
    let deviceProfile = EmbyDeviceProfile()

    enum CodingKeys: String, CodingKey {
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case userID = "UserId"
        case deviceProfile = "DeviceProfile"
    }
}

/// 当前客户端声明支持的直连能力。与 Jellyfin 侧 `directPlayDeviceProfile`
/// 同一份能力（同形结构，只是不经过 SDK 类型）。
struct EmbyDeviceProfile: Encodable {
    struct DirectPlayProfile: Encodable {
        let audioCodec: String?
        let container: String?
        let type: String
        let videoCodec: String?

        enum CodingKeys: String, CodingKey {
            case audioCodec = "AudioCodec"
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
        }
    }

    let directPlayProfiles = [
        DirectPlayProfile(
            audioCodec: "aac,ac3,eac3,dts,truehd,flac,opus",
            container: "mkv,mp4,ts,m2ts",
            type: "Video",
            videoCodec: "h264,hevc,av1,vc1"
        ),
        DirectPlayProfile(
            audioCodec: nil,
            container: "mp4,m4a,flac,opus,aac,ac3,eac3",
            type: "Audio",
            videoCodec: nil
        ),
    ]
    let maxStreamingBitrate = 120_000_000
    let name = "OcPlayer"

    enum CodingKeys: String, CodingKey {
        case directPlayProfiles = "DirectPlayProfiles"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case name = "Name"
    }
}

/// `POST /Items/{id}/PlaybackInfo` 的响应。
struct EmbyPlaybackInfoDTO: Decodable, Sendable {
    var playSessionId: String?
    var mediaSources: [EmbyMediaSourceDTO]?
}

extension PlaybackDeliveryMethod {
    /// 上报体的 `PlayMethod` 串。两家的值域相同。
    var wireValue: String {
        switch self {
        case .directPlay: "DirectPlay"
        case .directStream: "DirectStream"
        case .transcode: "Transcode"
        }
    }
}
