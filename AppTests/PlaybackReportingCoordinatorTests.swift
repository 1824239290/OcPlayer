import JellyfinKit
@testable import OcPlayer
import XCTest

final class PlaybackReportingCoordinatorTests: XCTestCase {

    /// `reportTimeout` 是进程级静态：用例改过它必须还原，否则会串到后面的用例
    /// （表现为"某条上报莫名没发出去"这种极难定位的失败）。
    private var savedReportTimeout: Duration = .seconds(5)

    override func setUp() {
        super.setUp()
        savedReportTimeout = PlaybackReportingCoordinator.reportTimeout
    }

    override func tearDown() {
        PlaybackReportingCoordinator.reportTimeout = savedReportTimeout
        super.tearDown()
    }

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
        let requestID = UUID()
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-race"),
            requestID: requestID,
            resumeSeconds: nil,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { reporter.isStopSuspended }

        let explicitStop = coordinator.stop()
        reporter.resumeStoppedReport()
        await explicitStop?.value
        try? await Task.sleep(for: .milliseconds(5))

        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
        XCTAssertEqual(terminalEvents, [.init(requestID: requestID, reachedEnd: true)])
    }

    @MainActor
    func testMidPlaybackExplicitStopDoesNotSignalTerminal() async {
        let source = TestPlaybackStateSource(snapshot: .active(position: 10))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(stateSource: source)
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-mid"),
            requestID: UUID(),
            resumeSeconds: nil as Double?,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { reporter.events.count == 1 }

        _ = coordinator.stop()
        XCTAssertTrue(terminalEvents.isEmpty)
    }

    /// 回归（兜底拆除后）：片尾的 `.error` **不再**被认成「播完」——内核 v0.3.0
    /// （上游 #169）起尾读按 EOF 干净收口，能到这里的错误都是真错误：徽章该露、
    /// 连播不该触发。谁要是把 `.error` 重新接进终态判定，这条会红。
    @MainActor
    func testEndOfStreamErrorSignalsTerminalWithoutReachedEnd() async {
        // 实测现场同款位置：1471.512s / 时长 1472s（片长 − 0.488s）。
        let source = TestPlaybackStateSource(snapshot: .error(position: 1471.512, duration: 1472))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .milliseconds(1)
        )
        let requestID = UUID()
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-eof-error"),
            requestID: requestID,
            resumeSeconds: nil,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { terminalEvents.count == 1 }

        XCTAssertEqual(terminalEvents, [.init(requestID: requestID, reachedEnd: false)])
        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
    }

    /// 片中（离片尾还远）的错误仍然只报 `reachedEnd=false`：错误徽章 + 「重试」那条路
    /// 不能因为上面那条兜底被改掉。
    @MainActor
    func testMidStreamErrorSignalsTerminalWithoutReachedEnd() async {
        let source = TestPlaybackStateSource(snapshot: .error(position: 31, duration: 100))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .milliseconds(1)
        )
        let requestID = UUID()
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-mid-error"),
            requestID: requestID,
            resumeSeconds: nil,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { terminalEvents.count == 1 }

        XCTAssertEqual(terminalEvents, [.init(requestID: requestID, reachedEnd: false)])
        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
    }

    /// 宿主主动 `stop()`（关播放器 / 换控制器）时，片尾的 `.error` **不算**播完——
    /// 那时用户正在拆台，反过来触发连播是错的（见 `isNaturalEnd` 的注释）。
    @MainActor
    func testEndOfStreamErrorOnExplicitStopDoesNotSignalTerminal() async {
        let source = TestPlaybackStateSource(snapshot: .error(position: 1471.512, duration: 1472))
        let reporter = TestPlaybackReporter()
        // 心跳窗口放到用例跑不完的长度：只让 `stop()` 这条路径有机会触发。
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .seconds(60)
        )
        var terminalEvents: [PlaybackReportingCoordinator.TerminalEvent] = []

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-eof-error-stop"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { terminalEvents.append($0) }
        )
        await waitUntil { reporter.events.count == 1 }

        await coordinator.stop()?.value

        XCTAssertTrue(terminalEvents.isEmpty)
        XCTAssertEqual(reporter.events.filter(\.isStopped).count, 1)
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

    /// 回归：**暂停后不再每 N tick 重复上报**。
    ///
    /// 原实现里 `.paused` 不被终止态判据拦下，直接落到
    /// `ticks % progressEveryTicks == 0` 的通用分支 —— 于是暂停挂机也每 10 s 发一次
    /// 真实 POST（**360 次/小时**），而暂停期间播放位置根本不再前进：除第一条外，
    /// 后面每一条都是同一条数据的复制品。
    ///
    /// 语义要求两条，缺一不可：
    /// 1. 进入暂停时**仍要报一次**（服务端需要「停在哪 + 现在是暂停」）；
    /// 2. 暂停期间不再重复；恢复播放后照常恢复上报。
    @MainActor
    func testPausedDoesNotRepeatProgressReports() async {
        let source = TestPlaybackStateSource(snapshot: .paused(position: 30))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source,
            heartbeatInterval: .milliseconds(5),
            progressEveryTicks: 2
        )

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-paused"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )

        // 1) 暂停后必须**先报一次**，且标明 isPaused。
        await waitUntil { reporter.progressCount >= 1 }
        XCTAssertEqual(reporter.progressCount, 1, "进入暂停时要上报一次")
        XCTAssertEqual(reporter.progressPausedFlags, [true], "这一条要标成暂停")

        // 2) 再等约 40 个 tick（每 tick 5 ms）：不该再多出任何一条。
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reporter.progressCount, 1, "暂停期间不该重复上报")

        // 3) 恢复播放后照常上报。
        source.snapshot = .active(position: 31)
        await waitUntil { reporter.progressCount >= 2 }
        XCTAssertEqual(reporter.progressPausedFlags, [true, false], "恢复后要按非暂停上报")

        await coordinator.stop()?.value
    }

    // MARK: - 上报超时

    /// 回归：「超时」此前**不生效**。原实现是「到点 `task.cancel()`，然后仍
    /// `await task.value`」—— 等的是任务**完成**而不是取消，所以只要上报实现不响应
    /// 取消，调用方就会一直挂着。
    ///
    /// 后果不只是慢：上报是一条串行链（`await precedingStop?.value` →
    /// `await startTask.value` → …），一个卡住的上报会把后面**所有**上报堵死，
    /// 表现为「上报静默失效」，而日志上看只是"网络慢"。
    ///
    /// `TestPlaybackReporter.shouldSuspendStop` 用 `withCheckedContinuation` 挂起、
    /// 天然不响应取消 —— 正好是这里要覆盖的非合作实现。
    @MainActor
    func testNonCooperativeReportDoesNotBlockTheChain() async {
        PlaybackReportingCoordinator.reportTimeout = .milliseconds(80)
        let source = TestPlaybackStateSource(snapshot: .stopped(position: 50, duration: 100))
        let reporter = TestPlaybackReporter()
        reporter.shouldSuspendStop = true   // 这次 stopped 上报永远不会自己返回
        // 短心跳：`.stopped` 快照要靠心跳才触发终报（默认 1s 会撞上 waitUntil 上限）。
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source, heartbeatInterval: .milliseconds(1))
        let requestID = UUID()

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-stuck"),
            requestID: requestID,
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.isStopSuspended }

        let stopTask = coordinator.stop()
        let start = Date()
        await stopTask?.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 1.0,
            "上报不响应取消时，调用方也必须在超时后返回（实测耗时 \(elapsed)s）；"
                + "原实现在这里会一直挂住")
        // 被放弃的那次上报仍跑在后台，收尾一下避免影响后续断言。
        reporter.resumeStoppedReport()
    }

    /// 合作的上报（正常返回）不该等满超时。
    @MainActor
    func testCooperativeReportReturnsImmediately() async {
        PlaybackReportingCoordinator.reportTimeout = .seconds(10)
        let source = TestPlaybackStateSource(snapshot: .stopped(position: 50, duration: 100))
        let reporter = TestPlaybackReporter()
        let coordinator = PlaybackReportingCoordinator(
            stateSource: source, heartbeatInterval: .milliseconds(1))

        coordinator.start(
            reporter: reporter,
            context: PlaybackSessionContext(itemID: "episode-fast"),
            requestID: UUID(),
            resumeSeconds: nil,
            onTerminal: { _ in }
        )
        await waitUntil { reporter.events.contains(where: \.isStopped) }

        let start = Date()
        await coordinator.stop()?.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "正常返回的上报不该等满 10s 超时")
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
    /// 进度上报条数（暂停期间的「是不是重复发了」靠它数）。
    var progressCount: Int {
        events.filter(\.isProgress).count
    }

    /// 每条进度上报的 `isPaused`，按发生顺序。
    var progressPausedFlags: [Bool] {
        events.compactMap { event in
            guard case let .progress(_, _, isPaused) = event else { return nil }
            return isPaused
        }
    }
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

    static func error(position: Double, duration: Double = 100) -> Self {
        Self(state: .error, positionSeconds: position, durationSeconds: duration, sourceOpenFailed: false)
    }
}
