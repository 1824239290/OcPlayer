import Foundation
import Observation

/// 专门承载高频刷新的时间轴快照（progress 10Hz、displayPosition 1Hz），
/// 独立于 PlayerState 其它属性，保证进度更新不连带触发菜单、控制栏等静态 UI 重绘。
@MainActor
@Observable
public final class PlayerTimeline {
    /// 原始播放位置：内核每帧推一次，故意不参与 Observation。
    @ObservationIgnored public private(set) var position: Duration = .zero
    /// 时间标签用的位置：只在整秒变化时发布。
    public private(set) var displayPosition: Duration = .zero
    /// 进度条用的比例（0…1）：媒体时间每过 100ms 发布一次。
    public private(set) var progress: Double = 0
    public private(set) var duration: Duration = .zero

    private static let progressPublishInterval = Duration.milliseconds(100)
    @ObservationIgnored private var lastProgressPublishPosition: Duration = .zero

    public init() {}

    public func reset() {
        position = .zero
        displayPosition = .zero
        progress = 0
        lastProgressPublishPosition = .zero
        duration = .zero
    }

    func setPosition(_ value: Duration) {
        position = value
        publishDerivedPosition()
    }

    func setDuration(_ value: Duration) {
        // 同值跳过：durationChanged 被逐帧重发时，force 刷新会把 displayPosition/
        // progress 的发布也整帧拖着跑。
        guard duration != value else { return }
        duration = value
        publishDerivedPosition(force: true)
    }

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
        let elapsed = abs(position.microseconds - lastProgressPublishPosition.microseconds)
        guard force || elapsed >= Self.progressPublishInterval.microseconds else { return }
        lastProgressPublishPosition = position
        let fraction = min(max(Double(position.microseconds) / Double(total), 0), 1)
        if fraction != progress { progress = fraction }
    }
}

/// UI 只读的播放快照。事件流在 `start()` 里被独占消费，逐条折叠成属性。
@MainActor
@Observable
public final class PlayerState {
    public private(set) var state: PlaybackState = .idle
    public private(set) var isBuffering = false
    public private(set) var videoParams: VideoParams?
    public private(set) var trackCounts = TrackCounts(video: 0, audio: 0, subtitle: 0)
    public private(set) var hasSurface = false
    /// 轨道列表（音轨 / 字幕菜单用）。事件流里 tracks 数量变化或选轨生效时自动重拉。
    public private(set) var audioTracks: [TrackInfo] = []
    public private(set) var subtitleTracks: [TrackInfo] = []
    /// 最近一条内核错误，UI 可以显示后自行清掉。
    public private(set) var lastError: String?

    /// 连续重复的内核错误去重键。内核卡进坏状态（如 EOF stall）会逐帧重发同一条
    /// `.failed`，不去重的话主线程和诊断日志会被错误风暴刷爆（实测 6302 条）。
    private var lastFailedEventKey: String?

    /// 独立时间轴快照：高频 progress/position 封装在此，隔离其它观察者。
    public let timeline = PlayerTimeline()

    @ObservationIgnored public var position: Duration { timeline.position }
    public var displayPosition: Duration { timeline.displayPosition }
    public var progress: Double { timeline.progress }
    public var duration: Duration { timeline.duration }

    /// Every consumer receives a generation. A cancelled old task may already
    /// have an event buffered on the main actor, so cancellation alone is not
    /// enough to prevent it from mutating the state for a newer engine.
    @ObservationIgnored private var consumptionGeneration = 0

    public init() {}

    /// 开始消费某个引擎的事件流。调用方持有返回的 `Task` 决定生命周期。
    @discardableResult
    public func start(consuming engine: any PlaybackEngine) -> Task<Void, Never> {
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
                    // 轨道 / 选择变了：重拉列表（很快，适配器内部自己串行化）
                    self.refreshTracks(from: engine)
                default:
                    break
                }
            }
        }
    }

    /// 换源 / 手动选轨后由 `PlaybackController` 显式调用。
    public func refreshTracks(from engine: any PlaybackEngine) {
        guard let all = try? engine.tracks() else { return }
        audioTracks = all.filter { $0.kind == .audio }
        subtitleTracks = all.filter { $0.kind == .subtitle }
    }

    public func clearError() { lastError = nil }

    /// 换源时复位快照，避免旧内容的 position / duration / 轨道 / 错误残留到新源。
    /// surface 归 surface（视图一直挂着），这里只管媒体相关的状态。
    public func reset() {
        state = .idle
        timeline.reset()
        isBuffering = false
        videoParams = nil
        trackCounts = TrackCounts(video: 0, audio: 0, subtitle: 0)
        audioTracks = []
        subtitleTracks = []
        lastError = nil
        lastFailedEventKey = nil
    }

    func apply(_ event: PlayerEvent) {
        switch event {
        case .stateChanged(let value):
            // 内核卡进坏状态时会逐帧重发同一事件；@Observable 的写入即使同值
            // 也会触发观察者，同值直接丢（上次错误风暴被 .failed 去重救场，
            // 这里把其余事件类型一并防住）。
            if state != value { state = value }
        case .positionChanged(let value):
            timeline.setPosition(value)
        case .durationChanged(let value):
            timeline.setDuration(value)
        case .bufferingChanged(let value):
            if isBuffering != value { isBuffering = value }
        case .videoParamsChanged(let value):
            if videoParams != value { videoParams = value }
        case .tracksChanged(let value):
            if trackCounts != value { trackCounts = value }
        case .surfaceAttached:
            hasSurface = true
        case .surfaceDetached:
            hasSurface = false
        case .videoDecoderChanged, .audioOutputChanged, .trackSelectionChanged:
            break
        case .failed(let code, let message):
            // 同一条错误只记一次：内核卡死时 .failed 会逐帧重发，去重前一次
            // EOF stall 刷了 6302 条日志、主线程被事件轰炸到假死。
            let key = "\(code)|\(message ?? "")"
            if key != lastFailedEventKey {
                PlaybackLog.error("内核错误事件 code=\(code) message=\(message ?? "nil")")
                lastFailedEventKey = key
            }
            if state != .error { state = .error }
            lastError = message ?? "内核错误 code=\(code)"
        }
    }
}
