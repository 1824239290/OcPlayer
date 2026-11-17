import CErika
import Foundation
import PlaybackKit

// Erika 的 C 事件模型 → PlaybackKit 的中立事件。
// 这个文件是纯映射层：一侧是 CErika，另一侧是 PlaybackKit，没有业务逻辑。

extension PlaybackState {
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

extension PlayerEvent {
    /// `nil` 表示 `ErikaEventKind_None`（内核给了个空事件，直接丢弃）。
    ///
    /// `errorMessage` 是 autoclosure：内核的错误文本存在**线程局部**槽位里，
    /// 必须在出错的那条线程上立刻取，所以调用点（`pollEvent`）就地读掉。
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
            self = .failed(code: Int32(bitPattern: raw.status.rawValue), message: errorMessage())
        default:
            return nil
        }
    }
}

extension PlaybackStats {
    /// Erika 的统计结构体字段远多于中立结构体，这里只取 App 侧调试行用到的那些。
    /// 需要 HDR / 音频恢复 / 升采样那些细项时，直接读 `ErikaEngine.latestErikaStats`。
    init(_ raw: ErikaPresenterStats) {
        self.init(
            decodedVideoFrames: raw.decoded_video_frames,
            renderedVideoFrames: raw.rendered_video_frames,
            hardwareVideoFrames: raw.hardware_video_frames,
            softwareVideoFrames: raw.software_video_frames,
            zeroCopyVideoFrames: raw.zero_copy_video_frames,
            pushedAudioFrames: raw.pushed_audio_frames,
            renderFailures: raw.render_failures,
            audioFailures: raw.audio_failures
        )
    }
}
