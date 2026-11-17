import XCTest
@testable import OcPlayer

/// overlay 采样时钟的 seek 跳变检测。
///
/// 核心回归：原实现 tick 比较原始媒体时间、resync 写入减偏移的生效时间，两个时基
/// 混用——偏移非零时 resync 后下一拍算出 delta ≈ 偏移量，越过阈值误判 seek →
/// 清屏死循环、弹幕整集不出现。本检测器只认原始媒体时间，这组用例把它钉住。
final class DanmakuSeekDetectorTests: XCTestCase {

    private let jump = 2.0

    /// bug 本体：对齐发生在偏移 3s 的时基上（旧实现写入 effective），
    /// 下一拍原始时间只前进 1/60s，必须判连续而非 seek。
    func testAlignThenNextTickIsContinuousDespiteOffset() {
        var detector = DanmakuSeekDetector()
        // 旧实现：lastMediaSample = effective(raw) = 100 − 3 = 97
        detector.align(rawSeconds: 100)
        // 旧实现：delta = 100.016 − 97 = 3.016 > 2.0 → 误判 seek（死循环起点）
        XCTAssertEqual(
            detector.evaluate(rawSeconds: 100.016, jumpSeconds: jump),
            .continuous
        )
    }

    /// 对齐后连续多拍都不得判 seek（死循环会在这里持续清屏）。
    func testAlignThenSeveralTicksStayContinuous() {
        var detector = DanmakuSeekDetector()
        detector.align(rawSeconds: 100)
        for step in 1...5 {
            XCTAssertEqual(
                detector.evaluate(rawSeconds: 100 + Double(step) / 60.0, jumpSeconds: jump),
                .continuous,
                "第 \(step) 拍不应判 seek"
            )
        }
    }

    /// 首拍没有比较基准。
    func testFirstSampleWithoutBaseline() {
        var detector = DanmakuSeekDetector()
        XCTAssertEqual(detector.evaluate(rawSeconds: 12.5, jumpSeconds: jump), .firstSample)
        // 首拍已建立基准：紧接着的采样是连续。
        XCTAssertEqual(detector.evaluate(rawSeconds: 12.516, jumpSeconds: jump), .continuous)
    }

    /// 前向跳变超过阈值仍要判 seek（别把 seek 检测修坏）。
    func testForwardJumpDetected() {
        var detector = DanmakuSeekDetector()
        detector.align(rawSeconds: 100)
        XCTAssertEqual(detector.evaluate(rawSeconds: 105, jumpSeconds: jump), .jumped)
    }

    /// 后向跳变（往回 seek）超过 0.5s 判 seek。
    func testBackwardJumpDetected() {
        var detector = DanmakuSeekDetector()
        detector.align(rawSeconds: 100)
        XCTAssertEqual(detector.evaluate(rawSeconds: 99, jumpSeconds: jump), .jumped)
    }

    /// jumped 后基准已更新到新采样点：下一拍不会再次判 jumped。
    func testBaselineAdvancesAfterJump() {
        var detector = DanmakuSeekDetector()
        detector.align(rawSeconds: 100)
        XCTAssertEqual(detector.evaluate(rawSeconds: 105, jumpSeconds: jump), .jumped)
        XCTAssertEqual(detector.evaluate(rawSeconds: 105.016, jumpSeconds: jump), .continuous)
    }

    /// reset 后回到「无基准」：下一次采样是 firstSample。
    func testResetClearsBaseline() {
        var detector = DanmakuSeekDetector()
        detector.align(rawSeconds: 100)
        detector.reset()
        XCTAssertEqual(detector.evaluate(rawSeconds: 200, jumpSeconds: jump), .firstSample)
    }
}
