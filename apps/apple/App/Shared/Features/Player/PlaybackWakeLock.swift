import Foundation

#if !os(macOS)
import UIKit
#endif

/// 播放期间阻止屏幕休眠 / 自动锁屏。
///
/// 内核自己不碰系统电源策略（它只管解码和出帧），所以看片看到一半屏幕黑掉、
/// iPhone 直接锁屏是 App 层的责任。
///
/// **只在真正出画面的时候持有**：暂停、出错、退出播放器都立刻放掉。
/// 暂停还压着不让休眠，等于用户按下暂停去做别的事、回来发现电池空了。
///
/// macOS 用 `ProcessInfo.beginActivity`（而不是 `IOPMAssertionCreateWithName`）：
/// 同一个令牌顺带压掉 App Nap——窗口被挡住时系统会给低优先级线程降频，
/// 渲染线程被降频就是掉帧。
@MainActor
final class PlaybackWakeLock {
    private var isHeld = false
    #if os(macOS)
    /// `beginActivity` 的令牌；`endActivity` 必须传回**同一个**对象。
    private var activity: (any NSObjectProtocol)?
    #endif

    /// 幂等：状态没变就什么都不做，不会叠出第二个令牌、也不会重复 end。
    func setActive(_ active: Bool) {
        guard active != isHeld else { return }
        isHeld = active
        if active { acquire() } else { release() }
    }

    private func acquire() {
        #if os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "OcPlayer 正在播放视频"
        )
        #else
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    private func release() {
        #if os(macOS)
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        #else
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}
