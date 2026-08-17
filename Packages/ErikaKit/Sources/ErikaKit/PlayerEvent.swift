import CErika
import Foundation

/// 播放状态。与 `ErikaState` 一一对应，但不让内核枚举漏到 UI 层。
public enum PlaybackState: Sendable, Hashable {
    case idle, opening, ready, playing, paused, stopped, closed, error

    init(_ raw: ErikaState) {
        switch raw {
        case ErikaState_Opening: self = .opening
        case ErikaState_Ready: self = .ready
        case ErikaState_Playing: self = .playing
        case ErikaState_Paused: self = .paused
        case ErikaState_Stopped: self = .stopped
        case ErikaState_Closed: self = .closed
        case ErikaState_Error: self = .error
        default: self = .idle
        }
    }
}

public struct VideoParams: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// 色彩原色 / 传输函数的原始编码值（AVCol* 语义），HDR 判定用。
    public let primaries: UInt32
    public let transfer: UInt32

    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 16.0 / 9.0
    }
}

public struct TrackCounts: Sendable, Hashable {
    public let video: Int
    public let audio: Int
    public let subtitle: Int
}

/// 从内核轮询出来的事件。已经脱离内核内存，可跨线程传递。
public enum PlayerEvent: Sendable {
    case stateChanged(PlaybackState)
    case durationChanged(Duration)
    case positionChanged(Duration)
    case tracksChanged(TrackCounts)
    case bufferingChanged(Bool)
    case videoParamsChanged(VideoParams)
    case surfaceAttached
    case surfaceDetached
    case videoDecoderChanged
    case audioOutputChanged
    /// 用户选轨生效（音轨 / 字幕轨）。UI 据此重拉轨道列表拿新的 selected。
    case trackSelectionChanged
    /// 内核报错。`message` 只有在出错的那条线程上立刻取才拿得到，所以在 tick 线程里就读好。
    case failed(status: ErikaStatus, message: String?)

    /// `nil` 表示 `ErikaEventKind_None`（内核给了个空事件，直接丢弃）。
    init?(_ raw: ErikaEvent, errorMessage: @autoclosure () -> String?) {
        switch raw.kind {
        case ErikaEventKind_StateChanged:
            self = .stateChanged(PlaybackState(raw.state))
        case ErikaEventKind_DurationChanged:
            self = .durationChanged(.microseconds(max(0, raw.duration_micros)))
        case ErikaEventKind_PositionChanged:
            self = .positionChanged(.microseconds(Int64(clamping: raw.position_micros)))
        case ErikaEventKind_TracksChanged:
            self = .tracksChanged(TrackCounts(video: Int(raw.tracks.video),
                                              audio: Int(raw.tracks.audio),
                                              subtitle: Int(raw.tracks.subtitle)))
        case ErikaEventKind_BufferingChanged:
            self = .bufferingChanged(raw.buffering)
        case ErikaEventKind_VideoParamsChanged:
            self = .videoParamsChanged(VideoParams(width: Int(raw.video.width),
                                                   height: Int(raw.video.height),
                                                   primaries: raw.video.primaries,
                                                   transfer: raw.video.transfer))
        case ErikaEventKind_SurfaceAttached:
            self = .surfaceAttached
        case ErikaEventKind_SurfaceDetached:
            self = .surfaceDetached
        case ErikaEventKind_VideoDecoderChanged:
            self = .videoDecoderChanged
        case ErikaEventKind_AudioOutputChanged:
            self = .audioOutputChanged
        case ErikaEventKind_TrackSelectionChanged:
            self = .trackSelectionChanged
        case ErikaEventKind_Error:
            self = .failed(status: raw.status, message: errorMessage())
        default:
            return nil
        }
    }
}

/// 打开一个媒体源。`headers` 直接落到 `erika_presenter_open_with_headers`，
/// Jellyfin 的 token 走这里，不进 URL（日志不泄露）。
public struct PlaybackSource: Sendable, Hashable {
    public let uri: String
    public let headers: [String: String]

    public init(uri: String, headers: [String: String] = [:]) {
        self.uri = uri
        self.headers = headers
    }

    public init(fileURL: URL, headers: [String: String] = [:]) {
        self.init(uri: fileURL.isFileURL ? fileURL.path : fileURL.absoluteString, headers: headers)
    }
}
