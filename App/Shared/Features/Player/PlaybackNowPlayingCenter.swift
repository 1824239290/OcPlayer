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
/// **刻意不碰 `AVAudioSession`**：音频会话的类别 / 激活由内核适配器在每次
/// `play()` 之前统一配置（`ErikaEngine.play()` → `ErikaAudioSession`），
/// 这里再去 setCategory / setActive 只会和它抢同一份全局状态。
/// 本类型只做两件纯登记的事——报元数据、收命令，不改任何音频状态。
/// 配套前提是 `Info.plist` 的 `UIBackgroundModes: audio`（已在 `Config/Info.plist` 声明），
/// 有它才谈得上后台继续播放与锁屏控件真正可控。
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

    /// 真正落盘的动作。默认写系统「正在播放」，**测试里换成计数器桩**。
    ///
    /// ## 为什么要有这个接缝（审查阻断级）
    ///
    /// 第一批实现把判据抽成纯函数后，**9 条用例全都不经过 `publish()`** ——
    /// 把 `publish` 里对判据的调用整段删掉，用例仍然全绿。测试等于在测
    /// 「一个可能与生产无关的函数」。
    ///
    /// 而 `publish` 原先是不可测的：它最后一步直接
    /// `MPNowPlayingInfoCenter.default().nowPlayingInfo = info`，那是系统单例，
    /// 单测里没有安全替身。所以把**这一步**抽成注入点 —— 判据没有变，
    /// 但用例现在能真的驱动 `publish()` 并数「写了几次」。
    var writeNowPlaying: ([String: Any]?) -> Void = {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = $0
    }

    /// 读当前时刻（单调秒）。默认 `systemUptime`；**测试注入固定步进的时钟**。
    ///
    /// 不注入的话，测试里 `publish()` 循环瞬间跑完、`systemUptime` 几乎不动，
    /// 于是心跳判据永远不触发、而 seek 判据会因「位置一直在涨但外推时间一直是 0」
    /// 每隔几秒误触发一次 —— 用例就会得到 1201 次这种毫无意义的数字（实测如此）。
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// macOS 的 `playbackState` 也走同一个接缝（它同样是跨进程系统状态）。
    #if os(macOS)
    var writePlaybackState: (MPNowPlayingPlaybackState) -> Void = {
        MPNowPlayingInfoCenter.default().playbackState = $0
    }
    #endif

    private var handlers: Handlers?
    private var commandsRegistered = false
    /// 标题类元数据单独缓存：seek / 换速率这些内部路径不该为了重发一次进度
    /// 而去关心「剧名 + 集号」怎么拼（那份信息住在 AppModel 侧）。
    private var title = ""
    private var subtitle = ""
    /// 上一次发布的快照（`nowPlayingInfo` 的 setter 会跨进程同步，所以只在必要时写）。
    private var lastPublished: Snapshot?
    /// 上次发布的时刻（`systemUptime`，单调时钟）：seek 检测与心跳都要用它做外推基准。
    private var lastPublishedAt: TimeInterval?

    /// 一次发布的快照。**不是 `private`**：`needsRepublish` 的判据要在
    /// `AppTests` 里做表驱动测试，而判据的入参里含它。
    struct Snapshot: Equatable {
        var title: String
        var subtitle: String
        var durationSeconds: Double
        /// **精确**位置（不再取整）：它是下面「外推偏差」的基准，
        /// 取整会在每次重锚时引入最多 1 秒的固定误差。
        var positionSeconds: Double
        var rate: Double
    }

    // MARK: - 重发判据（`P2-32`，纯函数、可表驱动测试）

    /// 心跳上限：即使内容与位置都没明显变化，也每隔这么久重发一次。
    ///
    /// 系统虽然会按 `playbackRate` 外推进度，但那是**尽力而为**：
    /// 卡顿、rate 微调、系统侧重建「正在播放」面板都可能让外推与实际脱节。
    /// 10 s 一次心跳既能把漂移收回来，又把写入量从 1 Hz 降到 0.1 Hz。
    nonisolated static let heartbeatInterval: TimeInterval = 10

    /// seek 判定阈值：实际位置与「按上次发布外推出来的位置」差超过它就当作跳转。
    ///
    /// 2 s 的取值：正常播放时两者的差只有引擎的细微抖动（毫秒级），
    /// 而用户可感知的跳转（±10 秒按钮、拖进度条）都远大于它。
    nonisolated static let seekTolerance: TimeInterval = 2

    /// 这次 `publish` 要不要真的写 `nowPlayingInfo`（`P2-32`）。
    ///
    /// ## 为什么需要它
    ///
    /// 原实现是「快照不等于上次就发」，而快照里含**整秒位置** —— 于是播放中
    /// 位置每秒变一次，就等于**每秒一次跨进程 XPC 写入**（`nowPlayingInfo` 的
    /// setter 会同步到系统进程）。而系统本来就按 `playbackRate` 自行外推进度，
    /// 那些写入几乎没有信息量。
    ///
    /// 现在只在四种情况下发：
    /// 1. **首次**（`last == nil`）；
    /// 2. **内容变了**（标题 / 副标题 / 时长 / 速率 —— 暂停恢复、变速、换集都在这里）；
    /// 3. **seek**（实际位置偏离外推位置超过 `seekTolerance`）；
    /// 4. **心跳**（距上次发布超过 `heartbeatInterval`）。
    ///
    /// 正常播放时命中的只有第 4 条 → 写入量从 **1 Hz** 降到 **0.1 Hz**。
    ///
    /// - Parameters:
    ///   - last: 上次发布的快照；从未发布过为 nil。
    ///   - lastPublishedAt: 上次发布的时刻（`systemUptime`，单调时钟）。
    ///   - now: 当前时刻（同一时间基准）。
    ///
    /// ## ⚠️ 覆盖边界（不假装覆盖得更多）
    ///
    /// 表驱动用例覆盖的是**这个函数里的分支逻辑**，**不覆盖 `publish()` 是否真的
    /// 调用了它** —— 审查实测过：把 `publish` 里对它的那段 guard 整段删掉，
    /// 9 条用例仍然全绿。
    ///
    /// 要覆盖那一层，得让 `publish()` 可测，但它最后一步是
    /// `MPNowPlayingInfoCenter.default().nowPlayingInfo = info` ——
    /// 那会真的去改系统「正在播放」状态，单测里没有安全的替身
    /// （该类型是系统单例，不是协议）。
    ///
    /// 所以这里的诚实表述是：**分支逻辑有测试、接线没有**。接线靠代码评审保障。
    /// 这也是上一批（`P2-34`）被审查抓到的同一类问题 —— 我把这条边界写在这里，
    /// 避免下一个维护者以为「有测试就等于测过了」。
    nonisolated static func needsRepublish(
        last: Snapshot?,
        lastPublishedAt: TimeInterval?,
        title: String,
        subtitle: String,
        durationSeconds: Double,
        positionSeconds: Double,
        rate: Double,
        now: TimeInterval
    ) -> Bool {
        guard let last, let lastPublishedAt else { return true }

        // 2. 内容变化：这些字段一变，系统面板上的文字 / 进度条长度 / 播放按钮就要跟着变。
        if last.title != title
            || last.subtitle != subtitle
            || last.durationSeconds != durationSeconds
            || last.rate != rate {
            return true
        }

        // 4. 心跳：先判它，避免下面用「已经过去很久」的外推去做 seek 判定。
        let elapsed = now - lastPublishedAt
        if elapsed >= heartbeatInterval { return true }

        // 3. seek：按上次发布的速率外推，看实际位置偏了多少。
        //
        // ## 暂停时容差必须归零（审查发现的真 bug）
        //
        // `rate == 0` 时外推位置恒等于上次那个点，**没有任何外推误差可混淆** ——
        // 所以任何位移都是用户操作，必须立即发。
        //
        // 第一版仍套用 2 s 容差，后果被审查实测量化：暂停中拖 1.9 s（90 s 短片的
        // 滑条约 8 pt）会被判「不是 seek」；而**心跳救不了它** ——
        // `publish()` 的触发源只有「1 Hz 的 displayPosition」（仅播放中变化）、
        // state 变化与元数据变化。暂停后进度 tick 停了 → 再也不会有 `publish()` 调用
        // → 心跳永远不会响 → 系统面板位置**一直停在旧值**，直到用户恢复播放。
        //
        // 所以：暂停（rate == 0）用 0 容差；播放中才用 2 s 吸收引擎抖动。
        let expected = last.positionSeconds + last.rate * elapsed
        let tolerance = last.rate == 0 ? 0 : seekTolerance
        if abs(positionSeconds - expected) > tolerance { return true }

        return false
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

        let publishedRate = isPlaying ? rate : 0
        let currentTime = now()
        // `P2-32`：只在「首次 / 内容变 / seek / 心跳」时真写 —— 判据是纯函数。
        guard Self.needsRepublish(
            last: lastPublished,
            lastPublishedAt: lastPublishedAt,
            title: title,
            subtitle: subtitle,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            rate: publishedRate,
            now: currentTime
        ) else { return }

        let snapshot = Snapshot(
            title: title,
            subtitle: subtitle,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            rate: publishedRate
        )
        lastPublished = snapshot
        lastPublishedAt = currentTime

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
        writeNowPlaying(info)
        #if os(macOS)
        // macOS 的控制中心靠这个字段决定显示播放还是暂停图标。
        writePlaybackState(isPlaying ? .playing : .paused)
        #endif
    }

    /// 退出播放：撤掉登记，别让系统一直显示一个已经不存在的节目。
    func clear() {
        title = ""
        subtitle = ""
        guard lastPublished != nil || commandsRegistered else { return }
        lastPublished = nil
        lastPublishedAt = nil
        writeNowPlaying(nil)
        #if os(macOS)
        writePlaybackState(.stopped)
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
