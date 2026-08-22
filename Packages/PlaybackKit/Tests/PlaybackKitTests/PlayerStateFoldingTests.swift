import XCTest
@testable import PlaybackKit

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
