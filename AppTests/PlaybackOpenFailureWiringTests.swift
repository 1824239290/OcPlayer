import Foundation
import JellyfinKit
import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// `PlaybackController` 打开失败 → `onOpenFailure` 回调的**接线**。
///
/// ## 为什么这组必须单独存在
///
/// `PlaybackSourceFailoverTests` 测的是「拿到失败之后怎么决策」，它直接喂
/// `(requestID, kind)`。**但如果 `finishOpenFailure` 里那行回调从来没被调用，
/// 决策层那 6 条依然全绿——功能等于没做，测试却没意见。**
/// 所以这里只钉三件事：回调确实会响、响几次、以及**该静默的时候是否真的静默**。
///
/// ## 判据怎么被证伪（已实测）
///
/// 删掉 `PlaybackController.swift:995` 的 `onOpenFailure?(request.id, kind)`，
/// 前两条必须红。2026-11-03 实测：两条都「等待条件超时」，
/// `xcresult=/tmp/ocp-l1wc-211625.xcresult`（result=Failed 0/2）。
///
/// ## 覆盖边界：代次守卫**无测试覆盖，且当前不可达**
///
/// 第三条 `testSupersededFailureDoesNotCallBack` 守的是「被顶替的旧请求失败不回调」，
/// 它走的是控制器的 supersede 路由（`finishOpenSuperseded`），不是 `finishOpenFailure`
/// 开头那道 `guard sourceGeneration == generation`。
///
/// 2026-11-03 实测：把该守卫改成恒真，第三条**仍然绿**
/// （`xcresult=/tmp/ocp-l1wm-211404.xcresult`，result=Passed 1/0）。
/// 复核原因（Player）：`sourceGeneration` 共 4 处递增（`:545` / `:646` / `:976` / `:1160`），
/// 其中三处都在递增前 `openingAttempt?.cancel()`，于是该 attempt 的完成回调先命中
/// `attempt.cancelled` 走 `finishOpenSuperseded`；第四处在守卫之后。四个调用点
/// （同步两处、完成回调、看门狗）也都不满足「抵达时 generation 不相等」。
/// ⇒ **守卫当前不可达，所以没有任何用例能让它变红。**
///
/// 证伪入口：将来若有人加了「递增代次但不 cancel」的路径，或把某个调用点的
/// `generation` 改成 `await` 之前捕获，这条判断立刻失效，守卫也立刻变成有效防护。
///
@MainActor
final class PlaybackOpenFailureWiringTests: XCTestCase {

    // MARK: - 可门控内核替身（与 PlaybackControllerOpenTests 同一套路）

    private final class GatedFakeEngine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(
            id: "wiring-gated-fake",
            displayName: "WiringGatedFake",
            summary: "接线测试替身",
            supportsKernelDanmaku: false
        )

        let events: AsyncStream<PlayerEvent>
        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { PlaybackStats() }

        @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }

        private let lock = NSLock()
        private var _openCalls = 0
        private var _openError: Error?
        private let gate = DispatchSemaphore(value: 0)
        private var eventContinuation: AsyncStream<PlayerEvent>.Continuation

        init() {
            var continuation: AsyncStream<PlayerEvent>.Continuation!
            (events, continuation) = AsyncStream<PlayerEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
            eventContinuation = continuation
        }

        var openCalls: Int { lock.withLock { _openCalls } }
        func failOpen(_ error: Error) { lock.withLock { _openError = error } }
        func releaseGate() { gate.signal() }

        func open(_ source: PlaybackSource) throws {
            lock.withLock { _openCalls += 1 }
            gate.wait()
            if let error = lock.withLock({ _openError }) { throw error }
        }
        func play() throws {}
        func pause() throws {}
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
    }

    // MARK: - 夹具

    private var savedSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        savedSelection = PlaybackEngineRegistry.storedSelectionID
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.clearSelection()
        let deadline = Date().addingTimeInterval(3)
        while PlaybackController.activeOpenAttemptsForTesting != 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        PlaybackController.resetOpenAttemptCountersForTesting()
    }

    override func tearDown() {
        PlaybackController.openWatchdogTimeout = PlaybackController.openWatchdogDefault
        PlaybackEngineRegistry.resetForTesting()
        if let savedSelection {
            PlaybackEngineRegistry.select(savedSelection)
        } else {
            PlaybackEngineRegistry.clearSelection()
        }
        PlaybackEngineAssembly.registerAll()
        super.tearDown()
    }

    private func installEngines(_ engines: [GatedFakeEngine]) {
        var index = 0
        PlaybackEngineRegistry.register(GatedFakeEngine.descriptor) {
            defer { index += 1 }
            return engines[min(index, engines.count - 1)]
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 让「失败」这条消息可被确定性分类：中文文案直接命中网络桶。
    private var networkFailure: Error { JellyfinError(.other("连接媒体服务器超时")) }

    // MARK: - ① 失败必须回调，且带上 requestID 与类别

    func testOpenFailureCallsBackOnceWithRequestIDAndKind() async throws {
        let engine = GatedFakeEngine()
        installEngines([engine])
        let controller = PlaybackController()
        let request = PlaybackRequest(title: "A", uri: "file:///tmp/a.mp4")

        var calls: [(PlaybackRequest.ID, PlaybackOpenErrorKind)] = []
        controller.onOpenFailure = { calls.append(($0, $1)) }

        engine.failOpen(networkFailure)
        controller.open(request: request)
        try await waitUntil { engine.openCalls > 0 }
        engine.releaseGate()
        try await waitUntil { !calls.isEmpty }

        XCTAssertEqual(calls.count, 1, "一次失败只许回调一次")
        XCTAssertEqual(calls.first?.0, request.id, "回调必须带上这条请求的 id，换源决策靠它")
        XCTAssertEqual(calls.first?.1, .network, "类别要与落进 setupError 的那份一致")
        XCTAssertEqual(controller.setupErrorKind, .network)
        XCTAssertTrue(
            controller.setupError?.contains(PlaybackOpenErrorKind.network.label) == true,
            "徽章文案要带类别前缀，实际：\(controller.setupError ?? "nil")"
        )
    }

    // MARK: - ② 同一请求失败两次（重试）⇒ 回调两次、id 相同

    func testRetryOfSameRequestCallsBackAgain() async throws {
        let engine = GatedFakeEngine()
        installEngines([engine])
        let controller = PlaybackController()
        let request = PlaybackRequest(title: "A", uri: "file:///tmp/a.mp4")

        var calls: [(PlaybackRequest.ID, PlaybackOpenErrorKind)] = []
        controller.onOpenFailure = { calls.append(($0, $1)) }
        engine.failOpen(networkFailure)

        controller.open(request: request)
        try await waitUntil { engine.openCalls > 0 }
        engine.releaseGate()
        try await waitUntil { calls.count == 1 }

        // 用户点重试 / 自动换源失败后再试：同一个 request 对象，id 不变。
        controller.open(request: request)
        try await waitUntil { engine.openCalls >= 2 }
        engine.releaseGate()
        try await waitUntil { calls.count == 2 }

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls.map(\.0)).count, 1, "同一个请求重试两次，回调里的 id 必须相同")
        XCTAssertEqual(calls.map(\.1), [.network, .network])
    }

    // MARK: - ③ 被顶替的旧请求失败必须静默（走 supersede 路由；不是 finishOpenFailure 的代次守卫）

    func testSupersededFailureDoesNotCallBack() async throws {
        let firstEngine = GatedFakeEngine()
        let secondEngine = GatedFakeEngine()
        installEngines([firstEngine, secondEngine])
        let controller = PlaybackController()

        var calls: [(PlaybackRequest.ID, PlaybackOpenErrorKind)] = []
        controller.onOpenFailure = { calls.append(($0, $1)) }

        let superseded = PlaybackRequest(title: "A", uri: "file:///tmp/a.mp4")
        let current = PlaybackRequest(title: "B", uri: "file:///tmp/b.mp4")

        // A 在飞时被 B 顶替：A 的代次已经过期。
        controller.open(request: superseded)
        try await waitUntil { firstEngine.openCalls > 0 }
        controller.open(request: current)
        try await waitUntil { secondEngine.openCalls > 0 }

        // 让 A 带着失败迟到（真实场景：弱网下的旧请求终于报错返回）。
        firstEngine.failOpen(networkFailure)
        firstEngine.releaseGate()

        // 给它足够的主队列 turn 去落地：它必须被代次守卫吃掉。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(
            calls.isEmpty,
            "被顶替的旧请求失败不许回调：否则 App 会拿一条已经离开的请求去做换源决策"
        )

        // 收尾：放掉 B，避免后台 open 挂在闸门上污染后续用例。
        secondEngine.releaseGate()
    }
}
