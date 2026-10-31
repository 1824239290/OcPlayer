import DiagnosticsKit
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

/// 一次播放会话的累计统计。`PlayerState` 每次 open 重建，所以天然按「源」清零。
/// `stallCount` 由宿主侧看门狗通过 `noteStall()` 上报（PlaybackKit 不知道宿主怎么检测）。
public struct PlaybackSessionStats: Sendable, Equatable {
    public var bufferCount = 0
    public var bufferedSeconds: TimeInterval = 0
    public var errorCount = 0
    public var stallCount = 0
    /// 处于 `.playing` 的累计时长（不含缓冲与暂停）。
    public var playedSeconds: TimeInterval = 0
}

/// UI 只读的播放快照。事件流在 `start()` 里被独占消费，逐条折叠成属性。
@MainActor
@Observable
public final class PlayerState {
    public private(set) var state: PlaybackState = .idle
    public private(set) var isBuffering = false
    /// UI 展示用的缓冲态：`isBuffering` **持续** `bufferingUIShowDelay` 才置位，
    /// 恢复时立刻跟随（显示满 `bufferingUIMinVisible` 之前不收回）。
    ///
    /// 单帧饿数据不该让整块 UI 动起来：转圈浮现、弹幕冻结、HUD 亮起（含全屏暗幕）
    /// 都跟着它走，抖一下就是用户眼里的「闪」（issue #2）。诊断事件行一律用原始
    /// `isBuffering`——别把迟滞掺进真值。
    public private(set) var isBufferingSustained = false
    public private(set) var videoParams: VideoParams?
    public private(set) var trackCounts = TrackCounts(video: 0, audio: 0, subtitle: 0)
    public private(set) var hasSurface = false
    /// 轨道列表（音轨 / 字幕菜单用）。事件流里 tracks 数量变化或选轨生效时自动重拉。
    public private(set) var audioTracks: [TrackInfo] = []
    public private(set) var subtitleTracks: [TrackInfo] = []
    /// 最近一条内核错误，UI 可以显示后自行清掉。
    public private(set) var lastError: String?

    /// 本次会话的累计统计（缓冲次数/时长、错误数、卡死数、播放时长）。
    public private(set) var sessionStats = PlaybackSessionStats()

    /// 会话是否已经开过（`start(consuming:)` 置位）：没开过源时不写 session.end 噪音。
    @ObservationIgnored private var sessionStarted = false
    @ObservationIgnored private var bufferingStartedAt: Date?
    @ObservationIgnored private var playStartedAt: Date?
    @ObservationIgnored private var hasEmittedFirstFrame = false

    /// UI 缓冲态的上沿迟滞：内核报缓冲要连续持续这么久，UI 才跟着动。
    @ObservationIgnored private let bufferingUIShowDelay: Duration
    /// UI 缓冲态的最短可见时长：上沿挡住「一闪而过」，这条挡住「刚显示就恢复」
    /// 留下的那一帧闪动（两者一起才对得上一句「在极端的时间内画面闪动」）。
    @ObservationIgnored private let bufferingUIMinVisible: Duration
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var bufferingUIShowTask: Task<Void, Never>?
    @ObservationIgnored private var bufferingUIHideTask: Task<Void, Never>?
    @ObservationIgnored private var sustainedBufferingShownAt: ContinuousClock.Instant?

    /// 连续重复的内核错误去重键。内核卡进坏状态（如 EOF stall）会逐帧重发同一条
    /// `.failed`，不去重的话主线程和诊断日志会被错误风暴刷爆（实测 6302 条）。
    private var lastFailedEventKey: String?

    /// 已经折叠过一次「片尾陈旧读错误」（见 `isStaleIOErrorInTail`）。
    ///
    /// 内核在同一件事上会先后推两条事件（`.failed` 之后紧跟 `.stateChanged(.error)`），
    /// 折叠掉第一条之后，第二条不许把状态再翻回错误态；否则徽章照样弹、
    /// `isNaturalEnd` 照样不成立，连播还是断在这里。
    private var foldedStaleTailIOFailure = false

    /// 片尾窗口：位置落在「片长 − 2 s」以内就算片尾。与上报层
    /// `naturalEndPositionSlackSeconds` 同一口径。
    nonisolated static let tailFailureWindow: Duration = .seconds(2)

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

    /// 迟滞参数可注入：默认值是面向真机观感的，测试用小值跑真实计时路径。
    public init(
        bufferingUIShowDelay: Duration = .milliseconds(300),
        bufferingUIMinVisible: Duration = .milliseconds(500)
    ) {
        self.bufferingUIShowDelay = bufferingUIShowDelay
        self.bufferingUIMinVisible = bufferingUIMinVisible
    }

    /// 开始消费某个引擎的事件流。调用方持有返回的 `Task` 决定生命周期。
    @discardableResult
    public func start(consuming engine: any PlaybackEngine) -> Task<Void, Never> {
        consumptionGeneration &+= 1
        let generation = consumptionGeneration
        sessionStarted = true
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

    /// 轨道列表刷新后的回调，每次 `refreshTracks` 拿到新列表都会触发（主 actor 上同步）。
    ///
    /// 自动选字幕挂在这里：轨道什么时候齐全是事件流说了算（open 后内封轨道就绪、
    /// 外挂字幕一条条挂上），控制器自己拿不到「这一次刷新之后列表已经最新」这个点。
    /// 实现方必须**幂等**——选轨本身会再推一次 `trackSelectionChanged` → 再刷新。
    @ObservationIgnored public var onTracksRefreshed: (() -> Void)?

    /// 换源 / 手动选轨后由 `PlaybackController` 显式调用。
    public func refreshTracks(from engine: any PlaybackEngine) {
        guard let all = try? engine.tracks() else { return }
        audioTracks = all.filter { $0.kind == .audio }
        subtitleTracks = all.filter { $0.kind == .subtitle }
        onTracksRefreshed?()
    }

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
        foldedStaleTailIOFailure = false
        sessionStats = PlaybackSessionStats()
        sessionStarted = false
        bufferingStartedAt = nil
        playStartedAt = nil
        hasEmittedFirstFrame = false
        cancelSustainedBuffering()
    }

    func apply(_ event: PlayerEvent) {
        switch event {
        case .stateChanged(let value):
            // 片尾那条陈旧读错误的内核侧孪生事件：`.failed` 已按自然收尾折叠
            // （见 `.failed` 分支），这里不许把状态再翻回 `.error`。
            if value == .error, foldedStaleTailIOFailure,
               Self.isInTailWindow(position: timeline.position, duration: timeline.duration) {
                return
            }
            // 内核卡进坏状态时会逐帧重发同一事件；@Observable 的写入即使同值
            // 也会触发观察者，同值直接丢（上次错误风暴被 .failed 去重救场，
            // 这里把其余事件类型一并防住）。
            if state != value {
                state = value
                recordStateTransition(value)
            }
        case .positionChanged(let value):
            timeline.setPosition(value)
        case .durationChanged(let value):
            timeline.setDuration(value)
        case .bufferingChanged(let value):
            if isBuffering != value {
                isBuffering = value
                recordBufferingChange(value)
                updateSustainedBuffering(value)
            }
        case .videoParamsChanged(let value):
            if videoParams != value { videoParams = value }
        case .tracksChanged(let value):
            if trackCounts != value { trackCounts = value }
        case .surfaceAttached:
            hasSurface = true
        case .surfaceDetached:
            hasSurface = false
        case .videoDecoderChanged:
            // 硬解 ⇄ 软解的回退在现场只表现为「突然变卡」，画面照常，用户不会报
            // 「内核换了解码器」。内核一直在报这个事件，此前到这里就是一个 break，
            // 于是排障时永远拿不到第一现场。位置带上，能和进度对上。
            PlaybackLog.event(
                .decoderChanged,
                fields: PlaybackEvent.decoderChangedFields(position: timeline.position)
            )
        case .audioOutputChanged:
            // 刻意不处理：Apple 后端（AudioQueue）不实现音频自恢复状态机，这条事件
            // 在 macOS / iOS 上**永不触发**（见 CHANGELOG 0.2.1 的记账）。留着 break
            // 是有意的——不是遗漏，别当成缺陷来「修」。
            break
        case .trackSelectionChanged:
            // 选轨本身会推一次，由 `refreshTracks` 那条路消费（见 onTracksRefreshed）。
            break
        case .failed(let code, let message):
            // 同一条错误只记一次：内核卡死时 .failed 会逐帧重发，去重前一次
            // EOF stall 刷了 6302 条日志、主线程被事件轰炸到假死。
            let key = "\(code)|\(message ?? "")"
            // 片尾的陈旧读错误不是这一次的错（机理见 `isStaleIOErrorInTail`）。
            if Self.isStaleIOErrorInTail(
                message: message,
                position: timeline.position,
                duration: timeline.duration
            ) {
                // **会话已经真失败**：先到的那条真错误（EOF stall 风暴、HTTP 4xx）
                // 才是这一集的死因。两条都不许动——把状态翻回 `.stopped` 会让上报层
                // 当成自然播完、在一集明明失败的情况下连播下一集；盖掉 `lastError`
                // 则会把用户看到的徽章换成这条带 `failed earlier` 的误导文案。
                guard state != .error else { return }

                // 会话还活着：按自然收尾折叠成 `.stopped`。上报层只认 `.stopped` +
                // 贴片长的 `isNaturalEnd`，于是本集照常结束、连播不断、不露错误徽章，
                // `errorCount` 也不计这条假报——它不该进 `session.end` 汇总。
                if key != lastFailedEventKey {
                    lastFailedEventKey = key
                    foldedStaleTailIOFailure = true
                    PlaybackLog.warning(
                        "片尾陈旧读错误按自然收尾处理（内核 AVIO 错误闸门，待 liberika 修）",
                        fields: [
                            "code": .integer(Int64(code)),
                            "message": .string(message ?? "nil"),
                            "position_ms": .integer(timeline.position.microseconds / 1000),
                            "duration_ms": .integer(timeline.duration.microseconds / 1000),
                        ]
                    )
                }
                if state != .stopped {
                    state = .stopped
                    recordStateTransition(.stopped)
                }
                return
            }
            if key != lastFailedEventKey {
                lastFailedEventKey = key
                sessionStats.errorCount += 1
                PlaybackLog.error("内核错误事件 code=\(code) message=\(message ?? "nil")")
                // 结构化事件行：与人类可读的错误行互补，脚本按 event/code 直接消费。
                PlaybackLog.event(.error, fields: [
                    "code": .integer(Int64(code)),
                    "message": .string(message ?? "nil"),
                    "position_ms": .integer(timeline.position.microseconds / 1000),
                ], level: .error)
            }
            if state != .error { state = .error }
            let newError = message ?? "内核错误 code=\(code)"
            if lastError != newError { lastError = newError }
        }
    }

    /// 识别「片尾的陈旧读错误」：内核在一次 seek 打断读之后，那条 EIO 会被 FFmpeg
    /// 永久锁进 `AVIOContext.error`（`avio_seek` 只清 `eof_reached`，从不清 `error`），
    /// 于是此后**第一次读到 0 字节**（自然播完 / 跳到片尾）拿到的是这条陈旧 EIO
    /// 而不是 EOF → `av_read_frame` = -5 → demux worker 判 fatal。
    ///
    /// 判据刻意收得很窄，只认两件事同时成立：
    /// ① 片长已知且位置已贴到片尾（`tailFailureWindow` 以内）；
    /// ② 文案是 `av_read_frame` 的 EIO——内核格式为
    ///    `ffmpeg error in av_read_frame: {av_strerror(-5)} (-5)`。
    ///
    /// 认 `(-5)` 而不是认 `Input/output error`：`av_strerror` 走 `strerror`，
    /// 一旦宿主进程设了 locale 就是本地化文本，认英文会把这条兜底在非英文环境里
    /// 变成死代码。`av_read_frame` + `(-5)` 已经是这个事件的全部身份。
    ///
    /// 别的错误（HTTP 4xx、解码器故障、EOF stall 风暴）即便落在片尾也照样报错。
    ///
    /// **代价是已知且被接受的**：片尾最后 2 s 内真的发生 I/O 故障（例如断网）也会
    /// 落进这个签名、被当成自然收尾——那一集剩下的内容本就不足 2 s，误判的后果
    /// 小于「每集播完都因内核缺陷报错」。
    nonisolated static func isStaleIOErrorInTail(
        message: String?,
        position: Duration,
        duration: Duration
    ) -> Bool {
        guard let message,
              isInTailWindow(position: position, duration: duration),
              message.contains("av_read_frame"),
              message.contains("(-5)")
        else { return false }
        return true
    }

    /// 位置是否已经贴到片尾（`tailFailureWindow` 以内）。片长未知（0）时不算片尾。
    nonisolated static func isInTailWindow(position: Duration, duration: Duration) -> Bool {
        duration > .zero && position >= duration - tailFailureWindow
    }

    /// 状态迁移的副作用：首帧近似点 + 播放时长累计。
    private func recordStateTransition(_ newState: PlaybackState) {
        if newState == .playing {
            if !hasEmittedFirstFrame {
                hasEmittedFirstFrame = true
                // 内核没有独立的「首帧已渲染」事件，状态进 playing 是宿主能给的最接近的点；
                // 与 `open.start`/`open.done` 的时间戳（毫秒精度）相减即得「open 到出画面」。
                PlaybackLog.event(.firstFrame, fields: [
                    "position_ms": .integer(timeline.position.microseconds / 1000),
                ])
            }
            if playStartedAt == nil { playStartedAt = Date() }
        } else if let started = playStartedAt {
            sessionStats.playedSeconds += Date().timeIntervalSince(started)
            playStartedAt = nil
        }
    }

    /// 缓冲起止事件：issue #2（「三十秒闪一次」）在日志里查不到东西，正是因为
    /// 此前缓冲周期完全不落日志，只有 UI 状态在悄悄翻。
    private func recordBufferingChange(_ buffering: Bool) {
        let positionMs = timeline.position.microseconds / 1000
        if buffering {
            bufferingStartedAt = Date()
            sessionStats.bufferCount += 1
            PlaybackLog.event(.bufferStart, fields: ["position_ms": .integer(positionMs)])
        } else {
            let buffered = bufferingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            bufferingStartedAt = nil
            sessionStats.bufferedSeconds += buffered
            PlaybackLog.event(.bufferEnd, fields: [
                "position_ms": .integer(positionMs),
                "duration_ms": .integer(Int64(buffered * 1000)),
            ])
        }
    }

    /// 宿主侧卡死看门狗上报一次（检测逻辑在 App 层：内核不报缓冲 ≠ 没卡）。
    public func noteStall() {
        sessionStats.stallCount += 1
    }

    /// UI 缓冲态的两侧迟滞（真值 `isBuffering` 不动）：
    /// - 进：连续持续 `bufferingUIShowDelay` 才置位——单帧饿数据完全不惊动 UI；
    /// - 出：立刻跟随，但补足 `bufferingUIMinVisible` 的最短可见时长——刚显示就恢复
    ///   不留一帧闪动；期间再次进缓冲则直接取消收回，不来回闪。
    private func updateSustainedBuffering(_ buffering: Bool) {
        if buffering {
            bufferingUIHideTask?.cancel()
            bufferingUIHideTask = nil
            guard !isBufferingSustained, bufferingUIShowTask == nil else { return }
            bufferingUIShowTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.bufferingUIShowDelay)
                guard !Task.isCancelled, self.isBuffering else { return }
                self.bufferingUIShowTask = nil
                self.sustainedBufferingShownAt = self.clock.now
                self.isBufferingSustained = true
            }
            return
        }

        bufferingUIShowTask?.cancel()
        bufferingUIShowTask = nil
        guard isBufferingSustained else { return }
        let shownFor = sustainedBufferingShownAt.map { clock.now - $0 } ?? .zero
        let remaining = bufferingUIMinVisible - shownFor
        guard remaining > .zero else {
            hideSustainedBuffering()
            return
        }
        bufferingUIHideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled, !self.isBuffering else { return }
            self.hideSustainedBuffering()
        }
    }

    private func hideSustainedBuffering() {
        bufferingUIHideTask = nil
        sustainedBufferingShownAt = nil
        isBufferingSustained = false
    }

    private func cancelSustainedBuffering() {
        bufferingUIShowTask?.cancel()
        bufferingUIShowTask = nil
        bufferingUIHideTask?.cancel()
        bufferingUIHideTask = nil
        sustainedBufferingShownAt = nil
        isBufferingSustained = false
    }

    /// 结束本会话并产出汇总（`reason` 由宿主给：user / superseded / failed）。
    /// 只放行一次；没开过源直接返回 nil，不制造噪音记录。
    @discardableResult
    public func finishSession(reason: String) -> PlaybackSessionStats? {
        guard sessionStarted else { return nil }
        sessionStarted = false
        var stats = sessionStats
        if let started = playStartedAt {
            stats.playedSeconds += Date().timeIntervalSince(started)
            playStartedAt = nil
        }
        // 逐项赋值而不是一个大字典字面量：6 个混合类型的条目会让类型检查器超时
        //（"unable to type-check this expression in reasonable time"）。
        var fields: [String: DiagnosticValue] = ["reason": .string(reason)]
        fields["played_ms"] = .integer(Int64(stats.playedSeconds * 1000))
        fields["buffer_count"] = .integer(Int64(stats.bufferCount))
        fields["buffered_ms"] = .integer(Int64(stats.bufferedSeconds * 1000))
        fields["error_count"] = .integer(Int64(stats.errorCount))
        fields["stall_count"] = .integer(Int64(stats.stallCount))
        PlaybackLog.event(.sessionEnd, fields: fields)
        return stats
    }
}
