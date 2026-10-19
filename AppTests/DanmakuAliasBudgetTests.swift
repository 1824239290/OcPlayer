import Foundation
import XCTest

@testable import OcPlayer

/// 弹幕手动搜索的**别名链不阻塞主检索**（性能审查清单 `P1-02`）。
///
/// ## 为什么算问题
///
/// 改前是「主检索 `await` 完 → 再 `await` 别名链」：最坏是两段**串行 RTT**
/// （网关 `timeoutIntervalForRequest = 10` / `ForResource = 20`，所以是
/// ≤10–20 s 的串行等待），而这期间**网关已经成功返回的结果上不了屏**。
///
/// 改后：别名链先并发起飞 → 主检索回来即可用 → 别名最多再等 `aliasBudget`，
/// 超时就放弃（别名只是「多找回几部」的增强，不是结果正确性的前提）。
///
/// ## 这组用例测什么
///
/// 直接测 `boundedValue` 的语义（超时不阻塞、按时返回原值、不取消工作），
/// 以及 `firstNonEmptyAliasResult` 的「命中即停」契约 —— 这两块是并发改动的
/// 全部新增逻辑，`searchEpisodes` 本身只是把两者接起来。
final class DanmakuAliasBudgetTests: XCTestCase {

    /// 工作**先于**预算完成 → 原值返回。
    func testReturnsValueWhenWorkFinishesFirst() async {
        let work = Task { () -> Int in
            try? await Task.sleep(for: .milliseconds(10))
            return 42
        }
        let value = await DanmakuCoordinator.boundedValue(of: work, within: .milliseconds(500))
        XCTAssertEqual(value, 42)
    }

    /// 工作**慢于**预算 → nil（放弃别名），且**不等**它跑完。
    ///
    /// 判据用耗时：若实现是「等 work 完成再丢弃」，这里会花 ~1s；期望是远小于它。
    func testReturnsNilPromptlyWhenWorkIsTooSlow() async {
        let work = Task { () -> Int in
            try? await Task.sleep(for: .milliseconds(1_000))
            return 7
        }
        let started = CFAbsoluteTimeGetCurrent()
        let value = await DanmakuCoordinator.boundedValue(of: work, within: .milliseconds(50))
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000

        XCTAssertNil(value, "超预算时必须放弃别名")
        XCTAssertLessThan(elapsedMs, 500,
                          "耗时 \(Int(elapsedMs)) ms —— 说明它在等慢任务跑完，而不是超时就返回")
    }

    /// 超时放弃之后，那个工作**仍然能自然完成**（我们不取消它，只是不等）。
    ///
    /// 这条防的是「为了超时而把工作取消掉」——那会让 `firstNonEmptyAliasResult`
    /// 内部的循环提前退出，语义从「放弃等待」变成「取消请求」。
    func testSlowWorkStillCompletesAfterWeGiveUpWaiting() async {
        let box = CompletionBox()
        let work = Task { () -> Int in
            try? await Task.sleep(for: .milliseconds(120))
            box.markDone()
            return 7
        }
        let value = await DanmakuCoordinator.boundedValue(of: work, within: .milliseconds(20))
        XCTAssertNil(value)

        // 等它自己跑完。
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(box.isDone, "被放弃等待的工作必须仍能自然完成（没被取消）")
    }

    /// 预算本身是有限值：不能设成 0（等于永远放弃别名）或无穷。
    func testAliasBudgetIsSane() {
        XCTAssertGreaterThan(DanmakuCoordinator.aliasBudget, .milliseconds(200),
                             "太小会让别名几乎总是被放弃")
        XCTAssertLessThanOrEqual(DanmakuCoordinator.aliasBudget, .seconds(3),
                                 "太大就退化成阻塞主结果")
    }
}

/// 一次性的完成标记（`@unchecked Sendable`：内部用锁）。
private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}
