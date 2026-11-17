import CoreModel
import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// iOS 前后台往返（进程被挂起再唤醒）的决策逻辑。
///
/// 真机上内核的音频出口 / 解码会话撑不过挂起这件事，单测复现不了；这里锁的是
/// 「回来该做什么」：决策表 + 意图簿记。改动这块时别把「自动接回去」退化成
/// 「弹错误徽章等用户点重试」。
@MainActor
final class AppBackgroundPlaybackTests: XCTestCase {

    // MARK: - 决策表

    func testForegroundResumeActionTable() {
        typealias Action = AppModel.ForegroundResumeAction
        func action(_ intent: Bool, _ state: PlaybackState?, setupError: Bool = false) -> Action {
            AppModel.foregroundResumeAction(
                intentToResume: intent, state: state, hasSetupError: setupError)
        }

        // 离开前没在播（用户自己按的暂停 / 本来就停在错误页）：前台一律不动，
        // 更不能顺手把一条旧错误又重试一遍。
        XCTAssertEqual(action(false, .playing), .none)
        XCTAssertEqual(action(false, .paused), .none)
        XCTAssertEqual(action(false, .error, setupError: true), .none)

        // 内核没撑过挂起 → 重建（和手动重试同一条路，只是不用用户点）。
        XCTAssertEqual(action(true, .error), .rebuild)
        XCTAssertEqual(action(true, .paused, setupError: true), .rebuild)

        // 健康 → 接着播。
        XCTAssertEqual(action(true, .paused), .resume)
        XCTAssertEqual(action(true, .ready), .resume)
        XCTAssertEqual(action(true, .playing), .resume)

        // 换片 / 已停 / 还没起播：不是「用户离开时正在看」，不做自动动作。
        XCTAssertEqual(action(true, .idle), .none)
        XCTAssertEqual(action(true, .opening), .none)
        XCTAssertEqual(action(true, .stopped), .none)
        XCTAssertEqual(action(true, .closed), .none)

        // 控制器还没装配 / 状态未知。
        XCTAssertEqual(action(true, nil), .none)
    }

    // MARK: - 意图簿记

    func testBackgroundWithoutControllerRecordsNoResumeIntent() {
        let app = AppModel()
        let request = PlaybackRequest(title: "ep-1", uri: "/tmp/ep1.mkv", resumeSeconds: 120)
        app.presentedPlayer = request

        _ = app.playbackDidEnterBackground()

        XCTAssertFalse(app.backgroundResumeIntent, "没有控制器就没有「离开时在播」这回事")
        XCTAssertNil(app.playbackPreparation, "进后台不该动准备态")
    }

    /// 控制器在、但引擎没起来（未播放 / 已停）：前台钩子必须空转，
    /// 不能因为「有控制器」就去重建一条根本没在播的会话。
    func testForegroundHookIsNoOpWhenPlaybackWasNotRunning() {
        let app = AppModel()
        let controller = PlaybackController()
        app.playback = controller
        let request = PlaybackRequest(title: "ep-1", uri: "/tmp/ep1.mkv")
        app.presentedPlayer = request
        app.playbackPreparation = nil

        _ = app.playbackDidEnterBackground()
        XCTAssertFalse(app.backgroundResumeIntent)

        app.playbackDidEnterForeground()

        XCTAssertFalse(app.backgroundResumeIntent, "前台钩子应当把意图消费掉")
        XCTAssertEqual(app.presentedPlayer?.id, request.id, "不该换请求")
        XCTAssertNil(app.playbackPreparation, "没在播就不该盖 loading 层")
    }

    // MARK: - 进后台策略：有后台档 vs 没有

    /// **有后台档的内核（Erika）**：进后台不暂停，只把帧驱动切给定时器；
    /// 回前台切回渲染档——**不补 play()**（后台档里根本没暂停过）。
    /// 这条挂了 = 又退化成「进后台先停、回前台重建」，正是要根治的那个现象。
    func testBackgroundKeepsPlayingWhenEngineSupportsBackgroundAudio() async throws {
        let engine = BackgroundCapableProbe()
        let controller = try await makeController(engine: engine)

        XCTAssertTrue(controller.beginSystemSuspension(), "离开时在播，回前台就该接着播")
        XCTAssertEqual(engine.backgroundAudioOnlyChanges, [true], "应切进后台档")
        XCTAssertEqual(engine.pauseCalls, 0, "有后台档就不该暂停——声音要接着走")

        XCTAssertTrue(
            controller.endSystemSuspension(resumePlaying: true),
            "内核没坏，这条会话该能接着用（不必重建）"
        )
        XCTAssertEqual(engine.backgroundAudioOnlyChanges, [true, false], "应切回渲染档")
        XCTAssertEqual(engine.playCalls, 0, "后台档里没暂停过，回前台不该补 play")
    }

    /// **没有后台档的内核**：退回老做法——挂起前主动暂停，回前台 play() 解开。
    func testBackgroundPausesWhenEngineLacksBackgroundAudio() async throws {
        let engine = BackgroundIncapableProbe()
        let controller = try await makeController(engine: engine)

        XCTAssertTrue(controller.beginSystemSuspension())
        XCTAssertEqual(engine.pauseCalls, 1, "没有后台档只能在被挂起前暂停")
        XCTAssertTrue(engine.backgroundAudioOnlyChanges.isEmpty, "不支持就别调")

        // 暂停由内核事件回流（真实路径如此）。
        engine.emitPaused()
        try await waitUntil { controller.state.state == .paused }

        XCTAssertTrue(controller.endSystemSuspension(resumePlaying: true))
        XCTAssertEqual(engine.playCalls, 1, "回前台应解开那次暂停")
    }

    /// 离开前就没在播（用户自己按的暂停）：两条策略都不许动引擎。
    func testBackgroundDoesNotTouchEngineWhenNotPlaying() async throws {
        let engine = BackgroundCapableProbe()
        let controller = try await makeController(engine: engine, playing: false)

        XCTAssertFalse(controller.beginSystemSuspension(), "没在播就没有「回来接着播」这回事")
        XCTAssertTrue(engine.backgroundAudioOnlyChanges.isEmpty)
        XCTAssertEqual(engine.pauseCalls, 0)
    }

    /// 进后台时暂停就失败 = 会话已经不健康：回前台必须让 App 层走重建，
    /// 不能报「还能用」把一条死引擎留在场上。
    func testFailedPauseFallsBackToRebuild() async throws {
        let engine = BackgroundIncapableProbe()
        engine.failPause = true
        let controller = try await makeController(engine: engine)

        XCTAssertTrue(controller.beginSystemSuspension(), "照样记「回来该接着播」")
        XCTAssertFalse(
            controller.endSystemSuspension(resumePlaying: true),
            "暂停都没成功 → 不可复用 → 交给 App 层重建"
        )
    }

    /// 后台期间用户把播放停掉（锁屏按停 / 播完自动关）：回前台决策表给的是 `.none`
    /// （`resumePlaying == false`），但**驱动档位仍必须退出**——否则渲染线程再也不会
    /// 被启动，回来是一片永远不动的黑屏。
    func testLeavingBackgroundExitsAudioOnlyModeEvenWhenNotResuming() async throws {
        let engine = BackgroundCapableProbe()
        let controller = try await makeController(engine: engine)

        XCTAssertTrue(controller.beginSystemSuspension())
        engine.emitStopped()
        try await waitUntil { controller.state.state == .stopped }

        XCTAssertEqual(
            AppModel.foregroundResumeAction(
                intentToResume: true, state: .stopped, hasSetupError: false),
            .none,
            "停掉的会话不该被自动重播"
        )
        XCTAssertFalse(controller.endSystemSuspension(resumePlaying: false))
        XCTAssertEqual(
            engine.backgroundAudioOnlyChanges, [true, false],
            "档位必须退出，与「要不要接着播」无关"
        )
    }

    // MARK: - 夹具

    /// 装配一台「已在播」的控制器：注入引擎、置在播标志、让 state 吃引擎事件。
    ///
    /// `.playing` 必须**等它回流**：状态来自引擎事件流上的异步消费任务，
    /// 发完事件立刻读还是 `.idle`，那样 `beginSystemSuspension()` 会走「离开时没在播」
    /// 的分支，测的就不是这条路径了。
    private func makeController(
        engine: SuspensionProbeEngine,
        playing: Bool = true
    ) async throws -> PlaybackController {
        let controller = PlaybackController()
        controller.engine = engine
        controller.engineIsActive = true
        _ = controller.state.start(consuming: engine)
        if playing {
            engine.emitPlaying()
            try await waitUntil { controller.state.state == .playing }
        }
        return controller
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// 只观测「进后台时控制器怎么对待引擎」的替身。
///
/// 后台档能力是**类型级**的（`static var supportsBackgroundAudio`，与
/// `supportsKernelDanmaku` 同一套约定），所以两种内核得是两个类型。
private class SuspensionProbeEngine: PlaybackEngine, @unchecked Sendable {
    static let descriptor = PlaybackEngineDescriptor(
        id: "suspension-probe",
        displayName: "SuspensionProbe",
        summary: "后台策略测试替身",
        supportsKernelDanmaku: false
    )

    class var supportsBackgroundAudio: Bool { false }

    let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    let lock = NSLock()
    private var _backgroundAudioOnlyChanges: [Bool] = []
    private var _pauseCalls = 0
    private var _playCalls = 0
    var failPause = false

    init() {
        (events, continuation) = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    var backgroundAudioOnlyChanges: [Bool] { lock.withLock { _backgroundAudioOnlyChanges } }
    var pauseCalls: Int { lock.withLock { _pauseCalls } }
    var playCalls: Int { lock.withLock { _playCalls } }

    func emitPlaying() { continuation.yield(.stateChanged(.playing)) }
    func emitPaused() { continuation.yield(.stateChanged(.paused)) }
    func emitStopped() { continuation.yield(.stateChanged(.stopped)) }

    var latestMediaTime: Duration { .zero }
    var latestStats: PlaybackStats { PlaybackStats() }
    @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }

    func setBackgroundAudioOnly(_ active: Bool) {
        lock.withLock { _backgroundAudioOnlyChanges.append(active) }
    }

    func play() throws { lock.withLock { _playCalls += 1 } }

    func pause() throws {
        if failPause { throw StubError.pauseFailed }
        lock.withLock { _pauseCalls += 1 }
    }

    func open(_ source: PlaybackSource) throws {}
    func stop() throws {}
    func seek(to position: Duration) throws {}
    func setRate(_ rate: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func tracks() throws -> [TrackInfo] { [] }
    func selectAudioTrack(_ id: Int64) throws {}
    func selectSubtitleTrack(_ id: Int64?) throws {}
    @discardableResult func addExternalSubtitle(_ uri: String) throws -> Int64 { 0 }
    func setSubtitleScale(_ scale: Double) throws {}
    func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }

    private enum StubError: Error { case pauseFailed }
}

/// 有后台档的内核（Erika 的形状）。
private final class BackgroundCapableProbe: SuspensionProbeEngine, @unchecked Sendable {
    override class var supportsBackgroundAudio: Bool { true }
}

/// 没有后台档的内核（退回「挂起前暂停」那条路）。
private final class BackgroundIncapableProbe: SuspensionProbeEngine, @unchecked Sendable {}
