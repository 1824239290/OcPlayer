import Foundation
import MediaPlayer

/// 跳转步长，与 HUD 上的 ±10 秒保持一致。
///
/// 故意放在文件作用域：远程命令的 handler 由 MediaPlayer 在**非主线程**调起，
/// 而 `@MainActor` 类型的静态成员也带着 actor 隔离，在那里读不到（Swift 6 直接报错）。
private let remoteSkipInterval: Double = 10

/// 系统「正在播放」信息与远程控制命令。
///
/// 拿到的好处：macOS 上键盘媒体键 / 控制中心 / 灵动岛式的「正在播放」小组件能控播放，
/// iOS 上锁屏与控制中心同理。之前这些一律没反应——App 从来没往系统登记过任何东西。
///
/// **刻意不碰 `AVAudioSession`**：内核（Erika）自己在 Rust 侧配置音频输出，
/// App 层再去 setCategory / setActive 有可能把它已经建好的会话打翻。
/// 这里只做两件纯登记的事——报元数据、收命令，不改任何音频状态。
/// 因此 iOS 上锁屏能否显示，取决于内核把会话激活成什么类别；
/// 后台播放还需要 `UIBackgroundModes: audio`（当前 Info.plist 没开，属另一件事）。
@MainActor
final class PlaybackNowPlayingCenter {
    /// 命令回调。`PlaybackController` 装一次，之后不再变。
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
    }

    private var handlers: Handlers?
    private var commandsRegistered = false
    /// 标题类元数据单独缓存：seek / 换速率这些内部路径不该为了重发一次进度
    /// 而去关心「剧名 + 集号」怎么拼（那份信息住在 AppModel 侧）。
    private var title = ""
    private var subtitle = ""
    /// 上一次发布的快照：内容没变就不重发（`nowPlayingInfo` 的 setter 会跨进程同步）。
    private var lastPublished: Snapshot?

    private struct Snapshot: Equatable {
        var title: String
        var subtitle: String
        var durationSeconds: Double
        var positionSeconds: Double
        var rate: Double
    }

    func install(handlers: Handlers) {
        self.handlers = handlers
    }

    func setMetadata(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    /// 发布当前状态。`isActive` 为 false 表示没有在播的源，直接清空。
    func publish(
        durationSeconds: Double,
        positionSeconds: Double,
        rate: Double,
        isPlaying: Bool,
        isActive: Bool
    ) {
        guard isActive else {
            clear()
            return
        }
        registerCommandsIfNeeded()

        let snapshot = Snapshot(
            title: title,
            subtitle: subtitle,
            durationSeconds: durationSeconds,
            // 位置只在**整秒**上比较：系统会用 rate 自行外推，逐帧重发纯属浪费。
            positionSeconds: positionSeconds.rounded(.down),
            rate: isPlaying ? rate : 0
        )
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
        ]
        if !snapshot.subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = snapshot.subtitle
        }
        // 直播 / 时长未知的源不要报 0，否则进度条会显示成"已播完"。
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // macOS 的控制中心靠这个字段决定显示播放还是暂停图标。
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    /// 退出播放：撤掉登记，别让系统一直显示一个已经不存在的节目。
    func clear() {
        title = ""
        subtitle = ""
        guard lastPublished != nil || commandsRegistered else { return }
        lastPublished = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        unregisterCommands()
    }

    // MARK: - 远程命令

    /// 只在真的有源时登记：不然 App 一启动就抢走媒体键，用户在别处放歌会被打断。
    ///
    /// 每个 handler 里都只做两件事：把事件里的数值（`Double`，Sendable）就地取出来，
    /// 然后 `Task { @MainActor }` 跳回主 actor 再调回调。**不**用
    /// `MainActor.assumeIsolated`——MediaPlayer 没有承诺在主线程调 handler，
    /// 猜错就是崩溃；这里跳一次的代价可以忽略。
    private func registerCommandsIfNeeded() {
        guard !commandsRegistered, handlers != nil else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers?.play() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers?.toggle() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? remoteSkipInterval
            Task { @MainActor in self?.handlers?.skip(interval) }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? remoteSkipInterval
            Task { @MainActor in self?.handlers?.skip(-interval) }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.handlers?.seek(position) }
            return .success
        }
    }

    /// `removeTarget(nil)` 拆掉本 App 装的所有 handler；顺带禁用，交还媒体键。
    private func unregisterCommands() {
        guard commandsRegistered else { return }
        commandsRegistered = false
        let center = MPRemoteCommandCenter.shared()
        for command in [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
        ] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }
}
