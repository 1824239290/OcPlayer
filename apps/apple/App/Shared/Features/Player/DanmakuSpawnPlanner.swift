import Foundation

/// 弹幕 overlay 每拍（tick）发射量的纯决策。
///
/// 背景：原来的发射循环没有单拍上限，正常节奏下无所谓（一拍也就发几条），但
/// `seekJumpSeconds` 阈值以内的前向 seek（例如往回跳 1.9s）会让窗口内几十到几百条
/// 弹幕在**同一拍**里全部出场：每次出场都要测字宽、取 cell、建视图，主线程直接结一
/// 个尖峰。这里把「这一拍发到哪」抽成纯函数，超出上限的部分顺延到后续拍——
/// 60Hz 下 24 条/拍 ≈ 1440 条/s，远超正常弹幕密度，观感上只是把一次爆发摊成若干帧。
///
/// 与 `tick()` 的分工：tick 负责 seek 检测（时间跳变 → resync）与暂停跟随，本类型只
/// 负责「已确认要发射时，这一拍发多少」和「积压跳变要清屏」两个决定。
enum DanmakuSpawnPlanner {

    /// 单拍发射上限。取 24：密集剧集的一拍正常也就个位数，24 仍留足余量；
    /// 而 300 条的补发会摊成约 13 拍（~0.2s），视觉上是「一片弹幕快速飘出来」，
    /// 不是一帧卡顿。
    static let defaultMaxPerTick = 24

    enum Decision: Equatable {
        /// 把指针推进到 `advanceTo`（发射 `pointer..<advanceTo` 区间）。
        case emit(advanceTo: Int)
        /// 两次发射机会之间媒体时间前进超过 `seekJumpSeconds`：积压的是早已过点的
        /// 弹幕，清屏重对齐而不是补发（就是「续播起播爆一大片」的兜底）。
        case resetBacklog
    }

    /// - Parameters:
    ///   - count: 弹幕总数。
    ///   - time: 第 i 条的出场时间；升序。
    ///   - pointer: 下一条待发射的下标。
    ///   - threshold: 当前生效时间点（媒体时间 − 轨道偏移 − 用户偏移）。
    ///   - lastThreshold: 上一次发射机会时的生效时间点；nil = 首次。
    ///   - maxPerTick: 单拍上限。
    static func decide(
        count: Int,
        time: (Int) -> Double,
        pointer: Int,
        threshold: Double,
        lastThreshold: Double?,
        seekJumpSeconds: Double,
        maxPerTick: Int = defaultMaxPerTick
    ) -> Decision {
        if let last = lastThreshold, threshold - last > seekJumpSeconds {
            return .resetBacklog
        }
        var next = max(0, min(pointer, count))
        var emitted = 0
        while next < count, time(next) <= threshold, emitted < maxPerTick {
            next += 1
            emitted += 1
        }
        return .emit(advanceTo: next)
    }
}
