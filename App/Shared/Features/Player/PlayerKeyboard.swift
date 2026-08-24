import Foundation

/// 播放器键位映射（macOS 本地键盘监听用）。
///
/// 只映射**无修饰键**的裸键；Cmd/Ctrl/Option 组合一律留给系统。
/// 空格 / 回车同义，j/l 与左右方向键同义（对齐常见播放器习惯）。
enum PlayerKeyAction: Equatable {
    case togglePlayPause
    case closePlayer
    case seekBackward
    case seekForward
    case volumeDown
    case volumeUp
    case toggleMute
    case toggleFullscreen

    static func action(keyCode: UInt16) -> PlayerKeyAction? {
        switch keyCode {
        case 49, 36: .togglePlayPause   // space / return
        case 53: .closePlayer           // escape
        case 123, 38: .seekBackward     // ← / j
        case 124, 37: .seekForward      // → / l
        case 125: .volumeDown           // ↓
        case 126: .volumeUp             // ↑
        case 46: .toggleMute            // m
        case 3: .toggleFullscreen       // f
        default: nil
        }
    }
}
