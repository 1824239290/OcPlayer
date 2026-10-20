import CoreModel
import XCTest

@testable import OcPlayer

/// `P2-34`：`schedulePreparationDismiss` 的 100 ms 轮询循环必须有总时限。
///
/// ## 测的是哪一部分（以及为什么不测别的）
///
/// 循环体依赖播放器内部状态（首帧标志 / `state` / `setupError`），在测试环境里
/// `playback` 恒为 nil —— 循环会走 `guard let playback else { ... return }`
/// **立即退出**，根本到不了时限分支。伪造出「engine 为 nil、state 既非 error 也非
/// playing」的组合等于测一个生产里不存在的状态。
///
/// 所以时限判定被抽成了纯函数 `shouldAbandonPreparation(elapsed:deadline:)`，
/// 它**与播放器状态无关**，可以独立验证。循环里调用的就是它。
final class PreparationDismissDeadlineTests: XCTestCase {

    private typealias Policy = AppModel

    /// **核心判据：超过时限就要放弃。**
    func testAbandonsAfterDeadline() {
        let deadline = Duration.seconds(30)
        XCTAssertFalse(Policy.shouldAbandonPreparation(elapsed: .zero, deadline: deadline))
        XCTAssertFalse(Policy.shouldAbandonPreparation(elapsed: .seconds(1), deadline: deadline))
        XCTAssertFalse(Policy.shouldAbandonPreparation(elapsed: .seconds(29), deadline: deadline))
        XCTAssertTrue(Policy.shouldAbandonPreparation(elapsed: .seconds(31), deadline: deadline))
        XCTAssertTrue(Policy.shouldAbandonPreparation(elapsed: .seconds(600), deadline: deadline))
    }

    /// 边界：**恰好等于时限时不放弃**（严格大于），与循环里的 `>` 一致。
    ///
    /// 这条钉住比较方向 —— 写成 `>=` 会让恰好卡点的正常路径被误判。
    func testBoundaryIsExclusive() {
        let deadline = Duration.seconds(30)
        XCTAssertFalse(Policy.shouldAbandonPreparation(elapsed: .seconds(30), deadline: deadline),
                       "恰好等于时限不该放弃（循环里是严格大于）")
        // 多 1 纳秒就算超过。
        XCTAssertTrue(Policy.shouldAbandonPreparation(
            elapsed: .seconds(30) + .nanoseconds(1), deadline: deadline))
    }

    /// **任何 finite 时限最终都会放弃** —— 这是「不会永久轮询」的形式化表述。
    ///
    /// 用一批时限值验证：只要 elapsed 足够大，判定必然为真。若哪天有人把实现改成
    /// `return false`（永不放弃），这条会红。
    func testAlwaysAbandonsEventually() {
        for seconds in [1, 5, 30, 60, 300] {
            let deadline = Duration.seconds(seconds)
            let beyond = Duration.seconds(seconds + 1)
            XCTAssertTrue(
                Policy.shouldAbandonPreparation(elapsed: beyond, deadline: deadline),
                "时限 \(seconds)s 之后必须放弃，否则就是永久轮询")
        }
    }

    /// 生产时限默认 30 秒，别被误改小（太小会误撤 loading）。
    ///
    /// `AppModel` 是 `@MainActor`，静态属性也是主 actor 隔离的 ——
    /// 不能在 `XCTAssertEqual` 的 autoclosure（非隔离）里直接读，先取出来。
    @MainActor
    func testProductionDeadlineIsSane() {
        let deadline = AppModel.preparationDismissDeadline
        XCTAssertGreaterThan(deadline, .seconds(5), "太短会误撤 loading")
        XCTAssertLessThanOrEqual(deadline, .seconds(120), "太长等于没有总时限")
    }
}
