import XCTest
@testable import PlaybackKit

/// `PlaybackEngine` 协议本身的契约：默认实现要正确，而且**新适配器不用写弹幕代码**。
final class PlaybackEngineContractTests: XCTestCase {

    func testDebugStatsLineKeepsAStableColumnLayout() {
        let engine = FakePlaybackEngine()
        engine.setStats(PlaybackStats(
            decodedVideoFrames: 120,
            renderedVideoFrames: 118,
            hardwareVideoFrames: 120,
            softwareVideoFrames: 0,
            zeroCopyVideoFrames: 117,
            pushedAudioFrames: 300,
            renderFailures: 1,
            audioFailures: 2
        ))
        XCTAssertEqual(
            engine.debugStatsLine(),
            "解码 120 · 渲染 118 · 硬解 120 · 软解 0 · 零拷贝 117 · 音频 300 · 渲染失败 1 · 音频失败 2"
        )
    }

    /// 首帧判据：内核报 ready 不等于屏幕上有东西，必须真的渲染过一帧。
    func testHasRenderedFirstFrameNeedsAnActualFrame() {
        let engine = FakePlaybackEngine()
        XCTAssertFalse(engine.hasRenderedFirstFrame)

        engine.setStats(PlaybackStats(decodedVideoFrames: 5, renderedVideoFrames: 0))
        XCTAssertFalse(engine.hasRenderedFirstFrame, "解码了但没渲染，loading 不能撤")

        engine.setStats(PlaybackStats(decodedVideoFrames: 5, renderedVideoFrames: 1))
        XCTAssertTrue(engine.hasRenderedFirstFrame)
    }

    /// 不支持内核弹幕的引擎：整组弹幕调用都安静地什么都不做，**不抛错**。
    /// overlay 路线下 `PlaybackController` 也会顺手调 `clearDanmaku()`，
    /// 那条路径上抛错只会制造噪音。
    func testKernelDanmakuDefaultsAreSilentNoOps() throws {
        let engine = FakePlaybackEngine()
        XCTAssertFalse(engine.supportsKernelDanmaku)
        XCTAssertFalse(FakePlaybackEngine.supportsKernelDanmaku)

        XCTAssertNoThrow(try engine.clearDanmaku())
        XCTAssertNoThrow(try engine.setDanmakuEnabled(true))
        XCTAssertNoThrow(try engine.setDanmakuGlobalOffset(.seconds(3)))
        XCTAssertNoThrow(try engine.setDanmakuConfig(DanmakuConfig()))
        XCTAssertEqual(try engine.addDanmakuTrack(json: "{}", name: "x", offset: .zero), 0)
        XCTAssertEqual(try engine.danmakuTracks().count, 0)
        XCTAssertEqual(try engine.danmakuConfig(), DanmakuConfig())
    }

    func testDescriptorIsReachableFromInstance() {
        let engine = FakePlaybackEngine()
        XCTAssertEqual(engine.descriptor.id, "fake")
        XCTAssertEqual(engine.descriptor, FakePlaybackEngine.descriptor)
    }

    func testPlaybackSourceFromFileURLUsesPath() {
        let source = PlaybackSource(fileURL: URL(fileURLWithPath: "/tmp/a b.mkv"))
        XCTAssertEqual(source.uri, "/tmp/a b.mkv")
        XCTAssertTrue(source.headers.isEmpty)
    }

    func testDurationMicrosecondsTruncates() {
        XCTAssertEqual(Duration.seconds(2).microseconds, 2_000_000)
        XCTAssertEqual(Duration.milliseconds(1500).microseconds, 1_500_000)
        XCTAssertEqual(Duration.nanoseconds(1_999).microseconds, 1)
    }
}
