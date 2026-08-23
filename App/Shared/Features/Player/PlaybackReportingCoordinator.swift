import Foundation
import JellyfinKit

@MainActor
protocol PlaybackReporting: Sendable {
    func reportPlaybackStart(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async

    func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async

    func reportPlaybackStopped(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async
}

extension JellyfinServer: PlaybackReporting {}

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

    /// `stop()` 收口时是否该按「自然播完」触发终态事件。
    /// 与心跳分支共用判定:只有引擎已发出 `.stopped`(播放器主动停也会经过这里,
    /// 但那时不满足「位置在末尾」)才认为是自然到尾,避免片尾手动关闭被误判成连播。
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

    private static func performWithTimeout(
        duration: Duration = .seconds(5),
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let task = Task { @MainActor in
            await operation()
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: duration)
            task.cancel()
        }
        await task.value
        timeoutTask.cancel()
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
                    let reachedEnd = snapshot.state == .stopped && Self.isReachedEnd(snapshot: snapshot)
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
