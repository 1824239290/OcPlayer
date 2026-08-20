import JellyfinKit
@testable import OcPlayer
import XCTest

final class PlaybackReportingCoordinatorTests: XCTestCase {
    @MainActor
    func testBackgroundProgressAndStopStayOrdered() async {
        let source = TestPlaybackStateSource(snapshot: .active(position: 12))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(stateSource: source)
        let requestID = UUID()

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-1"),
            requestID: requestID,
            resumeSeconds: 8,
            onTerminal: { _ in XCTFail("Active playback must not terminate") }
        )
        await waitUntil { reporter.events.count == 1 }

        source.snapshot = .paused(position: 19)
        await coordinator.reportBackgroundSnapshot()?.task.value
        source.snapshot = .active(position: 23)
        await coordinator.stop()?.value

        XCTAssertEqual(reporter.events, [
            .start(itemID: "episode-1", position: 8),
            .progress(itemID: "episode-1", position: 19, isPaused: true),
            .stopped(itemID: "episode-1", position: 23),
        ])
    }

    @MainActor
    func testRepeatedStopIsDeduplicated() async {
        let source = TestPlaybackStateSource(snapshot: .active(position: 42))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(stateSource: source)

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "movie-1"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.events.count == 1 }

        let firstStop = coordinator.stop()
        let duplicateStop = coordinator.stop()
        await firstStop?.value
        await duplicateStop?.value

        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
    }

    @MainActor
    func testNaturalEndReportsStoppedAndSignalsTerminalOnce() async {
        let source = TestPlaybackStateSource(snapshot: .stopped(position: 99, duration: 100))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .milliseconds(1),
            progressEveryTicks: 10
        )
        let requestID = UUID()
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-2"),
            requestID: requestID,
            resumeSeconds: nil,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { terminalEvents.count == 1 }

        XCTAssertEqual(terminalEvents, [.init(requestID: requestID, reachedEnd: true)])
        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
        XCTAssertNil(coordinator.stop())
    }

    @MainActor
    func testNaturalEndRacingExplicitStopReportsStoppedOnce() async {
        let source = TestPlaybackStateSource(snapshot: .stopped(position: 100, duration: 100))
        let reporter = TestPlaybackReporter()
        reporter.shouldSuspendStop = true
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .milliseconds(1)
        )
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-race"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { reporter.isStopSuspended }

        let explicitStop = coordinator.stop()
        reporter.resumeStoppedReport()
        await explicitStop?.value
        try? await Task.sleep(for: .milliseconds(5))

        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
        XCTAssertTrue(terminalEvents.isEmpty)
    }

    @MainActor
    func testNextStartWaitsForPreviousStoppedToFinish() async {
        let source = TestPlaybackStateSource(snapshot: .active(position: 10))
        let reporter = TestPlaybackReporter()
        reporter.shouldSuspendStop = true
        let coordinator = PlaybackReportingCoordinator(stateSource: source)

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-a"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.events.count == 1 }
        let firstStop = coordinator.stop()
        await waitUntil { reporter.isStopSuspended }

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-b"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(reporter.events.contains { $0.itemID == "episode-b" })

        reporter.resumeStoppedReport()
        await firstStop?.value
        await waitUntil { reporter.events.contains { $0.itemID == "episode-b" } }
        await coordinator.stop()?.value

        XCTAssertEqual(reporter.events.map(\.itemID), ["episode-a", "episode-a", "episode-b", "episode-b"])
    }

    @MainActor
    func testReplacementCoordinatorWaitsForHandoffStop() async {
        let firstSource = TestPlaybackStateSource(snapshot: .active(position: 10))
        let secondSource = TestPlaybackStateSource(snapshot: .active(position: 0))
        let reporter = TestPlaybackReporter()
        reporter.shouldSuspendStop = true
        let firstCoordinator = PlaybackReportingCoordinator(stateSource: firstSource)

        firstCoordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-old"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.events.count == 1 }
        let handoff = firstCoordinator.stop()
        await waitUntil { reporter.isStopSuspended }

        let secondCoordinator = PlaybackReportingCoordinator(
            stateSource: secondSource,
            precedingStoppedReport: handoff
        )
        secondCoordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-new"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(reporter.events.contains { $0.itemID == "episode-new" })

        reporter.resumeStoppedReport()
        await handoff?.value
        await waitUntil { reporter.events.contains { $0.itemID == "episode-new" } }
        await secondCoordinator.stop()?.value

        XCTAssertEqual(
            reporter.events.map(\.itemID),
            ["episode-old", "episode-old", "episode-new", "episode-new"]
        )
    }

    @MainActor
    func testPendingStopSurvivesMultipleCoordinatorHandoffs() async {
        let source = TestPlaybackStateSource(snapshot: .active(position: 10))
        let reporter = TestPlaybackReporter()
        reporter.shouldSuspendStop = true
        let firstCoordinator = PlaybackReportingCoordinator(stateSource: source)

        firstCoordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-a"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.events.count == 1 }
        let firstHandoff = firstCoordinator.stop()
        await waitUntil { reporter.isStopSuspended }

        let idleCoordinator = PlaybackReportingCoordinator(
            stateSource: source,
            precedingStoppedReport: firstHandoff
        )
        let secondHandoff = idleCoordinator.stop()
        let finalCoordinator = PlaybackReportingCoordinator(
            stateSource: source,
            precedingStoppedReport: secondHandoff
        )
        finalCoordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-c"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(reporter.events.contains { $0.itemID == "episode-c" })

        reporter.resumeStoppedReport()
        await firstHandoff?.value
        await secondHandoff?.value
        await waitUntil { reporter.events.contains { $0.itemID == "episode-c" } }
        await finalCoordinator.stop()?.value

        XCTAssertEqual(
            reporter.events.map(\.itemID),
            ["episode-a", "episode-a", "episode-c", "episode-c"]
        )
    }

    @MainActor
    func testPreparedRequestHasNoSnapshotBeforeItsSourceOpens() {
        let controller = PlaybackController()
        let request = PlaybackRequest(title: "Pending", uri: "https://example.invalid/video")

        controller.prepareForPresentation(request)

        XCTAssertNil(controller.playbackReportSnapshot(for: request.id))
    }

    @MainActor
    func testStateSourceRejectsSnapshotForAnotherRequest() {
        let requestID = UUID()
        let source = TestPlaybackStateSource(
            snapshot: .active(position: 10),
            acceptedRequestID: requestID
        )

        XCTAssertNil(source.playbackReportSnapshot(for: UUID()))
        XCTAssertNotNil(source.playbackReportSnapshot(for: requestID))
    }

    @MainActor
    func testBackgroundTerminalReturnsCleanupSignal() async {
        let source = TestPlaybackStateSource(snapshot: .error(position: 31))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(stateSource: source)
        var terminalCallbackCount = 0

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-error"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in terminalCallbackCount += 1 }
        )
        await waitUntil { reporter.events.count == 1 }

        let backgroundReport = coordinator.reportBackgroundSnapshot()
        guard case .terminal(let stopTask) = backgroundReport else {
            return XCTFail("A terminal snapshot must request AppModel cleanup")
        }
        await stopTask.value

        XCTAssertEqual(terminalCallbackCount, 0)
        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
        XCTAssertNil(coordinator.stop())
    }

    @MainActor
    func testFirstHeartbeatIsSentOnConfiguredTick() async {
        let source = CountingPlaybackStateSource()
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .milliseconds(1),
            progressEveryTicks: 10
        )

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-heartbeat"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.events.contains(where: \.isProgress) }
        await coordinator.stop()?.value

        XCTAssertEqual(
            reporter.events.first(where: \.isProgress),
            .progress(itemID: "episode-heartbeat", position: 10, isPaused: false)
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition was not met before timeout")
    }
}

@MainActor
private final class TestPlaybackStateSource: PlaybackReportingStateSource {
    var snapshot: PlaybackReportSnapshot
    let acceptedRequestID: PlaybackRequest.ID?

    init(
        snapshot: PlaybackReportSnapshot,
        acceptedRequestID: PlaybackRequest.ID? = nil
    ) {
        self.snapshot = snapshot
        self.acceptedRequestID = acceptedRequestID
    }

    func playbackReportSnapshot(for requestID: PlaybackRequest.ID) -> PlaybackReportSnapshot? {
        guard acceptedRequestID == nil || acceptedRequestID == requestID else { return nil }
        return snapshot
    }
}

@MainActor
private final class CountingPlaybackStateSource: PlaybackReportingStateSource {
    private var count = 0

    func playbackReportSnapshot(for requestID: PlaybackRequest.ID) -> PlaybackReportSnapshot? {
        count += 1
        return .active(position: Double(count))
    }
}

@MainActor
private final class TestPlaybackReporter: PlaybackReporting {
    enum Event: Equatable {
        case start(itemID: String, position: Double)
        case progress(itemID: String, position: Double, isPaused: Bool)
        case stopped(itemID: String, position: Double)

        var itemID: String {
            switch self {
            case .start(let itemID, _), .progress(let itemID, _, _), .stopped(let itemID, _):
                itemID
            }
        }

        var isStopped: Bool {
            if case .stopped = self { true } else { false }
        }

        var isProgress: Bool {
            if case .progress = self { true } else { false }
        }
    }

    var events: [Event] = []
    var shouldSuspendStop = false
    private(set) var isStopSuspended = false
    private var stoppedContinuation: CheckedContinuation<Void, Never>?

    func reportPlaybackStart(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async {
        events.append(.start(itemID: context.itemID, position: positionSeconds))
    }

    func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        events.append(.progress(
            itemID: context.itemID,
            position: positionSeconds,
            isPaused: isPaused
        ))
    }

    func reportPlaybackStopped(
        context: PlaybackSessionContext,
        positionSeconds: Double
    ) async {
        events.append(.stopped(itemID: context.itemID, position: positionSeconds))
        guard shouldSuspendStop else { return }
        isStopSuspended = true
        await withCheckedContinuation { stoppedContinuation = $0 }
        isStopSuspended = false
    }

    func resumeStoppedReport() {
        shouldSuspendStop = false
        stoppedContinuation?.resume()
        stoppedContinuation = nil
    }
}

private extension PlaybackReportSnapshot {
    static func active(position: Double) -> Self {
        Self(state: .active, positionSeconds: position, durationSeconds: 100, sourceOpenFailed: false)
    }

    static func paused(position: Double) -> Self {
        Self(state: .paused, positionSeconds: position, durationSeconds: 100, sourceOpenFailed: false)
    }

    static func stopped(position: Double, duration: Double) -> Self {
        Self(state: .stopped, positionSeconds: position, durationSeconds: duration, sourceOpenFailed: false)
    }

    static func error(position: Double) -> Self {
        Self(state: .error, positionSeconds: position, durationSeconds: 100, sourceOpenFailed: false)
    }
}
