#if os(iOS)
import AVFoundation
import Foundation
import PlaybackKit

/// `AVAudioSession` 中断（来电 / Siri / 别的 App 抢走音频）的收尾。
///
/// 配上 `.playback` 会话之后系统才会把这些通知发过来（见 `ErikaAudioSession`）。
/// 不处理的话：来电把音频抢走，播放器停在暂停态不动，挂完电话用户得自己点播放
/// ——而系统其实已经通过 `.shouldResume` 明确告诉你「该接着播了」。
///
/// 只做两件事：被打断时暂停；系统说该恢复、且**这次是我们被它打断的**，才接着播。
/// 「用户自己在打断期间按了暂停」不会被这里覆盖：`interrupted` 标记在用户操作后
/// 由 `noteUserPause()` 清掉。
@MainActor
final class PlaybackAudioInterruptions {
    struct Handlers {
        /// 当前是不是在播。用来判断「要不要记下这次中断需要恢复」。
        var isPlaying: () -> Bool
        var pause: () -> Void
        var play: () -> Void
    }

    private var handlers: Handlers?
    private var observer: NSObjectProtocol?
    /// 这次中断是不是由我们暂停的。只有它为真，`.ended` 才会自动恢复。
    private var interrupted = false

    func install(handlers: Handlers) {
        self.handlers = handlers
    }

    /// 装通知观察者。`installRemoteCommandHandlers` 调一次即可（重复调用先撤旧的）。
    func start() {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // 先把 userInfo 抽成值类型再跳 actor：`Notification` 不是 Sendable，
            // 直接塞进 MainActor 闭包会被并发检查拦下。
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            // 投递队列是 `.main`，所以这里确实在主 actor 上（`assumeIsolated` 会校验）。
            MainActor.assumeIsolated {
                self?.handle(rawType: rawType, rawOptions: rawOptions)
            }
        }
    }

    /// 撤观察者。持有者（`PlaybackController`）活得和 App 一样久，正常不会走到；
    /// 这里不做 `deinit`：`observer` 是非 Sendable 的 ObjC 对象，非隔离的 deinit
    /// 碰不了它。真漏掉也只是让一个 weak self 的闭包多挂一会儿，不会误触发。
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        interrupted = false
    }

    /// 用户自己按了暂停/播放：这次中断不再欠一次自动恢复。
    func noteUserIntent() {
        interrupted = false
    }

    private func handle(rawType: UInt?, rawOptions: UInt?) {
        guard let handlers,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            interrupted = handlers.isPlaying()
            if interrupted { handlers.pause() }
        case .ended:
            let options = rawOptions.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            defer { interrupted = false }
            guard interrupted, options.contains(.shouldResume) else { return }
            handlers.play()
        @unknown default:
            interrupted = false
        }
    }
}
#endif
