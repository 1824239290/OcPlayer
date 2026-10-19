import XCTest

@testable import OcPlayer

/// 系统音量量化（性能审查清单 `P1-14`）。
///
/// ## 为什么需要量化
///
/// `MPVolumeView` 的音量是 **1/16 量化**的，而纵滑手势给的是连续 `0...1`。
/// 原先的守卫是「差 > **0.005** 就写」—— 而 0.005 远小于 1/16 = 0.0625：
/// `MPVolumeView` 会把写入值自己取整，`slider.value` 读回来是取整后的值，
/// 于是下一次比较「差」仍大于 0.005，**几乎每个触摸事件都通过守卫**。
///
/// 一次 1 秒纵滑 ≈ 数百次跨进程系统音量写入（再经 KVO + 主 actor Task 回写）。
/// 量化到同一档后，档内连续拖动**一次都不写**。
final class VolumeQuantizationTests: XCTestCase {

    /// 目标必须落在 1/16 的整数倍上。
    func testQuantizedVolumeSnapsToSixteenths() {
        let step = PlayerPanGestureModel.volumeStep
        XCTAssertEqual(step, 1.0 / 16.0, accuracy: 1e-6, "MPVolumeView 的档位是 1/16")

        for raw in stride(from: 0.0, through: 1.0, by: 0.01) {
            let q = PlayerPanGestureModel.quantizedVolume(Float(raw))
            let steps = q / step
            XCTAssertEqual(
                steps, steps.rounded(), accuracy: 1e-5,
                "量化结果 \(q) 不在 1/16 的整数倍上（raw=\(raw)）")
            XCTAssertGreaterThanOrEqual(q, 0)
            XCTAssertLessThanOrEqual(q, 1)
        }
    }

    /// 超出 `0...1` 的输入要被夹住。
    func testQuantizedVolumeClampsOutOfRange() {
        XCTAssertEqual(PlayerPanGestureModel.quantizedVolume(-5), 0)
        XCTAssertEqual(PlayerPanGestureModel.quantizedVolume(5), 1)
        XCTAssertEqual(PlayerPanGestureModel.quantizedVolume(0), 0)
        XCTAssertEqual(PlayerPanGestureModel.quantizedVolume(1), 1)
    }

    /// **核心判据：同一档内的连续拖动，量化结果完全相同。**
    ///
    /// 这条直接钉住「档内不写系统音量」—— 若量化被去掉、或容差被改小，
    /// 同一档内的不同 raw 值会给出不同结果，用例立刻红。
    func testContinuousDragWithinOneStepProducesIdenticalTargets() {
        let step = PlayerPanGestureModel.volumeStep
        // 取第 5 档附近：4.5/16 ~ 5.5/16 都四舍五入到 5/16。
        let center = 5 * step
        let targets = stride(from: -0.4, through: 0.4, by: 0.05).map { delta in
            PlayerPanGestureModel.quantizedVolume(center + Float(delta) * step)
        }
        XCTAssertEqual(
            Set(targets), [center],
            "同一档内的连续拖动给出了不同的量化目标 \(Set(targets)) —— 每个事件都会写系统音量")
    }

    /// **对照：跨档时必须换目标**（不能为了少写而把不同档也合并）。
    ///
    /// ⚠️ 档位边界在 **±0.5 档**处（`.rounded()` 是四舍五入），所以
    /// `4.9 档` 与 `5.1 档` 都落在第 5 档、量化结果**相同** ——
    /// 要观测到变化，必须跨过边界（这里取 4.4 档与 5.6 档）。
    func testCrossingAStepChangesTarget() {
        let step = PlayerPanGestureModel.volumeStep
        let lower = PlayerPanGestureModel.quantizedVolume(4.4 * step)
        let upper = PlayerPanGestureModel.quantizedVolume(5.6 * step)
        XCTAssertNotEqual(lower, upper, "跨档必须产生不同目标，否则音量条会跳不过去")
        XCTAssertEqual(lower, 4 * step, accuracy: 1e-6)
        XCTAssertEqual(upper, 6 * step, accuracy: 1e-6)
    }

    /// 档位边界确实是 ±0.5 档：`4.9 档` 与 `5.1 档` 同档，`4.4 档` 与 `5.6 档` 不同档。
    ///
    /// 这条把「半档容差」的语义钉死 —— 守卫用的 `slider.value` 已经是量化值，
    /// 所以「差 ≥ 半档」才可能真的换档。
    func testStepBoundaryIsAtHalfStep() {
        let step = PlayerPanGestureModel.volumeStep
        XCTAssertEqual(PlayerPanGestureModel.quantizedVolume(4.9 * step),
                       PlayerPanGestureModel.quantizedVolume(5.1 * step),
                       "半档以内应落在同一档")
        XCTAssertEqual(PlayerPanGestureModel.quantizedVolume(5.5 * step), 6 * step,
                       "恰好半档处四舍五入向上（.rounded() 远离零）")
    }

    /// 半档容差是步长的一半 —— 守卫用它判断「是否已经在同一档」。
    func testHalfStepIsHalfTheVolumeStep() {
        XCTAssertEqual(
            PlayerPanGestureModel.volumeHalfStep,
            PlayerPanGestureModel.volumeStep / 2, accuracy: 1e-6)
    }

    // MARK: - 守卫本体（P1-14 真正改变行为的那几行）

    /// **守卫必须用半档容差，不能用半档以外的值。**
    ///
    /// ⚠️ 这组用例是补洞用的：原先 7 条只测 `quantizedVolume` 纯函数，而
    /// **真正改变行为的是 `updateUIView` 里那 4 行守卫**（`abs(slider.value - target)
    /// > 0.005` → 量化 + 半档容差）。独立审查实测：把守卫改回 `> 0.005`，
    /// 那 7 条用例**全绿** —— 等于本批的核心改动零覆盖。
    ///
    /// 现在守卫抽成了 `PlayerPanGestureModel.shouldWriteVolume(current:target:)`，
    /// 在 macOS 靶上可测。
    func testGuardUsesHalfStepTolerance() {
        let step = PlayerPanGestureModel.volumeStep
        let half = PlayerPanGestureModel.volumeHalfStep
        let current = 5 * step

        // 同档（差值 0）：不写。
        XCTAssertFalse(PlayerPanGestureModel.shouldWriteVolume(current: current, target: current),
                       "差值 0 不该写")

        // 差一点不到半档：不写（否则一次滑动会反复写）。
        XCTAssertFalse(
            PlayerPanGestureModel.shouldWriteVolume(current: current, target: current + half * 0.99),
            "不到半档不该写")

        // 恰好半档：写（`>=`，边界包含）。
        XCTAssertTrue(
            PlayerPanGestureModel.shouldWriteVolume(current: current, target: current + half),
            "恰好半档应该写")

        // 超过半档：写。
        XCTAssertTrue(
            PlayerPanGestureModel.shouldWriteVolume(current: current, target: current + step),
            "一整档必须写")
    }

    /// **回归：老的 `0.005` 阈值在半档语义下必然「几乎每次都写」。**
    ///
    /// 这条用**行为**证明，不是常量比大小：
    /// 老守卫是「差 > 0.005 就写」，而半档是 0.03125 —— 于是「差在 0.005 与半档之间」
    /// 这个区间里，老实现写、新实现不写。取这个区间里的一个值验两种判定相反。
    func testLegacyThresholdWouldWriteWhereQuantizedGuardDoesNot() {
        let step = PlayerPanGestureModel.volumeStep
        let current = 5 * step
        // 差 0.02：介于 0.005 与半档 0.03125 之间。
        let target = current + 0.02

        let legacyWouldWrite = abs(current - target) > 0.005
        let quantizedWouldWrite = PlayerPanGestureModel.shouldWriteVolume(
            current: current, target: target)

        XCTAssertTrue(legacyWouldWrite, "老阈值（0.005）在这个差值下会写")
        XCTAssertFalse(quantizedWouldWrite, "量化后的半档守卫不该写")
        XCTAssertNotEqual(legacyWouldWrite, quantizedWouldWrite,
                          "两种守卫在「0.005 ~ 半档」区间必须给出**相反**结论 —— 这正是老实现几乎每个事件都写的原因")
    }

    /// 守卫对**偏离网格**的 `current` 也成立（蓝牙 / AirPlay / 硬件音量键可能给非网格值）。
    func testGuardHandlesOffGridCurrentValues() {
        let step = PlayerPanGestureModel.volumeStep
        let offGrid = 5 * step + 0.01   // 不算在 1/16 网格上
        let target = 5 * step

        // 偏差 0.01 < 半档 → 不写（避免为了一点偏移反复写）。
        XCTAssertFalse(PlayerPanGestureModel.shouldWriteVolume(current: offGrid, target: target))
        // 偏差到半档 → 吸附。
        XCTAssertTrue(PlayerPanGestureModel.shouldWriteVolume(
            current: offGrid, target: target + step))
    }}
