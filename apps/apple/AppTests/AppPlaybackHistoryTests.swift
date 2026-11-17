import CoreModel
import JellyfinKit
@testable import PlaybackKit
import XCTest
@testable import OcPlayer

@MainActor
final class AppPlaybackHistoryTests: XCTestCase {
    private var directory: URL!
    private var store: AppPlaybackHistoryStore!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        store = AppPlaybackHistoryStore(directory: directory)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
    private var item: MediaItem {
        MediaItem(id: "episode", name: "第一集", kind: .episode, runtimeSeconds: 1440,
                  playState: .init(played: false, percentage: 0, positionSeconds: 0))
    }
    private func record(_ id: String, source: String = "account-a", seconds: Double) -> AppPlaybackRecord {
        let day = Calendar.current.startOfDay(for: Date())
        return .init(id: id, sourceID: source, item: item, day: day, watchedAt: day.addingTimeInterval(3600), seconds: seconds)
    }

    func testCheckpointsAreCumulativeAndSurviveRelaunch() async throws {
        try await store.save(record("session-day", seconds: 30))
        try await store.save(record("session-day", seconds: 60))
        try await store.save(record("session-day", seconds: 60))
        try await store.save(record("session-day", seconds: 15))
        let reloaded = AppPlaybackHistoryStore(directory: directory!)
        let values = try await reloaded.read(sourceID: "account-a")
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.seconds, 60)
        XCTAssertEqual(values.first?.item.playState?.played, false)
        XCTAssertEqual(values.first?.item.playState?.positionSeconds, 0)
    }

    func testDifferentSessionsAndAccountsRemainIndependent() async throws {
        try await store.save(record("s1", seconds: 20))
        try await store.save(record("s2", seconds: 40))
        try await store.save(record("s1", source: "account-b", seconds: 80))
        let a = try await store.read(sourceID: "account-a")
        let b = try await store.read(sourceID: "account-b")
        XCTAssertEqual(a.reduce(0) { $0 + $1.seconds }, 60)
        XCTAssertEqual(b.reduce(0) { $0 + $1.seconds }, 80)
    }

    func testRecorderFlushesPartialSessionOnPauseAndExit() async throws {
        let recorder = AppPlaybackRecorder(store: store)
        let now = Date()
        recorder.start(sourceID: "account-a", item: item)
        for second in 0...120 {
            recorder.sample(position: 300 + Double(second), playing: true, buffering: false, rate: 1,
                            time: Double(second), date: now.addingTimeInterval(Double(second)))
        }
        recorder.sample(position: 420, playing: false, buffering: false, rate: 1, time: 121, date: now.addingTimeInterval(121))
        await recorder.pendingWrite?.value
        var values = try await store.read(sourceID: "account-a")
        XCTAssertEqual(values.reduce(0) { $0 + $1.seconds }, 120, accuracy: 0.001)
        recorder.sample(position: 420, playing: false, buffering: false, rate: 1, time: 180, date: now.addingTimeInterval(180))
        await recorder.finish()?.value
        values = try await store.read(sourceID: "account-a")
        XCTAssertEqual(values.reduce(0) { $0 + $1.seconds }, 120, accuracy: 0.001)
        XCTAssertEqual(values.first?.item.playState?.played, false)
    }

    func testRecorderSplitsLocalMidnight() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8))!
        let recorder = AppPlaybackRecorder(store: store, calendar: calendar)
        recorder.start(sourceID: "account-a", item: item)
        recorder.sample(position: 0, playing: true, buffering: false, rate: 1, time: 0, date: midnight.addingTimeInterval(-0.5))
        recorder.sample(position: 1, playing: true, buffering: false, rate: 1, time: 1, date: midnight.addingTimeInterval(0.5))
        await recorder.finish()?.value
        let values = try await store.read(sourceID: "account-a")
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Set(values.map(\.day)).count, 2)
        XCTAssertTrue(values.allSatisfy { abs($0.seconds - 0.5) < 0.001 })
        XCTAssertTrue(values.allSatisfy { calendar.isDate($0.day, inSameDayAs: $0.watchedAt) })
    }

    func testSwitchingItemsRetainsBothSessions() async throws {
        let recorder = AppPlaybackRecorder(store: store)
        recorder.start(sourceID: "account-a", item: item)
        recorder.sample(position: 0, playing: true, buffering: false, rate: 1, time: 0)
        recorder.sample(position: 1, playing: true, buffering: false, rate: 1, time: 1)
        recorder.start(sourceID: "account-b", item: MediaItem(id: "b", name: "第二集", kind: .episode))
        recorder.sample(position: 0, playing: true, buffering: false, rate: 1, time: 2)
        recorder.sample(position: 1, playing: true, buffering: false, rate: 1, time: 3)
        await recorder.finish()?.value
        let a = try await store.read(sourceID: "account-a")
        let b = try await store.read(sourceID: "account-b")
        XCTAssertEqual(a.first?.seconds, 1)
        XCTAssertEqual(b.first?.seconds, 1)
    }

    func testDirectLinkDoesNotPersistCredentials() {
        let request = PlaybackRequest(title: "测试影片", uri: "https://user:password@example.com/video.mkv?api_key=secret", authHeader: "secret")
        let value = AppPlaybackRecorder.localItem(for: request)
        XCTAssertFalse(value.id.contains("secret"))
        XCTAssertFalse(value.id.contains("password"))
        XCTAssertTrue(value.id.hasPrefix("local:"))
        XCTAssertEqual(value.kind, .other)
    }

    func testControllerRebindsClockAfterReplacingPlayerStateAndFlushesOnStop() async throws {
        let recorder = AppPlaybackRecorder(store: store)
        let controller = PlaybackController(watchRecorder: recorder)
        let previousRate = controller.rate
        defer { controller.rate = previousRate }
        controller.rate = 1
        let request = PlaybackRequest(title: "测试影片", uri: "/test.mp4")
        controller.prepareForPresentation(request)
        controller.startLocalViewingRecord(sourceID: "account-a", item: item)
        let previous = controller.state
        controller.state = PlayerState() // Real openPreparedRequest replaces this object.
        XCTAssertNil(previous.onPlaybackActivityChanged)
        XCTAssertNotNil(controller.state.onPlaybackActivityChanged)
        controller.activeRequest = request
        controller.state.apply(.stateChanged(.playing))
        try await Task.sleep(for: .milliseconds(350))
        controller.state.apply(.positionChanged(.milliseconds(350)))
        controller.state.apply(.stateChanged(.paused))
        await recorder.pendingWrite?.value
        controller.stopPlayback()
        await recorder.pendingWrite?.value
        let values = try await store.read(sourceID: "account-a")
        XCTAssertEqual(values.count, 1)
        XCTAssertGreaterThan(values[0].seconds, 0.25)
        XCTAssertLessThanOrEqual(values[0].seconds, 0.36)
        XCTAssertEqual(values[0].item.playState?.played, false)
    }
}
