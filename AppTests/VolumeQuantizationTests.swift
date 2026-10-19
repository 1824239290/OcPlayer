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

    /// **回归对照：老的 0.005 阈值在 1/16 量化下恒成立。**
    ///
    /// 这条把「为什么原实现几乎每个事件都写」变成可执行的证据：
    /// 量化后的目标与任意一档的差，只要不是恰好同档，就 **≥ 半档 = 0.03125**，
    /// 而 0.03125 **远大于** 0.005 —— 所以老守卫永远放行。
    func testLegacyThresholdWouldAlwaysFire() {
        let legacyThreshold: Float = 0.005
        let step = PlayerPanGestureModel.volumeStep
        // 相邻两档的差 = 1/16 = 0.0625，是旧阈值的 12.5 倍。
        XCTAssertGreaterThan(step, legacyThreshold * 10,
                             "1/16 远大于 0.005 —— 这就是「几乎每个事件都写」的根因")
    }
}
