@testable import OcPlayer
import PlaybackKit
import XCTest

/// 播放信息面板的 AVCol 标签与宽高比格式化。
final class PlayerVideoColorLabelTests: XCTestCase {
    func testDynamicRange() {
        XCTAssertEqual(PlayerVideoColorLabel.dynamicRange(transfer: 16), "HDR (PQ)")
        XCTAssertEqual(PlayerVideoColorLabel.dynamicRange(transfer: 18), "HLG")
        // BT.709 / 未知传输函数都归 SDR。
        XCTAssertEqual(PlayerVideoColorLabel.dynamicRange(transfer: 1), "SDR")
        XCTAssertEqual(PlayerVideoColorLabel.dynamicRange(transfer: 99), "SDR")
    }

    func testDynamicRangeDolbyVision() {
        // 杜比源 + 输出端已知：映射 SDR 与 HDR 分开标注。
        XCTAssertEqual(
            PlayerVideoColorLabel.dynamicRange(transfer: 16, isDolbyVision: true, outputEncoding: .sdr),
            "杜比视界（映射 SDR）"
        )
        XCTAssertEqual(
            PlayerVideoColorLabel.dynamicRange(transfer: 16, isDolbyVision: true, outputEncoding: .appleEdr),
            "杜比视界（HDR）"
        )
        XCTAssertEqual(
            PlayerVideoColorLabel.dynamicRange(transfer: 16, isDolbyVision: true, outputEncoding: .hdr10Pq),
            "杜比视界（HDR）"
        )
        // 输出未知（打开中 / 内核没报）不猜输出端，只报杜比视界。
        XCTAssertEqual(
            PlayerVideoColorLabel.dynamicRange(transfer: 16, isDolbyVision: true, outputEncoding: .unknown),
            "杜比视界"
        )
        // 杜比标记不受源侧 transfer 影响：容器标错成 SDR TRC 也以杜比源为准。
        XCTAssertEqual(
            PlayerVideoColorLabel.dynamicRange(transfer: 1, isDolbyVision: true, outputEncoding: .sdr),
            "杜比视界（映射 SDR）"
        )
    }

    func testTransferLabels() {
        XCTAssertEqual(PlayerVideoColorLabel.transfer(1), "BT.1886")
        XCTAssertEqual(PlayerVideoColorLabel.transfer(4), "Gamma 2.2")
        XCTAssertEqual(PlayerVideoColorLabel.transfer(6), "BT.601")
        XCTAssertEqual(PlayerVideoColorLabel.transfer(13), "sRGB")
        XCTAssertEqual(PlayerVideoColorLabel.transfer(16), "PQ")
        XCTAssertEqual(PlayerVideoColorLabel.transfer(18), "HLG")
        // 认不出的码退回原始值，不猜。
        XCTAssertEqual(PlayerVideoColorLabel.transfer(23), "TRC 23")
    }

    func testPrimariesLabels() {
        XCTAssertEqual(PlayerVideoColorLabel.primaries(1), "BT.709")
        XCTAssertEqual(PlayerVideoColorLabel.primaries(6), "BT.601")
        XCTAssertEqual(PlayerVideoColorLabel.primaries(9), "BT.2020")
        XCTAssertEqual(PlayerVideoColorLabel.primaries(11), "DCI-P3")
        XCTAssertEqual(PlayerVideoColorLabel.primaries(12), "Display P3")
        XCTAssertEqual(PlayerVideoColorLabel.primaries(77), "原色 77")
    }

    func testAspectReducesToWholeRatio() {
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 1920, height: 1080), "16:9")
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 3840, height: 2160), "16:9")
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 720, height: 480), "3:2")
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 1080, height: 1920), "9:16")
    }

    func testAspectFallsBackToDecimalWhenWholeRatioTooLong() {
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 854, height: 480), "1.78:1")
    }

    func testAspectInvalidDimensions() {
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 0, height: 1080), "—")
        XCTAssertEqual(PlayerVideoColorLabel.aspect(width: 1920, height: 0), "—")
    }
}
