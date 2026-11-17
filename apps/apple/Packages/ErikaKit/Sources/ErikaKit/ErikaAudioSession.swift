#if os(iOS)
import AVFoundation
import Foundation
import PlaybackKit

/// iOS 音频会话：**内核不配这个，必须宿主配**。
///
/// 这是接入 Erika 时最容易踩空的一处：Erika 的 Rust 侧只调用 AudioToolbox 的
/// `AudioQueue*` C 函数，对 `AVFoundation` / `AVAudioSession` **零引用**
/// （iOS 切片 `nm -u liberika_capi.a` 里查不到任何 AVFoundation 符号）。
/// 也就是说「内核自己会把音频会话配好」是不成立的——默认类别（`.soloAmbient`）
/// 下退到后台 / 锁屏时，系统会把会话连同 AudioQueue 一起收走，回前台第一包数据
/// 喂进 `avcodec_send_packet` 就是 AVERROR_UNKNOWN（-1313558101），播放器被钉死在
/// 错误态，只能手动重试。
///
/// 上游把这一步放在它的 Flutter iOS 插件里（`configureAudioSessionForPlayback`），
/// 原生宿主必须自己做同一件事。配套的还有 `Info.plist` 的 `UIBackgroundModes: audio`
/// ——两件都做齐，进程才不会被挂起，后台才真的继续出声。
enum ErikaAudioSession {
    /// 每次 `play()` **之前**调用。
    ///
    /// 用 `.playback` 而不是默认类别：只有它允许锁屏 / 静音开关下继续出声。
    /// `.moviePlayback` 模式让系统按影视内容处理（不套用语音优化的路由策略）。
    ///
    /// **失败不抛给调用方**：会话没配好顶多是后台不出声，前台照常能播；
    /// 为这个把播放整个打断是本末倒置。只记一条日志，真机排查时有据可查。
    static func activateForPlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            PlaybackLog.warning("配置音频会话失败，后台/锁屏播放可能不生效 error=\(error)")
        }
    }
}
#endif
