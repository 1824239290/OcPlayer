import Foundation

/// App 层 UserDefaults key 的单一登记处。
///
/// 背景：`@AppStorage("dev.jumusu.ocplayer.xxx")` / `UserDefaults` 的 key 是手拼
/// 字符串，同一个 key 在多个文件各写一份（`ambientBackdrop` 曾散在设置页 /
/// 详情页 / 首页氛围三处）——改一处忘两处就是静默漂移。新 key 一律加在这里。
enum SettingsKeys {
    /// 播放内核 HTTP 预读窗口（MiB；0 = 内核默认）。设置页 ↔ PlaybackPreferences ↔ 装配。
    static let httpReadAheadMiB = "dev.jumusu.ocplayer.playback.httpReadAheadMiB"
    /// 播放内核 HTTP 回退预算（MiB；0 = 内核默认 16 MiB）。设置页 ↔ PlaybackPreferences ↔ 装配。
    static let httpBackBufferMiB = "dev.jumusu.ocplayer.playback.httpBackBufferMiB"
    /// 跳过片头开关（默认开）。设置页 ↔ PlaybackPreferences ↔ PlaybackController 门控。
    static let skipIntro = "dev.jumusu.ocplayer.playback.skipIntro"
    /// 跳过片尾开关（默认开）。片尾标记与末 90 秒保底提示一并受控。
    static let skipOutro = "dev.jumusu.ocplayer.playback.skipOutro"
    /// 保底跳过片尾的保留秒数（片长 − 该值为落点；0 = 不保留，默认 10）。
    static let outroRetentionSeconds = "dev.jumusu.ocplayer.playback.outroRetentionSeconds"
    /// 海报氛围背景开关。设置页 ↔ 详情页 ↔ 首页轮播。
    static let ambientBackdrop = "dev.jumusu.ocplayer.interface.ambientBackdrop"
    /// Bangumi 进度页排序偏好。
    static let bangumiProgressSort = "dev.jumusu.ocplayer.bangumi.progressSort"
    /// Bangumi 集成启用开关（默认开）。关闭只藏 UI 与停网络活动，登录态/关联/缓存保留。
    static let bangumiEnabled = "dev.jumusu.ocplayer.bangumi.enabled"
    /// MoviePilot 集成启用开关（默认开）。关闭只藏 UI 与停网络活动，服务器配置保留。
    static let moviepilotEnabled = "dev.jumusu.ocplayer.moviepilot.enabled"
    /// 弹幕：走 App 层 overlay 渲染（内核渲染当前被禁）。
    static let danmakuUseOverlayRenderer = "dev.jumusu.ocplayer.danmaku.useOverlayRenderer"
    /// 弹幕诊断日志开关。
    static let danmakuDiagnostics = "dev.jumusu.ocplayer.danmaku.diagnostics"
    /// 诊断日志：详细（debug）档开关。关（默认）= 只落 info 及以上（状态迁移 / 失败）；
    /// 开 = 连守卫与中间态一起落盘，排障用。见 `DiagnosticsSettings`。
    static let diagnosticsVerbose = "dev.jumusu.ocplayer.diagnostics.verbose"
    /// 更新检查：上一次拿到结果的时间（timeIntervalSince1970），自动检查的 24h 节流依据。
    static let updateLastCheckedAt = "dev.jumusu.ocplayer.update.lastCheckedAt"
    /// 更新检查：用户选择忽略提醒的版本号。
    /// 串里的 `OcPlayer` 大小写是历史原样——改掉等于丢用户的忽略记录。
    static let updateIgnoredVersion = "dev.jumusu.OcPlayer.ignoredVersion"
}

extension UserDefaults {
    /// 带默认值的 bool 读取。
    ///
    /// **别用 `bool(forKey:)` 读「默认开」的开关**：`@AppStorage` / Toggle 只会把
    /// 用户拨过的值写盘，默认值从不落盘。键不存在时 `bool(forKey:)` 返回 false，
    /// 于是「默认开」的开关对从未拨过它的人（含全新安装）实际是关的——这个坑
    /// 让 Bangumi 自动标看过静默失效过一次（review-20260914 P1-2）。
    /// 本方法在键不存在时回 fallback，语义与 Toggle 的默认值一致。
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        guard object(forKey: key) != nil else { return fallback }
        return bool(forKey: key)
    }
}
