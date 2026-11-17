import Foundation

/// overlay 采样时钟的 seek 跳变检测。**只认原始媒体时间一个时基**。
///
/// 背景：原实现把「上一拍采样点」存在 DanmakuOverlayController 的一个 Double 上，
/// tick 比较原始媒体时间、resync 却写入减过偏移的生效时间（effectiveSeconds）——
/// 两个时基混用。偏移非零时 resync 后的下一拍算出
/// `delta ≈ trackOffset + 用户偏移`，越过 seek 阈值 → 误判 seek → 再 resync →
/// 死循环：每拍清屏、`spawnUpTo` 永不执行，弹幕整集不出现。触发面覆盖
/// dandanplay 匹配的 shift、HUD 时间偏移（任何 |偏移| > 0.5s 的前移）与
/// 菜单冻结采样后的首拍。类型把「只持 raw」做成结构约束，杜绝再次混用。
///
/// 与 `effectiveSeconds`（overlay 的出场判定时基）的分工：本类型只回答
/// 「媒体时间是否发生了 tick 没看见的跳变」，偏移量多少与它无关。
struct DanmakuSeekDetector {
    enum Verdict: Equatable {
        /// 首个采样点：没有比较基准，交给调用方决定是否自动对齐。
        case firstSample
        /// 媒体时间跳变（seek / 跳片）。
        case jumped
        /// 连续采样，正常推进。
        case continuous
    }

    /// 上一次采样的**原始**媒体时间（秒）。nil = 尚无基准。
    private var lastRawSeconds: Double?

    /// 判定本次采样。前向后向阈值分开：往前跳 0.5s 以上即可疑（播放不会倒退），
    /// 往后跳要给足余量（一拍 16ms、卡顿补帧都在阈值内）。
    mutating func evaluate(rawSeconds: Double, jumpSeconds: Double) -> Verdict {
        guard let last = lastRawSeconds else {
            lastRawSeconds = rawSeconds
            return .firstSample
        }
        lastRawSeconds = rawSeconds
        let delta = rawSeconds - last
        if delta < -0.5 || delta > jumpSeconds { return .jumped }
        return .continuous
    }

    /// 对齐到指定原始媒体时间（resync / 装载后调用），下次 evaluate 以它为基准。
    mutating func align(rawSeconds: Double) {
        lastRawSeconds = rawSeconds
    }

    /// 清掉基准（换数据 / 拆装载）。
    mutating func reset() {
        lastRawSeconds = nil
    }
}
