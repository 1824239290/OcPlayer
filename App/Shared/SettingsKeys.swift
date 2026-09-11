import Foundation

/// App 层 UserDefaults key 的单一登记处。
///
/// 背景：`@AppStorage("dev.jumusu.ocplayer.xxx")` / `UserDefaults` 的 key 是手拼
/// 字符串，同一个 key 在多个文件各写一份（`ambientBackdrop` 曾散在设置页 /
/// 详情页 / 首页氛围三处）——改一处忘两处就是静默漂移。新 key 一律加在这里。
enum SettingsKeys {
    /// 播放内核 HTTP 预读窗口（MiB；0 = 内核默认）。设置页 ↔ PlaybackPreferences ↔ 装配。
    static let httpReadAheadMiB = "dev.jumusu.ocplayer.playback.httpReadAheadMiB"
    /// 海报氛围背景开关。设置页 ↔ 详情页 ↔ 首页轮播。
    static let ambientBackdrop = "dev.jumusu.ocplayer.interface.ambientBackdrop"
    /// Bangumi 进度页排序偏好。
    static let bangumiProgressSort = "dev.jumusu.ocplayer.bangumi.progressSort"
    /// 弹幕：走 App 层 overlay 渲染（内核渲染当前被禁）。
    static let danmakuUseOverlayRenderer = "dev.jumusu.ocplayer.danmaku.useOverlayRenderer"
    /// 弹幕诊断日志开关。
    static let danmakuDiagnostics = "dev.jumusu.ocplayer.danmaku.diagnostics"
}
