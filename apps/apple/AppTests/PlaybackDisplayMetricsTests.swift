@testable import OcPlayer
import XCTest

/// 显示器 EDR headroom 的净化规则：内核 capi 只接受 1.0…10000，
/// 屏幕读数缺失/异常统一兜底 SDR（1.0）——绝不把 0 或负值喂给内核。
final class PlaybackDisplayMetricsTests: XCTestCase {
    func testSanitizedClampsToKernelAcceptedRange() {
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(8.0), 8.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(10_000), 10_000, accuracy: 0.0001)
        // 超上界按内核边界钳制（capi 同口径）。
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(20_000), 10_000, accuracy: 0.0001)
    }

    func testSanitizedFallsBackToSDR() {
        // XDR 之下不到 HDR 线、读数异常、NaN：一律回落 SDR 基准。
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(1.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(-3), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(.nan), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackDisplayMetrics.sanitized(.infinity), 1.0, accuracy: 0.0001)
    }
}
