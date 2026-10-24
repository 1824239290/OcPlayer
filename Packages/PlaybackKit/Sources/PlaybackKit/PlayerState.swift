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

    /// 片尾 EOF 临时兜底是否已经落过**带 code/message** 的诊断（每会话一次：错误风暴下
    /// 日志不能跟着刷）。
    private var reportedEndOfStreamFold = false
    /// 是否落过只有状态迁移（`.stateChanged(.error)`、没有错误事件）的兜底诊断。
    /// 与上一条分开记：状态迁移先到时先留一条，随后 `.failed` 带着内核原文到达时
    /// 还要再留一条细节行，不能因为「已经记过」就把 code/message 丢掉。
    private var reportedEndOfStreamStateFold = false

    /// 认为「已经站在文件尾」的位置容差（秒）。
    ///
    /// ⚠️ **临时兜底，根因在内核侧、尚未修**：Erika v0.2.1 在请求边界跨过文件末尾时，
    /// 会间歇把「读到文件尾」报成致命错误（实测 `av_read_frame: Input/output error (-5)`，
    /// 也见过 `audio output stalled at EOF`），事件流给到 `.failed` / `.stateChanged(.error)`。
    /// 于是**自然播完**反而进 `.error`：UI 弹「播放出错」徽章、诊断记一条 error，上报链路
    /// 只能靠 `PlaybackReportingCoordinator.isEndOfStream` 再兜成「播完」。
    ///
    /// 这里在折叠层直接兜住：片长末尾窗口内的内核错误按自然结束（`.stopped`）收口，
    /// 不置 `lastError`、不计 `errorCount`，只落一条 warning 诊断留痕。判据只看**位置**
    /// 不看错误文案——文案跨内核版本会变，位置是稳定信号（三次实机现场全部落在片尾前
    /// 0.4–0.5 s）。
    ///
    /// 与 `PlaybackReportingCoordinator.isReachedEnd` 共用同一口径（那边直接引用本常量）。
    /// 两处阈值**不能分叉**：折叠出的 `.stopped` 必须能被上报层认成「播完」，否则会变成
    /// 「没有错误徽章、也不连播/退出」的静默卡死。
    ///
    /// **删除条件**：等上游 Erika 把跨 EOF 的读改成干净 EOF / 短读、升
    /// `Config/Erika.version` 之后，连同 `isAtEndOfStream` 与两处调用点一起删。
    public nonisolated static let endOfStreamToleranceSeconds: Double = 2.0

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

    /// 状态**收口到** `.stopped` 时回调一次（主 actor，同步；含片尾 EOF 折叠路径）。
    /// iOS 的画中画用它关掉系统窗口——PiP 窗口不会自己跟着内核 stopped 收。
    @ObservationIgnored public var onPlaybackStopped: (() -> Void)?

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
        reportedEndOfStreamFold = false
        reportedEndOfStreamStateFold = false
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
            // 内核卡进坏状态时会逐帧重发同一事件；@Observable 的写入即使同值
            // 也会触发观察者，同值直接丢（上次错误风暴被 .failed 去重救场，
            // 这里把其余事件类型一并防住）。
            //
            // 片尾的 `.stateChanged(.error)` 与 `.failed` 是同一个内核缺陷的两张面孔
            //（有的现场只给状态迁移、没有错误事件），所以这里也要过同一道折叠。
            let folded = foldEndOfStreamError(value)
            if state != folded {
                state = folded
                recordStateTransition(folded)
                if folded == .stopped { onPlaybackStopped?() }
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
            // 片尾临时兜底（判据与理由见 endOfStreamToleranceSeconds）：自然播到文件尾时
            // 内核把「跨 EOF 的读」报成致命错误，这不是播放失败。按自然结束收口，**不置
            // `lastError` / 不计 `errorCount`**——错误徽章与「重试」都不该出现。
            // 去重键照记：内核坏态下这条会逐帧重发，warning 也不能跟着刷屏。
            if isAtEndOfStream {
                lastFailedEventKey = key
                foldEndOfStreamError(code: code, message: message)
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

    // MARK: - 片尾 EOF 临时兜底（根因在内核侧，见 endOfStreamToleranceSeconds）

    /// 当前位置是否已经站在文件尾窗口内。片长未知（0，直播 / 尚未拿到 duration）时不成立
    /// ——拿不到分母就不猜，宁可照旧报错。
    ///
    /// 还要求 `position > 0`：没有位置就没有「已经播到末尾」这回事。否则片长 ≤ 容差的
    /// 短片（duration ≤ 2 s）在 position=0 时会满足 `0 + tolerance >= total`，把**开头**
    /// 的致命错误（解码起不来 / 源打不开）也折叠成「播完了」，那是在掩盖真故障。
    private var isAtEndOfStream: Bool {
        let total = timeline.duration.microseconds
        guard total > 0, timeline.position > .zero else { return false }
        let tolerance = Int64(Self.endOfStreamToleranceSeconds * 1_000_000)
        return timeline.position.microseconds + tolerance >= total
    }

    /// 把「片尾窗口内的内核错误」折叠成自然结束：状态收口到 `.stopped`，诊断每会话只落
    /// 一条（保留 `code` / `message` / 位置，便于确认是不是同一个 EOF 缺陷）。
    ///
    /// 只动状态与错误展示，**不伪造成功**：`session.end` 里 `error_count` 保持 0 是刻意的
    ///（这次收尾在用户视角就是「看完了」），内核错误的原始证据留在下面这条 warning 里。
    private func foldEndOfStreamError(_ candidateState: PlaybackState) -> PlaybackState {
        guard candidateState == .error, isAtEndOfStream else { return candidateState }
        // 只有状态迁移、没有错误事件：留一条不带 code/message 的诊断；随后若有 `.failed`
        // 带着内核原文到达，还会再补一条细节行（两个标记分开记，见属性注释）。
        if !reportedEndOfStreamStateFold {
            reportedEndOfStreamStateFold = true
            logEndOfStreamFold(code: nil, message: nil)
        }
        applyEndOfStreamStop()
        return .stopped
    }

    private func foldEndOfStreamError(code: Int32, message: String?) {
        // 内核原文是归因的唯一凭据，不能因为状态迁移那条先到就丢掉：这里独立记一次。
        if !reportedEndOfStreamFold {
            reportedEndOfStreamFold = true
            logEndOfStreamFold(code: code, message: message)
        }
        applyEndOfStreamStop()
    }

    private func logEndOfStreamFold(code: Int32?, message: String?) {
        PlaybackLog.warning(
            "片尾内核报错按自然结束处理（临时兜底）",
            fields: [
                "code": .integer(Int64(code ?? -1)),
                "message": .string(message ?? "nil"),
                "position_ms": .integer(timeline.position.microseconds / 1000),
                "duration_ms": .integer(timeline.duration.microseconds / 1000),
                "tolerance_s": .double(Self.endOfStreamToleranceSeconds),
            ]
        )
    }

    private func applyEndOfStreamStop() {
        if state != .stopped {
            state = .stopped
            recordStateTransition(.stopped)
            onPlaybackStopped?()
        }
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
