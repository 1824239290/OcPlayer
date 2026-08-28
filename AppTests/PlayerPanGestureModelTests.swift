import XCTest
@testable import OcPlayer

/// iOS 画面手势的纯逻辑（分类与映射），不碰 UIKit。
final class PlayerPanGestureModelTests: XCTestCase {

    // MARK: - 分类

    func testHorizontalDominantClassifiesAsSeek() {
        let mode = PlayerPanGestureModel.mode(
            translation: CGSize(width: 30, height: 4),
            startX: 100,
            width: 400
        )
        XCTAssertEqual(mode, .seek)
    }

    func testVerticalOnLeftHalfClassifiesAsBrightness() {
        let mode = PlayerPanGestureModel.mode(
            translation: CGSize(width: 4, height: 30),
            startX: 100,
            width: 400
        )
        XCTAssertEqual(mode, .brightness)
    }

    func testVerticalOnRightHalfClassifiesAsVolume() {
        let mode = PlayerPanGestureModel.mode(
            translation: CGSize(width: 4, height: 30),
            startX: 300,
            width: 400
        )
        XCTAssertEqual(mode, .volume)
    }

    func testInvalidWidthReturnsNil() {
        let mode = PlayerPanGestureModel.mode(
            translation: CGSize(width: 30, height: 30),
            startX: 0,
            width: 0
        )
        XCTAssertNil(mode)
    }

    // MARK: - 横滑 seek

    func testSeekTargetMapsQuarterDurationPerFullSwipe() {
        // 满屏宽 = 时长的 1/4：400pt 宽拖 100pt（1/4 屏）= 1/16 时长。
        let target = PlayerPanGestureModel.seekTarget(
            startSeconds: 60,
            translation: 100,
            width: 400,
            duration: 1_200
        )
        XCTAssertEqual(target, 60 + 1_200 / 16, accuracy: 0.001)
    }

    func testSeekTargetUsesSixtySecondFloorForShortVideos() {
        // 短视频（< 240s）满屏宽保底 60s，避免拖满屏也挪不了几秒。
        let target = PlayerPanGestureModel.seekTarget(
            startSeconds: 0,
            translation: 200,
            width: 400,
            duration: 120
        )
        XCTAssertEqual(target, 30, accuracy: 0.001)
    }

    func testSeekTargetClampsToDuration() {
        let target = PlayerPanGestureModel.seekTarget(
            startSeconds: 1_100,
            translation: 1_000,
            width: 400,
            duration: 1_200
        )
        XCTAssertEqual(target, 1_200, accuracy: 0.001)
    }

    func testSeekTargetClampsToZeroWhenDurationMissing() {
        let target = PlayerPanGestureModel.seekTarget(
            startSeconds: 10,
            translation: -50,
            width: 400,
            duration: 0
        )
        XCTAssertEqual(target, 10, accuracy: 0.001, "无时长时不映射，保持起点")
    }

    // MARK: - 纵滑亮度 / 音量

    func testVerticalTargetFullSwipeCoversWholeRange() {
        let up = PlayerPanGestureModel.verticalTarget(start: 0.5, translation: -300, extent: 600)
        XCTAssertEqual(up, 1.0, accuracy: 0.001, "上滑满屏 = 拉满")

        let down = PlayerPanGestureModel.verticalTarget(start: 0.5, translation: 300, extent: 600)
        XCTAssertEqual(down, 0.0, accuracy: 0.001, "下滑满屏 = 归零")
    }

    func testVerticalTargetClampsOutOfRangeStart() {
        XCTAssertEqual(
            PlayerPanGestureModel.verticalTarget(start: 1.2, translation: 100, extent: 600),
            1.0, accuracy: 0.001
        )
    }

    // MARK: - 比例换算

    func testFractionClamps() {
        XCTAssertEqual(PlayerPanGestureModel.fraction(seconds: 30, duration: 120), 0.25, accuracy: 0.001)
        XCTAssertEqual(PlayerPanGestureModel.fraction(seconds: -5, duration: 120), 0, accuracy: 0.001)
        XCTAssertEqual(PlayerPanGestureModel.fraction(seconds: 999, duration: 120), 1, accuracy: 0.001)
        XCTAssertEqual(PlayerPanGestureModel.fraction(seconds: 10, duration: 0), 0, accuracy: 0.001)
    }
}
