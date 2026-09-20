@testable import OcPlayer
import XCTest

/// 详情页「媒体信息」区块的格式化：服务端元数据 → 人读文本。
final class MediaInfoLabelTests: XCTestCase {

    func testBitrate() {
        XCTAssertEqual(MediaInfoLabel.bitrate(24_500_000), "24.5 Mbps")
        XCTAssertEqual(MediaInfoLabel.bitrate(1_000_000), "1.0 Mbps")
        XCTAssertEqual(MediaInfoLabel.bitrate(800_000), "800 kbps")
        XCTAssertEqual(MediaInfoLabel.bitrate(192_000), "192 kbps")
        // 无效值一律不显示，而不是显示 "0 kbps"。
        XCTAssertNil(MediaInfoLabel.bitrate(nil))
        XCTAssertNil(MediaInfoLabel.bitrate(0))
        XCTAssertNil(MediaInfoLabel.bitrate(-1))
    }

    func testSize() {
        XCTAssertEqual(MediaInfoLabel.size(12_345_678_900), "12.35 GB")
        XCTAssertEqual(MediaInfoLabel.size(1_073_741_824), "1.07 GB")
        XCTAssertNil(MediaInfoLabel.size(nil))
        XCTAssertNil(MediaInfoLabel.size(0))
    }

    func testFrameRate() {
        XCTAssertEqual(MediaInfoLabel.frameRate(23.976), "23.976 fps")
        XCTAssertEqual(MediaInfoLabel.frameRate(25), "25 fps")
        XCTAssertEqual(MediaInfoLabel.frameRate(29.97), "29.970 fps")
        XCTAssertNil(MediaInfoLabel.frameRate(nil))
        XCTAssertNil(MediaInfoLabel.frameRate(0))
    }

    func testResolutionUsesSameAspectAsPlayerHUD() {
        XCTAssertEqual(MediaInfoLabel.resolution(width: 3840, height: 2160), "3840×2160 · 16:9")
        XCTAssertEqual(MediaInfoLabel.resolution(width: 1920, height: 1080), "1920×1080 · 16:9")
        // 约分不出来时退小数，与 PlayerVideoColorLabel.aspect 同口径。
        XCTAssertEqual(MediaInfoLabel.resolution(width: 854, height: 480), "854×480 · 1.78:1")
        XCTAssertNil(MediaInfoLabel.resolution(width: nil, height: 1080))
        XCTAssertNil(MediaInfoLabel.resolution(width: 0, height: 0))
    }

    func testChannels() {
        XCTAssertEqual(MediaInfoLabel.channels(count: 8, layout: "7.1"), "7.1 (8ch)")
        XCTAssertEqual(MediaInfoLabel.channels(count: 6, layout: "5.1"), "5.1 (6ch)")
        // 只有布局名（老服务端不给声道数）
        XCTAssertEqual(MediaInfoLabel.channels(count: nil, layout: "stereo"), "stereo")
        // 只有声道数
        XCTAssertEqual(MediaInfoLabel.channels(count: 2, layout: nil), "2ch")
        // 布局是空白串按没有处理
        XCTAssertEqual(MediaInfoLabel.channels(count: 2, layout: "  "), "2ch")
        XCTAssertNil(MediaInfoLabel.channels(count: nil, layout: nil))
    }

    func testSampleRate() {
        XCTAssertEqual(MediaInfoLabel.sampleRate(48_000), "48 kHz")
        XCTAssertEqual(MediaInfoLabel.sampleRate(44_100), "44.1 kHz")
        XCTAssertNil(MediaInfoLabel.sampleRate(nil))
        XCTAssertNil(MediaInfoLabel.sampleRate(0))
    }

    /// 动态范围：DOVI 全变体归「杜比视界」，与 PlaybackSessionContext.isDolbyVision 同口径。
    func testDynamicRange() {
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "DOVI"), "杜比视界")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "DOVIWithEL"), "杜比视界")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "doviwithhdr10"), "杜比视界")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "DOVIWithHLG"), "杜比视界")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "DOVIWithSDR"), "杜比视界")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "HDR10"), "HDR10")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "HDR10Plus"), "HDR10+")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "HLG"), "HLG")
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "SDR"), "SDR")
        // Unknown / 空 / nil 不显示，别在行里留一个「未知」占位。
        XCTAssertNil(MediaInfoLabel.dynamicRange(videoRangeType: "Unknown"))
        XCTAssertNil(MediaInfoLabel.dynamicRange(videoRangeType: ""))
        XCTAssertNil(MediaInfoLabel.dynamicRange(videoRangeType: "   "))
        XCTAssertNil(MediaInfoLabel.dynamicRange(videoRangeType: nil))
        // 认不出的值回原始串，不猜。
        XCTAssertEqual(MediaInfoLabel.dynamicRange(videoRangeType: "HDR12"), "HDR12")
    }

    func testColorPrimariesAndTransfer() {
        XCTAssertEqual(MediaInfoLabel.colorPrimaries("bt2020"), "BT.2020")
        XCTAssertEqual(MediaInfoLabel.colorPrimaries("bt2020nc"), "BT.2020")
        XCTAssertEqual(MediaInfoLabel.colorPrimaries("bt709"), "BT.709")
        XCTAssertEqual(MediaInfoLabel.colorPrimaries("smpte431"), "DCI-P3")
        XCTAssertNil(MediaInfoLabel.colorPrimaries(nil))
        XCTAssertNil(MediaInfoLabel.colorPrimaries("  "))
        // 认不出的原样透传（保留原始大小写）
        XCTAssertEqual(MediaInfoLabel.colorPrimaries("WeirdSpace"), "WeirdSpace")

        XCTAssertEqual(MediaInfoLabel.colorTransfer("smpte2084"), "PQ")
        XCTAssertEqual(MediaInfoLabel.colorTransfer("arib-std-b67"), "HLG")
        XCTAssertEqual(MediaInfoLabel.colorTransfer("bt709"), "BT.709")
        XCTAssertNil(MediaInfoLabel.colorTransfer(nil))
        XCTAssertEqual(MediaInfoLabel.colorTransfer("bt2020-10"), "BT.2020")
    }

    func testCodecAndContainerUppercase() {
        XCTAssertEqual(MediaInfoLabel.codec("hevc"), "HEVC")
        XCTAssertEqual(MediaInfoLabel.codec("h264"), "H264")
        XCTAssertEqual(MediaInfoLabel.container("mkv"), "MKV")
        XCTAssertEqual(MediaInfoLabel.container("mp4"), "MP4")
        XCTAssertNil(MediaInfoLabel.codec(nil))
        XCTAssertNil(MediaInfoLabel.codec("  "))
        XCTAssertNil(MediaInfoLabel.container(nil))
    }

    func testLanguage() {
        // 认得出的语言代码给本地化名（不锁死具体语言包，只断言非空且不是原代码）。
        let zh = MediaInfoLabel.language("zh")
        XCTAssertNotNil(zh)
        XCTAssertNotEqual(zh, "zh")
        // 认不出的回原串，不显示空。
        XCTAssertEqual(MediaInfoLabel.language("qqq"), "qqq")
        XCTAssertNil(MediaInfoLabel.language(nil))
        XCTAssertNil(MediaInfoLabel.language("   "))
    }

    func testDuration() {
        XCTAssertEqual(MediaInfoLabel.duration(1450), "24 分钟")
        XCTAssertEqual(MediaInfoLabel.duration(5400), "1 小时 30 分")
        XCTAssertNil(MediaInfoLabel.duration(nil))
        XCTAssertNil(MediaInfoLabel.duration(0))
    }
}
