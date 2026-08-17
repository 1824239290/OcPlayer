import CErika
import Foundation
import Observation
import os

/// UI 只读的播放快照。事件流在 `start()` 里被独占消费，逐条折叠成属性。
@MainActor
@Observable
public final class PlayerState {
    public private(set) var state: PlaybackState = .idle
    public private(set) var position: Duration = .zero
    public private(set) var duration: Duration = .zero
    public private(set) var isBuffering = false
    public private(set) var videoParams: VideoParams?
    public private(set) var trackCounts = TrackCounts(video: 0, audio: 0, subtitle: 0)
    public private(set) var hasSurface = false
    /// 轨道列表（音轨 / 字幕菜单用）。事件流里 tracks 数量变化或选轨生效时自动重拉。
    public private(set) var audioTracks: [TrackInfo] = []
    public private(set) var subtitleTracks: [TrackInfo] = []
    /// 最近一条内核错误，UI 可以显示后自行清掉。
    public private(set) var lastError: String?

    public var progress: Double {
        let total = duration.microseconds
        guard total > 0 else { return 0 }
        return min(max(Double(position.microseconds) / Double(total), 0), 1)
    }

    public init() {}

    /// 开始消费某个引擎的事件流。调用方持有返回的 `Task` 决定生命周期。
    @discardableResult
    public func start(consuming engine: ErikaEngine) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in engine.events {
                guard let self else { return }
                self.apply(event)
                switch event {
                case .tracksChanged, .trackSelectionChanged:
                    // 轨道 / 选择变了：重拉列表（锁化 C 调用，很快）
                    self.refreshTracks(from: engine)
                default:
                    break
                }
            }
        }
    }

    /// 换源 / 手动选轨后由 `PlaybackController` 显式调用。
    public func refreshTracks(from engine: ErikaEngine) {
        guard let all = try? engine.tracks() else { return }
        audioTracks = all.filter { $0.kind == .audio }
        subtitleTracks = all.filter { $0.kind == .subtitle }
    }

    public func clearError() { lastError = nil }

    /// 换源时复位快照，避免旧内容的 position / duration / 轨道 / 错误残留到新源。
    /// surface 归 surface（视图一直挂着），这里只管媒体相关的状态。
    public func reset() {
        state = .idle
        position = .zero
        duration = .zero
        isBuffering = false
        videoParams = nil
        trackCounts = TrackCounts(video: 0, audio: 0, subtitle: 0)
        audioTracks = []
        subtitleTracks = []
        lastError = nil
    }

    func apply(_ event: PlayerEvent) {
        switch event {
        case .stateChanged(let value):
            state = value
        case .positionChanged(let value):
            position = value
        case .durationChanged(let value):
            duration = value
        case .bufferingChanged(let value):
            isBuffering = value
        case .videoParamsChanged(let value):
            videoParams = value
        case .tracksChanged(let value):
            trackCounts = value
        case .surfaceAttached:
            hasSurface = true
        case .surfaceDetached:
            hasSurface = false
        case .videoDecoderChanged, .audioOutputChanged, .trackSelectionChanged:
            break
        case .failed(let status, let message):
            erikaLog.error("内核错误事件 status=\(status.rawValue) message=\(message ?? "nil", privacy: .public)")
            PlaybackLog.append("内核错误事件 status=\(status.rawValue) message=\(message ?? "nil")")
            state = .error
            lastError = message ?? "内核错误 status=\(status.rawValue)"
        }
    }
}
