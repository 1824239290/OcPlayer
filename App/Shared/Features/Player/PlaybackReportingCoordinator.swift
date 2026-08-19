import Foundation
import JellyfinKit

@MainActor
protocol PlaybackReporting {
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
    struct TerminalEvent: Equatable {
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

    private struct Session {
        let generation: UInt64
        let reporter: any PlaybackReporting
        let context: PlaybackSessionContext
        let requestID: PlaybackRequest.ID
        let startTask: Task<Void, Never>
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

    func start(
        reporter: any PlaybackReporting,
        context: PlaybackSessionContext,
        requestID: PlaybackRequest.ID,
        resumeSeconds: Double?,
        onTerminal: @escaping @MainActor (TerminalEvent) -> Void
    ) {
        // Keep the coordinator correct even when a caller starts a new request
        // without first calling stop (AppModel normally does that explicitly).
        let precedingStop = stop() ?? pendingStoppedReport
        generation &+= 1
        let sessionGeneration = generation
        let startTask = Task {
            await precedingStop?.value
            await reporter.reportPlaybackStart(
                context: context,
                positionSeconds: resumeSeconds ?? 0
            )
        }
        let activeSession = Session(
            generation: sessionGeneration,
            reporter: reporter,
            context: context,
            requestID: requestID,
            startTask: startTask
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
                    onTerminal(TerminalEvent(
                        requestID: requestID,
                        reachedEnd: snapshot.state == .stopped
                            && snapshot.durationSeconds > 0
                            && snapshot.positionSeconds >= snapshot.durationSeconds - 2
                    ))
                    return
                }

                if ticks % self.progressEveryTicks == 0 {
                    let progressTask = self.enqueueProgressReport(
                        session: activeSession,
                        snapshot: snapshot
                    )
                    await progressTask.value
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
            await session.reporter.reportPlaybackProgress(
                context: session.context,
                positionSeconds: snapshot.positionSeconds,
                isPaused: snapshot.state == .paused
            )
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
            await session.reporter.reportPlaybackStopped(
                context: session.context,
                positionSeconds: positionSeconds
            )
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
