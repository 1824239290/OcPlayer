import XCTest

@testable import AppDesignKit

/// `ImageArrivalScheduler`：把一墙图片的成功回调摊到多帧应用。
///
/// 用 `.manual` 驱动（测试里不挂 `CADisplayLink` / `Timer`）：`drainFrame()` 与真实
/// 帧回调是**同一个入口**，手动调它等于精确控制「这一帧到了」。自动驱动不在这里测 ——
/// 它依赖真实 run loop 与屏幕，在无头环境上只会换来 flaky 用例；`drainFrame` 的
/// 语义才是需要钉住的东西。
@MainActor
final class ImageArrivalSchedulerTests: XCTestCase {

    /// 手动驱动的调度器：`frameBudget = 3`、`pendingLimit = 8`。
    private func makeScheduler(
        frameBudget: Int = 3,
        pendingLimit: Int = 8
    ) -> ImageArrivalScheduler {
        ImageArrivalScheduler(
            frameBudget: frameBudget,
            pendingLimit: pendingLimit,
            frameInterval: 1.0 / 60.0,
            driverMode: .manual
        )
    }

    /// 一帧只应用 `frameBudget` 个，剩下的留到下一帧。
    func testFrameBudgetLimitsApplicationsPerFrame() {
        let scheduler = makeScheduler(frameBudget: 3)
        var applied: [Int] = []
        for index in 0..<7 {
            scheduler.enqueue { applied.append(index) }
        }
        XCTAssertEqual(scheduler.pendingCount, 7)

        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 1, 2], "一帧最多应用 frameBudget 个")
        XCTAssertEqual(scheduler.pendingCount, 4)

        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 1, 2, 3, 4, 5])

        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    /// FIFO：先入队的先上屏，否则一墙海报会按「谁先解码完」乱序跳。
    func testArrivalsApplyInFIFOOrder() {
        let scheduler = makeScheduler(frameBudget: 2, pendingLimit: 16)
        var applied: [String] = []
        for name in ["a", "b", "c", "d", "e"] {
            scheduler.enqueue { applied.append(name) }
        }

        for _ in 0..<3 { scheduler.drainFrame() }
        XCTAssertEqual(applied, ["a", "b", "c", "d", "e"])
    }

    /// 取消项**跳过且不占预算**：否则一屏滚过去之后，真正的图要等好几帧才出现。
    func testCancelledArrivalsAreSkippedWithoutConsumingBudget() {
        let scheduler = makeScheduler(frameBudget: 3)
        var applied: [Int] = []
        var tokens: [ImageArrivalScheduler.Arrival?] = []
        for index in 0..<6 {
            tokens.append(scheduler.enqueue { applied.append(index) })
        }

        scheduler.cancel(tokens[1])
        scheduler.cancel(tokens[3])
        XCTAssertEqual(scheduler.pendingCount, 4, "取消要立刻从待办里摘掉")

        scheduler.drainFrame()
        XCTAssertEqual(
            applied, [0, 2, 4],
            "被取消的两项不该占掉这一帧的预算：一帧仍然要上满 3 张")
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 2, 4, 5])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    /// 取消已经执行完 / 从没入过队的令牌是幂等 no-op。
    func testCancelAfterExecutionIsNoOp() {
        let scheduler = makeScheduler(frameBudget: 4)
        var applied = 0
        let token = scheduler.enqueue { applied += 1 }
        scheduler.drainFrame()
        XCTAssertEqual(applied, 1)

        scheduler.cancel(token)
        scheduler.cancel(nil)
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.drainFrame()
        XCTAssertEqual(applied, 1, "重复取消不该影响已应用的项")
    }

    /// 队列达到上限且**不在** drain 中：先消费一帧腾位，再入队。
    ///
    /// 这条防的是「生产者一波推来 300 张，队列直接拒绝 44 张、那些图永远不上屏」。
    func testEnqueueAtLimitConsumesAFrameFirst() {
        let scheduler = makeScheduler(frameBudget: 3, pendingLimit: 4)
        var applied: [Int] = []
        for index in 0..<4 {
            XCTAssertNotNil(scheduler.enqueue { applied.append(index) })
        }
        XCTAssertEqual(scheduler.pendingCount, 4)
        XCTAssertTrue(applied.isEmpty, "入队本身不该触发应用")

        let overflow = scheduler.enqueue { applied.append(4) }

        XCTAssertNotNil(overflow, "非重入场景要腾位而不是拒绝")
        XCTAssertEqual(applied, [0, 1, 2], "腾位就是同步消费掉一帧预算")
        XCTAssertEqual(scheduler.pendingCount, 2)

        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 1, 2, 3, 4])
    }

    /// 重入生产（在一次应用的执行体里入队）撞上硬上限时返回 nil —— 调用方据此
    /// 决定「立刻上屏」而不是静默丢掉这张图（见 `RemoteImage.apply`）。
    func testReentrantEnqueueAtHardLimitIsRejected() {
        let scheduler = makeScheduler(frameBudget: 1, pendingLimit: 2)
        var rejected: [Int] = []
        var applied: [Int] = []

        scheduler.enqueue {
            applied.append(0)
            // 执行体内再入队：此时 isDraining == true，不允许递归消费。
            for index in 1...4 {
                let token = scheduler.enqueue { applied.append(index) }
                if token == nil { rejected.append(index) }
            }
        }
        scheduler.drainFrame()
        XCTAssertEqual(rejected, [3, 4], "超过 pendingLimit 的入队要拿到 nil")
        XCTAssertEqual(scheduler.pendingCount, 2)
        XCTAssertFalse(scheduler.isDrainingForTesting, "drain 结束必须复位重入标记")
        XCTAssertEqual(applied, [0])

        // 被接受的两项照常按帧落地。
        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 1])
        scheduler.drainFrame()
        XCTAssertEqual(applied, [0, 1, 2])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    /// 递归 `drainFrame()` 必须被忽略：否则一次 tick 会连锁跑到队列见底，
    /// 帧预算形同虚设。
    func testNestedDrainIsIgnored() {
        let scheduler = makeScheduler(frameBudget: 1, pendingLimit: 8)
        var applied: [String] = []

        scheduler.enqueue {
            applied.append("first")
            scheduler.drainFrame()   // 重入：应被 isDraining 挡掉
        }
        scheduler.enqueue { applied.append("second") }

        scheduler.drainFrame()
        XCTAssertEqual(applied, ["first"], "重入的 drain 不该顺带消费掉第二项")
        XCTAssertEqual(scheduler.pendingCount, 1)

        scheduler.drainFrame()
        XCTAssertEqual(applied, ["first", "second"])
    }

    /// 队列消费完之后要回收存储（长会话里否则只增不减）。
    func testStorageIsCompactedAfterDrain() {
        let scheduler = makeScheduler(frameBudget: 8, pendingLimit: 32)
        for index in 0..<5 {
            scheduler.enqueue { _ = index }
        }
        XCTAssertGreaterThan(scheduler.storageCountForTesting, 0)

        scheduler.drainFrame()

        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.storageCountForTesting, 0, "整队消费完要把存储清空")
        XCTAssertEqual(scheduler.headCursorForTesting, 0)
    }

    /// 预算与上限的非法输入要有下界（0 会让队列永不推进 / 永远拒绝）。
    func testBudgetAndLimitAreClampedToAtLeastOne() {
        let scheduler = makeScheduler(frameBudget: 0, pendingLimit: 0)
        XCTAssertEqual(scheduler.frameBudget, 1)
        XCTAssertEqual(scheduler.pendingLimit, 1)

        var applied = 0
        XCTAssertNotNil(scheduler.enqueue { applied += 1 })
        scheduler.drainFrame()
        XCTAssertEqual(applied, 1)
    }
}
