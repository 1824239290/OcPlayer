import JellyfinKit
@testable import OcPlayer
import XCTest

/// 管理服务器页里「地址行右侧状态标记」的显示优先级。
///
/// 这格是典型的静默出错点：早先「使用中 / 已固定」永远盖掉延迟，用户点完「重新检测」
/// 想看的偏偏就是那条数字，界面上却看不到；而这类细节没人会写回归，所以在这里钉住。
final class ServerAddressStatusTests: XCTestCase {

    private func status(
        isPinned: Bool = false,
        isActive: Bool = false,
        latency: Int?,
        probed: Bool = true,
        reveal: Bool
    ) -> ServerAddressStatus {
        ServerAddressStatus.resolve(
            isPinned: isPinned, isActive: isActive,
            latencyMilliseconds: latency, probed: probed, revealLatency: reveal)
    }

    /// 平时：使用中 / 已固定只显示状态，不显示数字。
    func testIdleHidesLatencyForActiveAndPinned() {
        XCTAssertEqual(status(isActive: true, latency: 8, reveal: false).text, "使用中")
        XCTAssertEqual(status(isPinned: true, latency: 8, reveal: false).text, "已固定")
    }

    /// 刚检测完：这两条要把数字带出来 —— 这正是补这个功能的原因。
    func testRevealShowsLatencyForActiveAndPinned() {
        XCTAssertEqual(status(isActive: true, latency: 8, reveal: true).text, "使用中 · 8 ms")
        XCTAssertEqual(status(isPinned: true, latency: 12, reveal: true).text, "已固定 · 12 ms")
    }

    /// 其余地址本来就常显延迟，与是否刚检测无关（倍数不该出现「·」）。
    func testNonActiveRowsAlwaysShowLatency() {
        XCTAssertEqual(status(latency: 45, reveal: false).text, "45 ms")
        XCTAssertEqual(status(latency: 45, reveal: true).text, "45 ms")
    }

    /// 使用中那条这轮没探到（例如固定了一条已经不通的地址）：
    /// 仍然显示状态标记，不能因为缺数字就退化成「不可达」。
    func testActiveWithoutLatencyKeepsStateLabel() {
        XCTAssertEqual(status(isActive: true, latency: nil, reveal: true).text, "使用中")
        XCTAssertEqual(status(isPinned: true, latency: nil, reveal: true).text, "已固定")
    }

    /// 探过但没结果 = 不可达；没探过 = 什么都不显示（没结论不等于连不上）。
    func testUnreachableVersusNotProbed() {
        XCTAssertEqual(status(latency: nil, probed: true, reveal: false).text, "不可达")
        XCTAssertNil(status(latency: nil, probed: false, reveal: false).text)
        XCTAssertNil(status(latency: nil, probed: false, reveal: true).text)
    }

    /// 「已固定」优先于「使用中」：固定项就是当前生效地址，两个标记不该同时出现。
    func testPinnedWinsOverActive() {
        XCTAssertEqual(status(isPinned: true, isActive: true, latency: 5, reveal: false).text, "已固定")
    }

    /// 亚毫秒延迟四舍五入到 0 ms 而不是负数 / 异常值（`Int(0.0004 * 1000) = 0`）。
    func testSubMillisecondLatencyRoundsToZero() {
        XCTAssertEqual(status(latency: 0, reveal: false).text, "0 ms")
    }
}
