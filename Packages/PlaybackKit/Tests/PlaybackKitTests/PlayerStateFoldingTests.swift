import XCTest
import Observation
@testable import PlaybackKit

/// `withObservationTracking` 的 onChange 是 @Sendable，测试计数用引用盒包一层。
private final class RepublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    func bump() {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
    }
}

/// `PlayerState` 的折叠语义。以前只能靠真内核间接验证，现在用替身直接钉住。
@MainActor
final class PlayerStateFoldingTests: XCTestCase {

    /// 等一个条件成立（事件跨 Task 投递，不能同步断言）。
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("超时未满足：\(description)")
    }

    func testStateAndDurationFoldFromEvents() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.stateChanged(.playing))
        engine.emit(.durationChanged(.seconds(120)))
        try await waitUntil("state/duration 到位") {
            state.state == .playing && state.duration == .seconds(120)
        }
    }

    /// 标签只在**整秒**变化时发布：亚秒抖动不该把整棵 HUD 子树拖成逐帧重排。
    func testDisplayPositionPublishesOnWholeSecondsOnly() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.durationChanged(.seconds(100)))
        try await waitUntil("duration 到位") { state.duration == .seconds(100) }

        engine.emit(.positionChanged(.milliseconds(1_200)))
        try await waitUntil("跨到第 1 秒") { state.displayPosition == .milliseconds(1_200) }

        // 同一秒内再动：position 跟进，displayPosition 不动。
        engine.emit(.positionChanged(.milliseconds(1_800)))
        try await waitUntil("position 跟进") { state.position == .milliseconds(1_800) }
        XCTAssertEqual(state.displayPosition, .milliseconds(1_200), "同一整秒内标签不该重新发布")
    }

    /// duration 是 progress 的分母，晚到时必须强制重算——否则进度条停在 0。
    func testLateDurationForcesProgressRecompute() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.positionChanged(.seconds(30)))
        try await waitUntil("position 到位") { state.position == .seconds(30) }
        XCTAssertEqual(state.progress, 0, "还没有 duration，比例只能是 0")

        engine.emit(.durationChanged(.seconds(60)))
        try await waitUntil("duration 到达后立刻重算比例") { state.progress == 0.5 }
    }

    func testErrorEventSetsErrorStateAndMessage() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.failed(code: 3, message: "HTTP 401"))
        try await waitUntil("错误落到 state") {
            state.state == .error && state.lastError == "HTTP 401"
        }
        state.clearError()
        XCTAssertNil(state.lastError)
    }

    /// 内核没给文案时也要有个能显示的东西，别给 UI 一个 nil。
    func testErrorWithoutMessageFallsBackToCode() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.failed(code: 4, message: nil))
        try await waitUntil("回退文案") { state.lastError == "内核错误 code=4" }
    }

    /// 错误风暴里同一条 `.failed` 逐帧重发：lastError 同值不该再次发布
    ///（否则 HUD / 进度订阅被无谓连坐失效）。
    func testSameLastErrorDoesNotRePublish() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.failed(code: 3, message: "HTTP 401"))
        try await waitUntil("错误落到位") { state.lastError == "HTTP 401" }

        let counter = RepublishCounter()
        // 单次注册全程追踪：同值 emit 若被抑制，tracking 不会触发也保持存活；
        // 异值 emit 触发恰好一次。同值没被抑制的话这里会先 +1，最终断言不符。
        withObservationTracking {
            _ = state.lastError
        } onChange: {
            counter.bump()
        }
        engine.emit(.failed(code: 3, message: "HTTP 401"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(counter.count, 0, "同值 lastError 不该发布")

        engine.emit(.failed(code: 5, message: "别的错"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(counter.count, 1, "异值 lastError 应恰好发布一次")
        XCTAssertEqual(state.lastError, "别的错")
    }

    /// 换引擎后旧消费者不能再改状态：取消本身不够（主 actor 上可能已经排了一条事件），
    /// 靠 generation 兜住。
    func testOnlyLatestConsumerMutatesState() async throws {
        let oldEngine = FakePlaybackEngine()
        let newEngine = FakePlaybackEngine()
        let state = PlayerState()

        let oldTask = state.start(consuming: oldEngine)
        let newTask = state.start(consuming: newEngine)
        defer {
            oldTask.cancel()
            newTask.cancel()
        }

        newEngine.emit(.durationChanged(.seconds(60)))
        try await waitUntil("新引擎的 duration 生效") { state.duration == .seconds(60) }

        oldEngine.emit(.durationChanged(.seconds(999)))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.duration, .seconds(60), "旧引擎的事件不许改新源的时间轴")
    }

    func testTracksChangedRefreshesAudioAndSubtitleLists() async throws {
        let engine = FakePlaybackEngine()
        engine.setTracks([
            .stub(id: 0, kind: .video),
            .stub(id: 1, kind: .audio, selected: true, language: "jpn", channels: 2),
            .stub(id: 2, kind: .subtitle, language: "zho"),
            .stub(id: 3, kind: .subtitle, source: .external, title: "外挂"),
        ])
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await waitUntil("轨道列表重拉") {
            state.audioTracks.count == 1 && state.subtitleTracks.count == 2
        }
        XCTAssertEqual(state.audioTracks.first?.id, 1)
        XCTAssertEqual(state.subtitleTracks.map(\.id), [2, 3])
        XCTAssertEqual(state.trackCounts.subtitle, 2)
    }

    func testResetClearsMediaStateButNotSurface() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.surfaceAttached)
        engine.emit(.durationChanged(.seconds(60)))
        engine.emit(.positionChanged(.seconds(30)))
        try await waitUntil("先攒一点状态") { state.hasSurface && state.progress == 0.5 }

        state.reset()
        XCTAssertEqual(state.duration, .zero)
        XCTAssertEqual(state.position, .zero)
        XCTAssertEqual(state.progress, 0)
        XCTAssertTrue(state.hasSurface, "surface 归 surface：视图一直挂着，reset 不该动它")
    }

    // MARK: - 会话统计与播放事件（阶段4）

    /// 缓冲轮次要能数出来：issue #2（「三十秒闪一次」）就是缓冲周期在驱动 UI，此前零记录。
    func testBufferingTogglesFoldIntoSessionStats() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        XCTAssertEqual(state.sessionStats.bufferCount, 0)

        engine.emit(.bufferingChanged(true))
        try await waitUntil("进缓冲") { state.isBuffering }
        XCTAssertEqual(state.sessionStats.bufferCount, 1)

        engine.emit(.bufferingChanged(false))
        try await waitUntil("缓冲结束") { !state.isBuffering }
        XCTAssertEqual(state.sessionStats.bufferCount, 1, "一轮起止只算一次")
        XCTAssertGreaterThanOrEqual(state.sessionStats.bufferedSeconds, 0)

        engine.emit(.bufferingChanged(true))
        try await waitUntil("第二轮缓冲") { state.isBuffering }
        XCTAssertEqual(state.sessionStats.bufferCount, 2)
    }

    /// 同一条内核错误逐帧重发只计一次（与错误日志的去重口径一致）。
    func testDistinctErrorsAreCountedOnceEach() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.failed(code: 3, message: "HTTP 401"))
        try await waitUntil("第一条错误") { state.sessionStats.errorCount == 1 }
        engine.emit(.failed(code: 3, message: "HTTP 401"))   // 重发
        engine.emit(.failed(code: 7, message: "别的"))        // 新的
        try await waitUntil("第二条错误") { state.sessionStats.errorCount == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.sessionStats.errorCount, 2)
    }

    /// 会话汇总只出一次，且没开过源时不写噪音记录。
    func testFinishSessionIsSingleShot() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()

        XCTAssertNil(state.finishSession(reason: "user"), "还没开过源：不该产出 session.end")

        let task = state.start(consuming: engine)
        defer { task.cancel() }
        engine.emit(.bufferingChanged(true))
        try await waitUntil("进缓冲") { state.isBuffering }

        let first = state.finishSession(reason: "user")
        XCTAssertEqual(first?.bufferCount, 1, "汇总里要带上这轮缓冲")
        XCTAssertNil(state.finishSession(reason: "user"), "同一次会话只结一次账")
    }

    /// 宿主侧看门狗上报的卡死次数要进汇总。
    func testNoteStallFeedsSessionStats() {
        let state = PlayerState()
        state.noteStall()
        state.noteStall()
        XCTAssertEqual(state.sessionStats.stallCount, 2)
    }

    func testResetClearsSessionStats() async throws {
        let engine = FakePlaybackEngine()
        let state = PlayerState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.bufferingChanged(true))
        try await waitUntil("进缓冲") { state.sessionStats.bufferCount == 1 }

        state.reset()
        XCTAssertEqual(state.sessionStats, PlaybackSessionStats(), "reset 按源清零")
    }

    // MARK: - UI 缓冲态迟滞（issue #2「三十秒闪一次」）

    /// 迟滞参数压到毫秒级：跑的是真实计时路径，只是不等真机的 300ms/500ms。
    private func makeSustainedState(
        showDelay: Duration = .milliseconds(40),
        minVisible: Duration = .milliseconds(80)
    ) -> PlayerState {
        PlayerState(bufferingUIShowDelay: showDelay, bufferingUIMinVisible: minVisible)
    }

    /// 单帧饿数据（内核报一下又立刻收回）完全不惊动 UI；真值照记。
    func testShortBufferingBlipNeverReachesUI() async throws {
        let engine = FakePlaybackEngine()
        let state = makeSustainedState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.bufferingChanged(true))
        try await Task.sleep(for: .milliseconds(10))    // 远在上沿之内
        engine.emit(.bufferingChanged(false))
        try await Task.sleep(for: .milliseconds(150))   // 越过上沿 + 最短可见

        XCTAssertFalse(state.isBufferingSustained, "单帧饿数据不该让 UI 动（转圈/弹幕/HUD）")
        XCTAssertEqual(state.sessionStats.bufferCount, 1, "诊断记账不受迟滞影响")
    }

    /// 持续缓冲：等过上沿才置位；恢复后补足最短可见时长再收回。
    func testSustainedBufferingShowsAfterDelayAndHoldsMinVisible() async throws {
        let engine = FakePlaybackEngine()
        let state = makeSustainedState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.bufferingChanged(true))
        try await waitUntil("内核报缓冲已应用") { state.isBuffering }
        XCTAssertFalse(state.isBufferingSustained, "上沿之前不许置位")

        try await waitUntil("持续缓冲置位") { state.isBufferingSustained }

        engine.emit(.bufferingChanged(false))
        try await Task.sleep(for: .milliseconds(30))    // < 最短可见时长
        XCTAssertTrue(state.isBufferingSustained, "最短可见时长内不收回（否则是一帧闪）")

        try await waitUntil("到点收回") { !state.isBufferingSustained }
    }

    /// 收回之前又进缓冲：不收回、也不重新计上沿——不来回闪。
    func testReenterDuringMinVisibleDoesNotBlink() async throws {
        let engine = FakePlaybackEngine()
        let state = makeSustainedState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.bufferingChanged(true))
        try await waitUntil("持续缓冲置位") { state.isBufferingSustained }

        engine.emit(.bufferingChanged(false))
        try await Task.sleep(for: .milliseconds(20))
        engine.emit(.bufferingChanged(true))
        try await Task.sleep(for: .milliseconds(150))   // 越过本该收回的时刻

        XCTAssertTrue(state.isBufferingSustained, "期间再进缓冲：保持显示，不闪")
    }

    /// reset 取消在飞的计时：换源后不会被上一轮的迟滞事后改写。
    func testResetCancelsPendingBufferingTimers() async throws {
        let engine = FakePlaybackEngine()
        let state = makeSustainedState()
        let task = state.start(consuming: engine)
        defer { task.cancel() }

        engine.emit(.bufferingChanged(true))    // 事件异步落地：先等它应用，上沿计时这才在飞
        try await waitUntil("内核报缓冲已应用") { state.isBuffering }
        XCTAssertFalse(state.isBufferingSustained)
        state.reset()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(state.isBufferingSustained, "reset 后不该被在飞的计时置位")

        engine.emit(.bufferingChanged(true))
        try await waitUntil("重进缓冲置位") { state.isBufferingSustained }
        state.reset()
        XCTAssertFalse(state.isBufferingSustained)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(state.isBufferingSustained, "reset 后不该被在飞的收回计时改写")
    }

    func testDisplayTitleFallsBackToLanguageAndCodec() {
        let named = TrackInfo.stub(id: 1, kind: .audio, title: "导演评论")
        XCTAssertEqual(named.displayTitle, "导演评论")

        let unnamed = TrackInfo.stub(id: 2, kind: .audio, language: "jpn", codec: "aac", channels: 6)
        XCTAssertEqual(unnamed.displayTitle, "jpn · aac · 6ch")

        // 字幕轨不显示声道数。
        let subtitle = TrackInfo.stub(id: 3, kind: .subtitle, language: "zho", codec: "ass", channels: 2)
        XCTAssertEqual(subtitle.displayTitle, "zho · ass")
    }
}
