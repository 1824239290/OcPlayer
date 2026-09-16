import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// 跳过片头/片尾偏好的测试：
/// - 纯函数（门控、保底落点）直接断言；
/// - 偏好默认值与非法存量值回落（UserDefaults 是测试宿主的真实域，存取后要清理）；
/// - 控制器链路用直注引擎替身验证 performSkip 的实际 seek 落点。
@MainActor
final class SkipPreferenceTests: XCTestCase {

    private var savedSkipIntro: Bool?
    private var savedSkipOutro: Bool?
    private var savedRetention: Int?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SettingsKeys.skipIntro) != nil {
            savedSkipIntro = defaults.bool(forKey: SettingsKeys.skipIntro)
        }
        if defaults.object(forKey: SettingsKeys.skipOutro) != nil {
            savedSkipOutro = defaults.bool(forKey: SettingsKeys.skipOutro)
        }
        if defaults.object(forKey: SettingsKeys.outroRetentionSeconds) != nil {
            savedRetention = defaults.integer(forKey: SettingsKeys.outroRetentionSeconds)
        }
        defaults.removeObject(forKey: SettingsKeys.skipIntro)
        defaults.removeObject(forKey: SettingsKeys.skipOutro)
        defaults.removeObject(forKey: SettingsKeys.outroRetentionSeconds)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        // 还原真实域：键从未写过就清掉，别把测试值留给宿主 App。
        if let savedSkipIntro {
            defaults.set(savedSkipIntro, forKey: SettingsKeys.skipIntro)
        } else {
            defaults.removeObject(forKey: SettingsKeys.skipIntro)
        }
        if let savedSkipOutro {
            defaults.set(savedSkipOutro, forKey: SettingsKeys.skipOutro)
        } else {
            defaults.removeObject(forKey: SettingsKeys.skipOutro)
        }
        if let savedRetention {
            defaults.set(savedRetention, forKey: SettingsKeys.outroRetentionSeconds)
        } else {
            defaults.removeObject(forKey: SettingsKeys.outroRetentionSeconds)
        }
        super.tearDown()
    }

    // MARK: - 偏好默认值

    func testSkipTogglesDefaultOn() {
        XCTAssertTrue(PlaybackPreferences.skipIntroEnabled)
        XCTAssertTrue(PlaybackPreferences.skipOutroEnabled)
    }

    func testOutroRetentionDefaultsToTen() {
        // 原硬编码 20s，本次改默认 10s；键从未落盘，读取必须给 10。
        XCTAssertEqual(PlaybackPreferences.outroRetentionSeconds, 10)
    }

    func testOutroRetentionRejectsValueOutsideOptions() {
        UserDefaults.standard.set(7, forKey: SettingsKeys.outroRetentionSeconds)
        XCTAssertEqual(PlaybackPreferences.outroRetentionSeconds, 10, "档位外的存量值回落默认")
        UserDefaults.standard.set(0, forKey: SettingsKeys.outroRetentionSeconds)
        XCTAssertEqual(PlaybackPreferences.outroRetentionSeconds, 0, "0（不保留）是合法档位")
        UserDefaults.standard.set(20, forKey: SettingsKeys.outroRetentionSeconds)
        XCTAssertEqual(PlaybackPreferences.outroRetentionSeconds, 20)
    }

    // MARK: - 保底片尾落点（endCreditsSkipTarget）

    func testEndCreditsSkipTargetUsesConfiguredRetention() {
        XCTAssertEqual(PlaybackController.endCreditsSkipTarget(
            position: 1150, duration: 1200, retentionSeconds: 10), 1190)
        XCTAssertEqual(PlaybackController.endCreditsSkipTarget(
            position: 1150, duration: 1200, retentionSeconds: 20), 1180)
        XCTAssertEqual(PlaybackController.endCreditsSkipTarget(
            position: 1150, duration: 1200, retentionSeconds: 30), 1170)
    }

    func testEndCreditsSkipTargetZeroRetentionClampsBeforeEOF() {
        // 不保留也不能 seek 到片长整点：EOF 之后内核会进错误风暴。
        XCTAssertEqual(PlaybackController.endCreditsSkipTarget(
            position: 1150, duration: 1200, retentionSeconds: 0), 1199.5)
    }

    func testEndCreditsSkipTargetNeverSeeksBackward() {
        // 播放位置已越过「片长 − 保留」时落点取当前位置，不往回跳。
        XCTAssertEqual(PlaybackController.endCreditsSkipTarget(
            position: 1195, duration: 1200, retentionSeconds: 10), 1195)
    }

    // MARK: - 提示门控（promptGatedByPreferences）

    private func mark(_ kind: SkipKind, start: Double, end: Double) -> SkipMark {
        SkipMark(id: "\(kind.rawValue)-\(Int(start))", source: .chapterHeuristic,
                 kind: kind, startSeconds: start, endSeconds: end)
    }

    func testPromptGatingHidesOpeningWhenIntroDisabled() {
        let prompt = SkipPrompt.mark(mark(.opening, start: 0, end: 90))
        XCTAssertNil(PlaybackController.promptGatedByPreferences(
            prompt, skipIntro: false, skipOutro: true))
        XCTAssertEqual(PlaybackController.promptGatedByPreferences(
            prompt, skipIntro: true, skipOutro: true), prompt)
    }

    func testPromptGatingHidesMarkAndFallbackCreditsWhenOutroDisabled() {
        let markPrompt = SkipPrompt.mark(mark(.credits, start: 1100, end: 1200))
        let fallback = SkipPrompt.endCredits(position: 1150)
        XCTAssertNil(PlaybackController.promptGatedByPreferences(
            markPrompt, skipIntro: true, skipOutro: false))
        XCTAssertNil(PlaybackController.promptGatedByPreferences(
            fallback, skipIntro: true, skipOutro: false))
        XCTAssertEqual(PlaybackController.promptGatedByPreferences(
            fallback, skipIntro: true, skipOutro: true), fallback)
    }

    // MARK: - 控制器链路

    /// 直注引擎替身：只记录 seek，事件由测试手动注入（不走 open 装配链路）。
    private final class SeekRecordingEngine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(
            id: "seek-recording",
            displayName: "SeekRecording",
            summary: "测试替身",
            supportsKernelDanmaku: false
        )

        let events: AsyncStream<PlayerEvent>
        private let eventContinuation: AsyncStream<PlayerEvent>.Continuation
        private let lock = NSLock()
        private var _seeks: [Duration] = []
        var seeks: [Duration] { lock.withLock { _seeks } }

        init() {
            (events, eventContinuation) = AsyncStream<PlayerEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(256))
        }

        func emit(_ event: PlayerEvent) { eventContinuation.yield(event) }

        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { PlaybackStats() }
        @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }
        func open(_ source: PlaybackSource) throws {}
        func play() throws {}
        func pause() throws {}
        func stop() throws {}
        func seek(to position: Duration) throws { lock.withLock { _seeks.append(position) } }
        func setRate(_ rate: Double) throws {}
        func setVolume(_ volume: Double) throws {}
        func tracks() throws -> [TrackInfo] { [] }
        func selectAudioTrack(_ id: Int64) throws {}
        func selectSubtitleTrack(_ id: Int64?) throws {}
        @discardableResult func addExternalSubtitle(_ uri: String) throws -> Int64 { 0 }
        func setSubtitleScale(_ scale: Double) throws {}
        func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }
    }

    /// 把引擎替身直注控制器并消费事件流，等 playing / 片长 / 位置就位。
    private func makeController(
        engine: SeekRecordingEngine,
        duration: Duration,
        position: Duration
    ) async throws -> PlaybackController {
        let controller = PlaybackController()
        controller.engine = engine
        controller.eventTask = controller.state.start(consuming: engine)
        engine.emit(.stateChanged(.playing))
        engine.emit(.durationChanged(duration))
        engine.emit(.positionChanged(position))
        let deadline = Date().addingTimeInterval(3)
        while !(controller.state.state == .playing
                && controller.state.duration == duration
                && controller.state.position == position), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return controller
    }

    func testPerformSkipSeeksToDurationMinusDefaultRetention() async throws {
        let engine = SeekRecordingEngine()
        let controller = try await makeController(
            engine: engine, duration: .seconds(1200), position: .seconds(1150))

        controller.performSkip()

        XCTAssertEqual(engine.seeks, [.seconds(1190)], "默认保留 10s：1200 − 10")
    }

    func testPerformSkipHonorsZeroRetention() async throws {
        UserDefaults.standard.set(0, forKey: SettingsKeys.outroRetentionSeconds)
        let engine = SeekRecordingEngine()
        let controller = try await makeController(
            engine: engine, duration: .seconds(1200), position: .seconds(1150))

        controller.performSkip()

        XCTAssertEqual(engine.seeks, [.seconds(1199.5)], "不保留时钳在片长 − 0.5s")
    }

    func testCurrentSkipPromptRespectsOutroToggle() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKeys.skipOutro)
        let engine = SeekRecordingEngine()
        let controller = try await makeController(
            engine: engine, duration: .seconds(1200), position: .seconds(1150))

        XCTAssertNil(controller.currentSkipPrompt, "跳过片尾关闭时末 90s 保底不弹")

        UserDefaults.standard.set(true, forKey: SettingsKeys.skipOutro)
        XCTAssertEqual(controller.currentSkipPrompt?.kind, .credits)
    }
}
