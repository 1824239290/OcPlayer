import XCTest
@testable import OcPlayer

/// 弹幕发射调度：单拍上限、顺延、积压清屏。此前发射循环无上限，2s 阈值内的
/// 前向 seek 会把窗口内几十到几百条弹幕压在同一帧出场。
final class DanmakuSpawnPlannerTests: XCTestCase {

    private func decide(
        times: [Double],
        pointer: Int = 0,
        threshold: Double,
        lastThreshold: Double?,
        maxPerTick: Int = DanmakuSpawnPlanner.defaultMaxPerTick
    ) -> DanmakuSpawnPlanner.Decision {
        DanmakuSpawnPlanner.decide(
            count: times.count,
            time: { times[$0] },
            pointer: pointer,
            threshold: threshold,
            lastThreshold: lastThreshold,
            seekJumpSeconds: 2.0,
            maxPerTick: maxPerTick
        )
    }

    func testNormalTickEmitsAllDueComments() {
        // 正常节奏：一拍到点的只有几条，全部发出。
        let times = [0.5, 1.0, 1.05, 1.06]
        XCTAssertEqual(
            decide(times: times, threshold: 1.06, lastThreshold: 1.043),
            .emit(advanceTo: 4)
        )
    }

    func testNothingDueKeepsPointer() {
        let times = [5.0, 6.0]
        XCTAssertEqual(
            decide(times: times, threshold: 1.0, lastThreshold: 0.99),
            .emit(advanceTo: 0)
        )
    }

    /// 300 条突发：首拍只发 24 条，指针停在上限处（剩余顺延到后续拍）。
    func testBurstIsCappedPerTick() {
        let times = (0..<300).map { Double($0) * 0.001 }
        XCTAssertEqual(
            decide(times: times, threshold: 0.5, lastThreshold: 0.4),
            .emit(advanceTo: 24)
        )
        // 下一拍从 24 继续，仍受上限约束。
        XCTAssertEqual(
            decide(times: times, pointer: 24, threshold: 0.6, lastThreshold: 0.5),
            .emit(advanceTo: 48)
        )
    }

    /// 1.9s 前向 seek（低于 2s 阈值，不触发 tick 的 seek 重同步）：
    /// 窗口内弹幕分批出场而不是一帧喷完。
    func testForwardSeekWithinThresholdDefersInsteadOfBursting() {
        let times = (0..<150).map { 10.0 + Double($0) * 0.01 }
        var pointer = 0
        var tickCount = 0
        var advanceTo = 0
        repeat {
            guard case .emit(let next) = decide(
                times: times, pointer: pointer, threshold: 11.9, lastThreshold: 10.0 + Double(tickCount) * 0.016
            ) else {
                return XCTFail("首拍不该判定为积压跳变")
            }
            advanceTo = next
            pointer = next
            tickCount += 1
        } while advanceTo < times.count && tickCount < 100

        // 150 条摊成 7 拍（24×6 + 6），而不是第 1 拍全发。
        XCTAssertEqual(tickCount, 7)
        XCTAssertEqual(advanceTo, times.count)
    }

    /// 超过 seekJumpSeconds 的跳变：清屏重对齐（既有兜底语义保留）。
    func testBacklogJumpResets() {
        let times = [0.0, 1.0, 2.0]
        XCTAssertEqual(
            decide(times: times, threshold: 10.0, lastThreshold: 3.0),
            .resetBacklog
        )
    }

    func testPointerClampedToBounds() {
        let times = [1.0, 2.0]
        // 指针越界（理论上不该发生）不崩、不倒退。
        XCTAssertEqual(
            decide(times: times, pointer: 99, threshold: 5.0, lastThreshold: 4.9),
            .emit(advanceTo: 2)
        )
    }
}
