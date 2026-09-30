import XCTest
@testable import ErikaKit

/// `PositionPublishGate` 的纯逻辑测试。
///
/// **刻意不建 `ErikaEngine`**：这个套件在无 GPU 的机器上（CI runner）也必须能跑，
/// 而创建 presenter 需要 Metal。闸门是纯值逻辑，单独测正合适。
final class PositionPublishGateTests: XCTestCase {

    private let start = ContinuousClock().now

    func testFirstCallAlwaysPublishes() {
        var gate = PositionPublishGate(interval: .milliseconds(100))
        XCTAssertTrue(gate.shouldPublish(now: start), "首次必须发布，否则位置一直不动")
    }

    func testDropsValuesInsideTheInterval() {
        var gate = PositionPublishGate(interval: .milliseconds(100))
        _ = gate.shouldPublish(now: start)

        // 间隔内的（模拟 60–120Hz 的逐帧位置）一律丢弃。
        for offset in [10, 20, 40, 60, 99] {
            XCTAssertFalse(
                gate.shouldPublish(now: start.advanced(by: .milliseconds(offset))),
                "间隔内不该发布：+\(offset)ms")
        }
    }

    func testPublishesAgainOnceTheIntervalElapsed() {
        var gate = PositionPublishGate(interval: .milliseconds(100))
        _ = gate.shouldPublish(now: start)

        XCTAssertTrue(
            gate.shouldPublish(now: start.advanced(by: .milliseconds(100))),
            "整好到点就要发布")
        XCTAssertFalse(gate.shouldPublish(now: start.advanced(by: .milliseconds(180))))
        XCTAssertTrue(gate.shouldPublish(now: start.advanced(by: .milliseconds(200))))
    }

    /// 120Hz 下跑 1 秒：发布次数应落在 10 次左右，而不是 120 次。
    /// 这条是修复的直接量化：事件流缓冲不再被逐帧位置灌满。
    func testKeepsRoughly10HzUnderFrameRateInput() {
        var gate = PositionPublishGate(interval: .milliseconds(100))
        var published = 0
        // 120 帧 = 1 秒 @120Hz。
        for frame in 0..<120 {
            let point = start.advanced(by: .milliseconds(Int((Double(frame) / 120.0 * 1000).rounded())))
            if gate.shouldPublish(now: point) { published += 1 }
        }
        XCTAssertEqual(published, 10, "1 秒 120 帧应压成 10 次发布，实际 \(published)")
    }

    /// 闸门只影响 position。控制事件的即时性由调用点保证——这里钉住「闸门本身
    /// 不区分事件类型」这个前提，避免有人误以为它会拦控制事件。
    func testGateIsIgnorantOfEventKindByDesign() {
        var gate = PositionPublishGate(interval: .seconds(10))
        XCTAssertTrue(gate.shouldPublish(now: start))
        // 闸门只看时间。ErikaEngine 的循环里只对 .positionChanged 调它。
        XCTAssertFalse(gate.shouldPublish(now: start.advanced(by: .seconds(5))))
    }
}
