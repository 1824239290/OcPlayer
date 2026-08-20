import AppKit

/// 播放时把窗口调成视频比例、退出播放时还原（仅 macOS，iOS 端不参与）。
///
/// 由 `PlayerScreen` 三个时机驱动：
/// - 出现：`saveOriginalIfNeeded()` 记住播放前的窗口（每次播放会话只记一次）
/// - 视频参数到达 / 变化：`fit(videoWidth:videoHeight:)` 贴比例
/// - 消失（关闭播放器）：`restore()` 回到播放前
///
/// 全屏（用户手动进的 macOS 全屏）不动窗口。尺寸策略：**比例对上就好**——
/// 一律保持窗口当前的高度、只把宽度调成 height × 视频比例（不放大到视频分辨率）；
/// 超出屏幕等比缩，窄到看不清（竖屏视频）才抬到最小宽并反推高度。顶边对齐、水平居中。
@MainActor
enum PlayerWindowFitter {

    private static var originalFrame: NSRect?

    private static func playerWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
    }

    private static func isFullscreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen)
    }

    static func saveOriginalIfNeeded() {
        guard originalFrame == nil,
              let window = playerWindow(),
              !isFullscreen(window)
        else { return }
        originalFrame = window.frame
    }

    static func fit(videoWidth: Int, videoHeight: Int) {
        guard videoWidth > 0, videoHeight > 0,
              let window = playerWindow(),
              !isFullscreen(window),
              window.frame.height > 0
        else { return }
        let aspect = CGFloat(videoWidth) / CGFloat(videoHeight)
        // 窗口比例已经差不多（±2%）就不动，避免重复播放同规格视频时抖
        guard abs(window.frame.width / window.frame.height - aspect) / aspect > 0.02 else { return }
        saveOriginalIfNeeded()
        let screen = window.screen?.visibleFrame ?? window.frame
        let target = fittedSize(aspect: aspect, current: window.frame.size, within: screen)
        // 计算在当前 runloop 完成（和 onChange 同步），
        // setFrame 推迟到下一轮，避开 SwiftUI update cycle 中 NSMoveHelper 的冲突。
        // 用 animate:true 让窗口贴合带有系统默认弹性动画（~0.18s），避免「一闪而大」。
        var newFrame = NSRect(
            x: window.frame.midX - target.width / 2,
            y: window.frame.maxY - target.height,   // 顶边对齐（Cocoa 的 y 是底边）
            width: target.width,
            height: target.height
        )
        newFrame.origin.x = min(max(newFrame.origin.x, screen.minX), screen.maxX - newFrame.width)
        newFrame.origin.y = min(max(newFrame.origin.y, screen.minY), screen.maxY - newFrame.height)
        DispatchQueue.main.async {
            guard !window.isReleasedWhenClosed, window === PlayerWindowFitter.playerWindow() else { return }
            window.setFrame(newFrame, display: true, animate: true)
        }
    }

    static func restore() {
        guard let original = originalFrame,
              let window = playerWindow(),
              !isFullscreen(window)
        else {
            originalFrame = nil
            return
        }
        let target = original
        originalFrame = nil
        // 退出播放器时还原窗口。不能在 onDisappear 的 SwiftUI update cycle 里同步做
        // animate:true 的 setFrame——那个动画 helper（NSMoveHelper）会在窗口因
        // overlay 移除 / 工具栏恢复而处于不稳定状态时被驱动，实测空指针 SIGSEGV。
        // 这里延后到下一个 runloop 再立即（无动画）还原。
        DispatchQueue.main.async {
            // 竞争保护：这个闭包是异步的，执行前用户可能已经退出一场播放、重新开始了
            // 一场新的（新会话 saveOriginalIfNeeded 会把 originalFrame 换成新窗口的 frame，
            // 也可能已经被 fit() 调过比例）。只对「还是同一场」的窗口做还原：
            // 比对窗口身份，防止把新窗口误拉回旧帧。
            guard !window.isReleasedWhenClosed, window === PlayerWindowFitter.playerWindow(),
                  PlayerWindowFitter.originalFrame == nil
            else { return }
            window.setFrame(target, display: true, animate: false)
        }
    }

    private static func fittedSize(aspect: CGFloat, current: CGSize, within screen: NSRect) -> CGSize {
        let maxWidth = max(screen.width - 24, 100)
        let maxHeight = max(screen.height - 24, 100)
        // 保高调宽：比例对上就好，窗口整体大小保持原量级
        var height = current.height
        var width = height * aspect
        // 宽度超出屏幕（超宽视频 / 窗口本来就很高）：等比缩
        if width > maxWidth {
            let scale = maxWidth / width
            width *= scale
            height *= scale
        }
        // 窄到看不清（竖屏视频）：抬到最小宽，高度反推
        if width < 420 {
            width = 420
            height = 420 / aspect
        }
        // 反推 / 极端比例导致的高度超屏：再等比缩一次
        if height > maxHeight {
            let scale = maxHeight / height
            width *= scale
            height *= scale
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}
