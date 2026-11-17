import XCTest
@testable import OcPlayer

/// 右箭头长按 2x 的控制器状态机（引擎为 nil，断言只看 rate 状态）。
final class HoldFastForwardTests: XCTestCase {

    @MainActor
    func testHoldEngagesAt2xAndRestoresPreviousRate() {
        let controller = PlaybackController()
        controller.applyRate(1.5)

        controller.beginHoldFastForward()
        XCTAssertTrue(controller.isHoldFastForwarding)
        XCTAssertEqual(controller.rate, 2.0, accuracy: 0.001)

        controller.endHoldFastForward()
        XCTAssertFalse(controller.isHoldFastForwarding)
        XCTAssertEqual(controller.rate, 1.5, accuracy: 0.001, "恢复到长按前的速度，不是写死 1x")
    }

    @MainActor
    func testBeginIsIdempotentUnderAutorepeat() {
        let controller = PlaybackController()
        controller.applyRate(1.0)

        controller.beginHoldFastForward()
        // autorepeat 每帧都会调 begin：原速锚点必须是第一次那份，不能被 2x 覆盖。
        controller.beginHoldFastForward()
        controller.beginHoldFastForward()
        XCTAssertEqual(controller.rate, 2.0, accuracy: 0.001)

        controller.endHoldFastForward()
        XCTAssertEqual(controller.rate, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testEndWithoutBeginIsNoop() {
        let controller = PlaybackController()
        controller.applyRate(0.75)
        controller.endHoldFastForward()
        XCTAssertEqual(controller.rate, 0.75, accuracy: 0.001)
        XCTAssertFalse(controller.isHoldFastForwarding)
    }
}
