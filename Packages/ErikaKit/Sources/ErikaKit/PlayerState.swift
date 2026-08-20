import CErika
import Foundation
import Observation

/// UI 只读的播放快照。事件流在 `start()` 里被独占消费，逐条折叠成属性。
@MainActor
@Observable
public final class PlayerState {
    public private(set) var state: PlaybackState = .idle
    /// 原始播放位置：内核**每帧**推一次，所以故意不参与 Observation。
    /// 上报、续播、skip 这类命令式读取用它；**视图 body 里不要读**——它不发通知
    /// （读了不会刷新），高频写入也不该把子树拖成逐帧重算。UI 读
    /// `displayPosition` / `progress`。
    @ObservationIgnored public private(set) var position: Duration = .zero
    /// 时间标签用的位置：只在**整秒**变化时发布（标签精度就是秒）。
    public private(set) var displayPosition: Duration = .zero
    /// 进度条用的比例（0…1）：媒体时间每过 `progressPublishInterval` 发布一次。
    public private(set) var progress: Double = 0
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

    /// Every consumer receives a generation. A cancelled old task may already
    /// have an event buffered on the main actor, so cancellation alone is not
    /// enough to prevent it from mutating the state for a newer engine.
    @ObservationIgnored private var consumptionGeneration = 0

    /// 进度条的发布节流：媒体时间每 100 ms 一档（1× 速率下约 10 Hz）。
    /// 滑块本身的视觉精度远低于此，再密只是白烧 MainActor 和布局。
    private static let progressPublishInterval = Duration.milliseconds(100)
    @ObservationIgnored private var lastProgressPublishPosition: Duration = .zero

    public init() {}

    /// 开始消费某个引擎的事件流。调用方持有返回的 `Task` 决定生命周期。
    @discardableResult
    public func start(consuming engine: ErikaEngine) -> Task<Void, Never> {
        consumptionGeneration &+= 1
        let generation = consumptionGeneration
        return Task { [weak self] in
            for await event in engine.events {
                guard !Task.isCancelled, let self,
                      self.consumptionGeneration == generation
                else { return }
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
        displayPosition = .zero
        progress = 0
        lastProgressPublishPosition = .zero
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
            publishDerivedPosition()
        case .durationChanged(let value):
            duration = value
            // duration 是 progress 的分母，晚到 / 换源时必须立刻重算一次。
            publishDerivedPosition(force: true)
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
            PlaybackLog.error("内核错误事件 status=\(status.rawValue) message=\(message ?? "nil")")
            state = .error
            lastError = message ?? "内核错误 status=\(status.rawValue)"
        }
    }

    /// 把逐帧的 `position` 折叠成 UI 真正需要的两个观察值：
    /// 标签只在整秒变化时发布，进度条按媒体时间限流。
    /// `force` 用于 duration 到达 / 复位这类必须立刻对齐的时刻。
    private func publishDerivedPosition(force: Bool = false) {
        if force || position.components.seconds != displayPosition.components.seconds {
            displayPosition = position
        }
        let total = duration.microseconds
        guard total > 0 else {
            if progress != 0 { progress = 0 }
            lastProgressPublishPosition = position
            return
        }
        // seek 会让位置倒退，所以比的是绝对差值。
        let elapsed = abs(position.microseconds - lastProgressPublishPosition.microseconds)
        guard force || elapsed >= Self.progressPublishInterval.microseconds else { return }
        lastProgressPublishPosition = position
        let fraction = min(max(Double(position.microseconds) / Double(total), 0), 1)
        if fraction != progress { progress = fraction }
    }
}
