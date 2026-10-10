import Foundation
import JellyfinKit

// 上报协议 `PlaybackReporting` 由 JellyfinKit 提供（只有那 3 条方法）：
// 协调器只依赖它需要的契约，测试替身不必实现整个 `MediaServer`。
// 生产侧 `JellyfinServer` / `EmbyServer` 都经 `MediaServer` 满足它。

struct PlaybackReportSnapshot: Equatable {
    enum State: Equatable {
        case active
        case paused
        case stopped
        case error
    }

    let state: State
    let positionSeconds: Double
    let durationSeconds: Double
    let sourceOpenFailed: Bool
}

@MainActor
protocol PlaybackReportingStateSource: AnyObject {
    func playbackReportSnapshot(for requestID: PlaybackRequest.ID) -> PlaybackReportSnapshot?
}

extension PlaybackController: PlaybackReportingStateSource {}

/// Serializes Jellyfin playback lifecycle reports for one player.
///
/// The queue deliberately outlives an active session: a new Start waits for the
/// previous Stopped, and a Stopped waits for the latest Progress. This prevents
/// a slow request from moving Jellyfin's resume position backwards.
@MainActor
final class PlaybackReportingCoordinator {
    struct TerminalEvent: Equatable, Sendable {
        let requestID: PlaybackRequest.ID
        let reachedEnd: Bool
    }

    enum BackgroundReport {
        case progress(Task<Void, Never>)
        case terminal(Task<Void, Never>)

        var task: Task<Void, Never> {
            switch self {
            case .progress(let task), .terminal(let task): task
            }
        }
    }

    private struct Session: Sendable {
        let generation: UInt64
        let reporter: any PlaybackReporting
        let context: PlaybackSessionContext
        let requestID: PlaybackRequest.ID
        let startTask: Task<Void, Never>
        let onTerminal: @MainActor @Sendable (TerminalEvent) -> Void
    }

    private weak var stateSource: (any PlaybackReportingStateSource)?
    private let heartbeatInterval: Duration
    private let progressEveryTicks: Int

    private var generation: UInt64 = 0
    private var session: Session?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingLifecycleReport: Task<Void, Never>?
    private var pendingStoppedReport: Task<Void, Never>?
    private var pendingStoppedRequestID: PlaybackRequest.ID?
    private var lastCompletedStoppedRequestID: PlaybackRequest.ID?
    private var stoppedReportGeneration: UInt64 = 0
    private var triggeredTerminalRequestIDs: Set<PlaybackRequest.ID> = []

    init(
        stateSource: any PlaybackReportingStateSource,
        heartbeatInterval: Duration = .seconds(1),
        progressEveryTicks: Int = 10,
        precedingStoppedReport: Task<Void, Never>? = nil
    ) {
        self.stateSource = stateSource
        self.heartbeatInterval = heartbeatInterval
        self.progressEveryTicks = max(progressEveryTicks, 1)
        pendingStoppedReport = precedingStoppedReport
    }

    private static func isReachedEnd(snapshot: PlaybackReportSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.durationSeconds > 0
            && snapshot.positionSeconds >= snapshot.durationSeconds - 2
    }

    /// 终态里「已经播到文件尾」的判定（心跳分支用）。
    ///
    /// `.stopped` 是引擎干净收尾；`.error` 也要认，因为内核在片尾会**间歇性**把
    /// 「读到文件末尾」报成致命错误，而不是干净 EOF：
    ///
    /// 实测（2026-10-09，iPad mini 5 / iPadOS 26.6.2 / OcPlayer 0.2.1 / Erika v0.2.1，
    /// `我的朋友很少 S1E5`，1472 s 片源）——最后一次成功读取停在距文件尾 **3966 字节**
    /// 处，下一次跨过 EOF 的读直接给出 `av_read_frame: Input/output error (-5)`，内核落
    /// `playback_fatal`、App 状态进 `.error`。对照同一天另一次收尾：最后一次 range 恰好
    /// 读到 EOF（919287807 + 81988 = 文件长度 919369795）→ `decoder_eof_drain complete`
    /// → `.stopped` → 连播/退出照常。差别只在请求边界是否跨过 EOF。
    ///
    /// 此前只认 `.stopped`，于是这种片尾错误被算成 `reachedEnd=false`：既不连播也不退出，
    /// 只剩错误徽章（那次日志里报错后 18 秒内唯一的动作是用户手动关闭）。
    /// 位置判据与 `.stopped` 共用 `isReachedEnd`（片长 − 2 s 以内），片中的真错误不受影响。
    private static func isEndOfStream(snapshot: PlaybackReportSnapshot?) -> Bool {
        guard let snapshot, isReachedEnd(snapshot: snapshot) else { return false }
        return snapshot.state == .stopped || snapshot.state == .error
    }

    /// `stop()` 收口时是否该按「自然播完」触发终态事件。
    /// 与心跳分支共用「位置在末尾」的判据，但**只认 `.stopped`**：这条路径由宿主主动
    /// 进入（关播放器 / 换控制器 / 退后台），此刻把片尾的 `.error` 也当成播完，会在用户
    /// 正拆台的时候反过来触发连播——`AppModel.playback` 的 didSet 里 `stop()` 甚至跑在
    /// `clearPlaybackSessionState()`（它会清 `activePlaybackIdentity`）之前。
    /// 片尾错误的兜底只放在心跳分支：那里还守着 `isCurrent`，用户先关了就不会误触发。
    private static func isNaturalEnd(snapshot: PlaybackReportSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.state == .stopped && isReachedEnd(snapshot: snapshot)
    }

    private func triggerTerminalIfNeeded(session: Session, reachedEnd: Bool) {
        guard !triggeredTerminalRequestIDs.contains(session.requestID) else { return }
        triggeredTerminalRequestIDs.insert(session.requestID)
        session.onTerminal(TerminalEvent(
            requestID: session.requestID,
            reachedEnd: reachedEnd
        ))
    }

    /// 上报超时时长（可注入：测试用短的）。
    nonisolated(unsafe) static var reportTimeout: Duration = .seconds(5)

    /// 带**真超时**地执行一次上报。
    ///
    /// 原实现是「到点 `task.cancel()`，然后仍然 `await task.value`」—— 那等的是任务
    /// **完成**而不是取消，所以只要 `PlaybackReporting` 的实现不响应取消，这个"超时"
    /// 就形同虚设。后果不只是慢一下：上报是一条串行链（`await precedingStop?.value`
    /// → `await startTask.value` → …），一个卡住的上报会把后面所有上报堵死，
    /// 表现为「上报静默失效」，而日志上看只是"网络慢"。
    ///
    /// 这里改成真正的竞速：谁先到点谁放行，**不等**落败方收尾。
    ///
    /// 取舍：`PlaybackReporting` 只承诺三个 `async` 方法、没有取消语义契约，所以被
    /// 放弃的那次上报只能"请求取消"、无法真正终止——它可能继续跑完。但上报链不再被
    /// 它阻塞，这是关键（宁可漏一次上报，也不要整条链停摆）。两个生产实现都走
    /// URLSession、天然响应取消。
    private static func performWithTimeout(
        duration: Duration? = nil,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let timeout = duration ?? reportTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            let work = Task { @MainActor in
                await operation()
                gate.resume()
            }
            Task {
                try? await Task.sleep(for: timeout)
                // 先请求取消（合作方会立刻退出），再无条件放行——不等它。
                work.cancel()
                gate.resume()
            }
        }
    }

    /// 保证 continuation 只被恢复一次（操作先完成、或超时先到点）。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    func start(
        reporter: any PlaybackReporting,
        context: PlaybackSessionContext,
        requestID: PlaybackRequest.ID,
        resumeSeconds: Double?,
        onTerminal: @escaping @MainActor @Sendable (TerminalEvent) -> Void
    ) {
        // Keep the coordinator correct even when a caller starts a new request
        // without first calling stop (AppModel normally does that explicitly).
        let precedingStop = stop() ?? pendingStoppedReport
        generation &+= 1
        let sessionGeneration = generation
        let startTask = Task {
            await precedingStop?.value
            await Self.performWithTimeout {
                await reporter.reportPlaybackStart(
                    context: context,
                    positionSeconds: resumeSeconds ?? 0
                )
            }
        }
        let activeSession = Session(
            generation: sessionGeneration,
            reporter: reporter,
            context: context,
            requestID: requestID,
            startTask: startTask,
            onTerminal: onTerminal
        )
        session = activeSession

        heartbeatTask = Task { [weak self] in
            await startTask.value
            guard !Task.isCancelled else { return }
            var ticks = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self?.heartbeatInterval ?? .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                      self.isCurrent(activeSession) else { return }
                guard let snapshot = self.stateSource?.playbackReportSnapshot(for: requestID) else {
                    continue
                }
                ticks += 1

                if snapshot.state == .stopped || snapshot.state == .error
                    || snapshot.sourceOpenFailed {
                    let precedingLifecycle = self.pendingLifecycleReport
                    self.pendingLifecycleReport = nil
                    let stopTask = self.enqueueStoppedReport(
                        session: activeSession,
                        positionSeconds: snapshot.positionSeconds,
                        precedingLifecycle: precedingLifecycle
                    )
                    await stopTask.value
                    guard self.isCurrent(activeSession) else { return }
                    self.session = nil
                    self.heartbeatTask = nil
                    let reachedEnd = Self.isEndOfStream(snapshot: snapshot)
                    self.triggerTerminalIfNeeded(session: activeSession, reachedEnd: reachedEnd)
                    return
                }

                if ticks % self.progressEveryTicks == 0 {
                    _ = self.enqueueProgressReport(
                        session: activeSession,
                        snapshot: snapshot
                    )
                }
            }
        }
    }

    /// Immediately snapshots progress for backgrounding. Terminal states are
    /// finalized instead, matching the normal heartbeat path.
    @discardableResult
    func reportBackgroundSnapshot() -> BackgroundReport? {
        guard let session,
              let snapshot = stateSource?.playbackReportSnapshot(for: session.requestID)
        else { return nil }
        if snapshot.state == .stopped || snapshot.state == .error
            || snapshot.sourceOpenFailed {
            guard let task = stop() else { return nil }
            return .terminal(task)
        }
        return .progress(enqueueProgressReport(session: session, snapshot: snapshot))
    }

    /// Finalizes the active session using the current position. Safe to call
    /// repeatedly; natural EOF and explicit dismissal share the same stop queue.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard let activeSession = session else { return pendingStoppedReport }
        let snapshot = stateSource?.playbackReportSnapshot(for: activeSession.requestID)
        let precedingLifecycle = pendingLifecycleReport
        pendingLifecycleReport = nil
        session = nil

        let reachedEnd = Self.isNaturalEnd(snapshot: snapshot)
        if reachedEnd {
            triggerTerminalIfNeeded(session: activeSession, reachedEnd: true)
        }

        return enqueueStoppedReport(
            session: activeSession,
            positionSeconds: snapshot?.positionSeconds ?? 0,
            precedingLifecycle: precedingLifecycle
        )
    }

    private func isCurrent(_ candidate: Session) -> Bool {
        session?.generation == candidate.generation
            && session?.requestID == candidate.requestID
    }

    private func enqueueProgressReport(
        session: Session,
        snapshot: PlaybackReportSnapshot
    ) -> Task<Void, Never> {
        let precedingLifecycle = pendingLifecycleReport
        let task = Task { [weak self] in
            await session.startTask.value
            await precedingLifecycle?.value
            guard let self, !Task.isCancelled, self.isCurrent(session) else { return }
            await Self.performWithTimeout {
                await session.reporter.reportPlaybackProgress(
                    context: session.context,
                    positionSeconds: snapshot.positionSeconds,
                    isPaused: snapshot.state == .paused
                )
            }
        }
        pendingLifecycleReport = task
        return task
    }

    private func enqueueStoppedReport(
        session: Session,
        positionSeconds: Double,
        precedingLifecycle: Task<Void, Never>?
    ) -> Task<Void, Never> {
        if lastCompletedStoppedRequestID == session.requestID {
            return Task {}
        }
        if pendingStoppedRequestID == session.requestID,
           let pendingStoppedReport {
            return pendingStoppedReport
        }

        let precedingStop = pendingStoppedReport
        stoppedReportGeneration &+= 1
        let stopGeneration = stoppedReportGeneration
        let task = Task { [weak self] in
            await precedingStop?.value
            await session.startTask.value
            await precedingLifecycle?.value
            await Self.performWithTimeout {
                await session.reporter.reportPlaybackStopped(
                    context: session.context,
                    positionSeconds: positionSeconds
                )
            }
            guard let self, self.stoppedReportGeneration == stopGeneration else { return }
            self.lastCompletedStoppedRequestID = session.requestID
            self.pendingStoppedReport = nil
            self.pendingStoppedRequestID = nil
        }
        pendingStoppedReport = task
        pendingStoppedRequestID = session.requestID
        return task
    }
}
