import Foundation

/// 播放偏好跨启动记忆。弹幕渲染偏好由 HUD 修改后也在此统一保存。
@MainActor
enum PlaybackPreferences {
    private static let rateKey = "dev.jumusu.ocplayer.playback.rate"
    private static let volumeKey = "dev.jumusu.ocplayer.playback.volume"
    private static let mutedKey = "dev.jumusu.ocplayer.playback.muted"
    private static let subtitleScaleKey = "dev.jumusu.ocplayer.playback.subtitleScale"
    private static let danmakuEnabledKey = "dev.jumusu.ocplayer.danmaku.enabled"
    private static let danmakuOpacityKey = "dev.jumusu.ocplayer.danmaku.opacity"
    private static let danmakuDisplayAreaKey = "dev.jumusu.ocplayer.danmaku.displayArea"
    private static let danmakuBlockTopKey = "dev.jumusu.ocplayer.danmaku.blockTop"
    private static let danmakuBlockBottomKey = "dev.jumusu.ocplayer.danmaku.blockBottom"
    private static let danmakuBlockScrollKey = "dev.jumusu.ocplayer.danmaku.blockScroll"
    private static let danmakuMergeDuplicatesKey = "dev.jumusu.ocplayer.danmaku.mergeDuplicates"
    private static let danmakuAllowStackingKey = "dev.jumusu.ocplayer.danmaku.allowStacking"
    private static let danmakuFontSizeKey = "dev.jumusu.ocplayer.danmaku.fontSize"
    private static let danmakuDiagnosticsKey = SettingsKeys.danmakuDiagnostics

    static var rate: Double {
        get { storedDouble(forKey: rateKey, range: 0.5...2.0, default: 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: rateKey) }
    }
    static var volume: Double {
        get { storedDouble(forKey: volumeKey, range: 0...1, default: 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: volumeKey) }
    }
    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }
    static var subtitleScale: Double {
        get { storedDouble(forKey: subtitleScaleKey, range: 0.5...3.0, default: 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: subtitleScaleKey) }
    }
    static var danmakuEnabled: Bool {
        get { storedBool(forKey: danmakuEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuEnabledKey) }
    }
    static var danmakuOpacity: Double {
        get { storedDouble(forKey: danmakuOpacityKey, range: 0.25...1, default: 0.85) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuOpacityKey) }
    }
    static var danmakuDisplayArea: Double {
        get { storedDouble(forKey: danmakuDisplayAreaKey, range: 0.25...1, default: 0.75) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuDisplayAreaKey) }
    }
    static var danmakuBlockTop: Bool {
        get { storedBool(forKey: danmakuBlockTopKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuBlockTopKey) }
    }
    static var danmakuBlockBottom: Bool {
        get { storedBool(forKey: danmakuBlockBottomKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuBlockBottomKey) }
    }
    static var danmakuBlockScroll: Bool {
        get { storedBool(forKey: danmakuBlockScrollKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuBlockScrollKey) }
    }
    /// 重复弹幕合并显示。Erika 内核的合并代表项会随计划窗口滑动翻转
    /// （×N 后缀改变文本宽度→碰撞几何变化），是稳态播放中弹幕跳轨的诱因之一，
    /// 默认关闭；后续弹幕渲染方案替换后可改为装载期一次性去重。
    static var danmakuMergeDuplicates: Bool {
        get { storedBool(forKey: danmakuMergeDuplicatesKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuMergeDuplicatesKey) }
    }
    /// 允许同轨道堆叠。实测在 Erika 的 DFM 布局里 stacking 打开会把弹幕
    /// 大量塞进同一轨道导致重叠、轨道数骤减；默认关闭。需要时 HUD 可开。
    static var danmakuAllowStacking: Bool {
        get { storedBool(forKey: danmakuAllowStackingKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuAllowStackingKey) }
    }
    static var danmakuFontSize: Double {
        get { storedDouble(forKey: danmakuFontSizeKey, range: 14...36, default: 22.0) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuFontSizeKey) }
    }
    /// 弹幕诊断日志开关（默认关闭）。开启后弹幕 overlay 记录时间轴对齐点、
    /// 爆发发射与续播定位日志（写入 diagnostics.jsonl），供排查「续播起播
    /// 爆一大片弹幕」等时间轴问题用；平时关闭以减少日志噪声。
    static var danmakuDiagnosticsEnabled: Bool {
        get { storedBool(forKey: danmakuDiagnosticsKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuDiagnosticsKey) }
    }

    /// 弹幕渲染走 App 层 overlay（DanmakuRenderKit）而非 Erika 内核的 DFM+ 子系统。
    /// 当前版本内核弹幕因滑窗重排跳轨问题被禁用（`PlaybackController` 强制 overlay），
    /// 本 key 已不被读取；保留是为了将来内核修复后恢复「默认内核弹幕、可切 overlay」，
    /// 用户旧选择仍在。恢复时记得同步设置页开关与相关测试。
    static var danmakuUseOverlayRenderer: Bool {
        get { storedBool(forKey: SettingsKeys.danmakuUseOverlayRenderer, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.danmakuUseOverlayRenderer) }
    }

    /// HTTP 源前向预取窗口（MiB）。仅 Erika 内核生效；0 = 内核默认 2 MiB。
    ///
    /// 内核按块拉取（单请求封顶 4 MiB、超时续传），窗口大小不再对应成比例的带宽门槛
    /// （约 2 Mbps 即可稳定拉取）。档位主要影响内存占用与抗卡顿深度：越大越能扛
    /// 带宽抖动，弱网下也无需刻意调小；回退播放另有 16 MiB 尾部缓存兜底。
    static let readAheadOptionsMiB: [Int] = [0, 8, 16, 32]
    static var httpReadAheadMiB: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: SettingsKeys.httpReadAheadMiB)
            return readAheadOptionsMiB.contains(stored) ? stored : 0
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.httpReadAheadMiB) }
    }

    /// 当前预读偏好换算成字节（0 = 内核默认），供 PlaybackSource 直接使用。
    static var httpReadAheadBytes: UInt64? {
        let mib = httpReadAheadMiB
        guard mib > 0 else { return nil }
        return UInt64(mib) * 1024 * 1024
    }

    /// 跳过片头开关。关闭后播放中不弹「跳过片头」——章节标记与弹幕/AniSkip 提示
    /// 一并静默（门控在 `PlaybackController.currentSkipPrompt`，改动即播即生效）。
    static var skipIntroEnabled: Bool {
        get { storedBool(forKey: SettingsKeys.skipIntro, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.skipIntro) }
    }
    /// 跳过片尾开关。关闭后不弹「跳过片尾」——片尾标记与末 90 秒保底一并静默。
    static var skipOutroEnabled: Bool {
        get { storedBool(forKey: SettingsKeys.skipOutro, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.skipOutro) }
    }

    /// 保底跳过片尾的保留档位（秒）。0 = 不保留，直接跳到片尾尽头。
    static let outroRetentionOptionsSeconds: [Int] = [0, 5, 10, 15, 20, 30]
    /// 保底跳过片尾的保留秒数：落点 = 片长 − 该值，默认 10（原 20 过长，会错过
    /// 下一集自动接续的黄金窗口且拖到黑屏；存量用户没有旧值需要兼容——20 从未落盘）。
    /// 只作用于「末 90 秒保底」；服务端 MediaSegments / 章节启发式给出的片尾标记
    /// 有精确区间终点，按标记终点跳，不吃这个设置。
    static var outroRetentionSeconds: Int {
        get {
            // 不能学 httpReadAheadMiB 用 integer() 兜 0 再校验档位——0 在这里是
            // 合法档位（不保留），键缺失会被读成 0 而非默认 10，必须先探存在性。
            guard UserDefaults.standard.object(forKey: SettingsKeys.outroRetentionSeconds) != nil
            else { return 10 }
            let stored = UserDefaults.standard.integer(forKey: SettingsKeys.outroRetentionSeconds)
            return outroRetentionOptionsSeconds.contains(stored) ? stored : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.outroRetentionSeconds) }
    }

    private static func storedDouble(
        forKey key: String,
        range: ClosedRange<Double>,
        default fallback: Double
    ) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.double(forKey: key).clamped(range)
    }

    /// 默认值感知的读取统一走 `UserDefaults.bool(forKey:default:)`（见 SettingsKeys）：
    /// 键不存在时回 fallback，而不是 `bool(forKey:)` 的 false。
    private static func storedBool(forKey key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.bool(forKey: key, default: fallback)
    }
}

extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
