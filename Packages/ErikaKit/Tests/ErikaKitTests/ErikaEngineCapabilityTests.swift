import ErikaKit
import XCTest

/// 内核**自报能力**的回归守卫。
///
/// `supportsBackgroundAudio` 是一个开关式的判定：它决定 `PlaybackController` 进后台时
/// 走哪条路——`true` 走内核内建的「挂起视频解码 / 回前台 flush 恢复」通路（iOS 切后台
/// 回来不再报错、不用点重试）；一旦被误改成 `false`，就会静默退回「挂起前暂停、
/// 回前台重建整个内核」的老做法，症状正是要根治的那个。改这里之前先读
/// `ErikaEngine.setBackgroundAudioOnly` 与 `PlaybackEngine.supportsBackgroundAudio`。
///
/// 这个套件只读静态标志，不实例化 presenter（无 Metal / 无 GPU 的机器上也能跑）。
final class ErikaEngineCapabilityTests: XCTestCase {

    /// Erika 的 v0.2.1 内核已导出 `erika_presenter_audio_only_tick`
    /// （`nm -g liberika_capi.a` 可见），后台档确实可用。
    func testErikaAdvertisesBackgroundAudio() {
        XCTAssertTrue(
            ErikaEngine.supportsBackgroundAudio,
            "Erika 有内建后台播放通路（audio_only_tick），关掉它等于退回「切后台必报错」"
        )
    }

    /// 另一个自报能力，同样别被误改：App 的弹幕 overlay 路线按它分流。
    func testErikaAdvertisesKernelDanmaku() {
        XCTAssertTrue(ErikaEngine.supportsKernelDanmaku)
    }
}
