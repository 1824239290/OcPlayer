import XCTest
@testable import OcPlayer

/// 播放器键位映射（keyCode → 动作）。
final class PlayerKeyboardTests: XCTestCase {

    func testKnownKeysMapToActions() {
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 49), .togglePlayPause, "space")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 36), .togglePlayPause, "return")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 53), .closePlayer, "escape")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 123), .seekBackward, "left")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 38), .seekBackward, "j")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 124), .seekForward, "right")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 37), .seekForward, "l")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 125), .volumeDown, "down")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 126), .volumeUp, "up")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 46), .toggleMute, "m")
        XCTAssertEqual(PlayerKeyAction.action(keyCode: 3), .toggleFullscreen, "f")
    }

    func testUnknownKeysMapToNil() {
        XCTAssertNil(PlayerKeyAction.action(keyCode: 0))   // a
        XCTAssertNil(PlayerKeyAction.action(keyCode: 11))  // b
        XCTAssertNil(PlayerKeyAction.action(keyCode: 96))  // F5（功能键不做）
        XCTAssertNil(PlayerKeyAction.action(keyCode: 65535))
    }
}
