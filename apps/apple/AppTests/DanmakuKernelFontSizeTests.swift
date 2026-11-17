import XCTest
@testable import OcPlayer

/// 内核弹幕字号映射：应用层偏好是 pt（基准 22pt），内核 `font_size` 是逻辑 px
/// （liberika v0.3.0 默认 30）。映射按比例走，100% = 内核默认值原样下发。
final class DanmakuKernelFontSizeTests: XCTestCase {

    /// 比例线性：100% → 30（等于内核默认，视觉零变化），200% → 60，50% → 15。
    func testKernelFontSizeMapsPreferenceScale() {
        XCTAssertEqual(PlaybackController.kernelFontSize(forScale: 1.0), 30, accuracy: 0.001)
        XCTAssertEqual(PlaybackController.kernelFontSize(forScale: 2.0), 60, accuracy: 0.001)
        XCTAssertEqual(PlaybackController.kernelFontSize(forScale: 0.5), 15, accuracy: 0.001)
    }

    /// 异常比例夹到 ≥1（与内核 `sanitized()` 的 `.max(1.0)` 一致），不产生 0/负字号。
    func testKernelFontSizeClampsToPositive() {
        XCTAssertEqual(PlaybackController.kernelFontSize(forScale: 0), 1, accuracy: 0.001)
        XCTAssertEqual(PlaybackController.kernelFontSize(forScale: -3), 1, accuracy: 0.001)
    }
}