import DanmakuKit
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
        // 判据用**比值**而不是固定毫秒：work 要 1000ms，若实现是「等它跑完再丢弃」
        // 必然 ≥1000ms；超时正确则 ≈预算（50ms）。取 1/4 留足 CI 抖动余量。
        XCTAssertLessThan(elapsedMs, 250,
                          "耗时 \(Int(elapsedMs)) ms —— 说明它在等 1000ms 的慢任务跑完，"
                              + "而不是超时就返回")
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

        // 等它自己跑完。窗口给足（work 120ms → 等 1000ms，余量 8x）：
        // 慢 runner 上短窗口会先红（上一批已踩过机器相关性）。
        for _ in 0..<50 where !box.isDone {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(box.isDone, "被放弃等待的工作必须仍能自然完成（没被取消）")
    }

    /// **别名链「命中即停」契约**（审查指出我原文件头声称测了、实际零覆盖）。
    func testFirstNonEmptyAliasResultStopsAtFirstHit() async {
        let tried = TriedAliases()
        let result = await DanmakuCoordinator.firstNonEmptyAliasResult(
            aliases: { _ in ["a", "b", "c"] },
            search: { alias in
                tried.record(alias)
                guard alias == "b" else { return [] }
                let data = Data(animeJSON(id: 7).utf8)
                return (try? JSONDecoder().decode(AnimeWithEpisodes.self, from: data)).map { [$0] }
            },
            anime: "anime")
        XCTAssertEqual(result?.map(\.animeId), [7], "应返回第一个命中的别名结果")
        XCTAssertEqual(tried.values, ["a", "b"], "命中后必须停（不该再试 c）")
    }

    /// 同名别名要跳过（`aliases(for:)` 会把自己也返回，那是浪费一次请求）。
    func testFirstNonEmptyAliasResultSkipsTheOriginalTitle() async {
        let tried = TriedAliases()
        _ = await DanmakuCoordinator.firstNonEmptyAliasResult(
            aliases: { _ in ["anime", "other"] },
            search: { alias in
                tried.record(alias)
                return []
            },
            anime: "anime")
        XCTAssertEqual(tried.values, ["other"], "与作品名同名的别名不该被检索")
    }

    /// 全部别名都没结果 → nil。
    func testFirstNonEmptyAliasResultReturnsNilWhenNothingHits() async {
        let result = await DanmakuCoordinator.firstNonEmptyAliasResult(
            aliases: { _ in ["a", "b"] },
            search: { _ in [] },
            anime: "anime")
        XCTAssertNil(result)
    }

    /// **被取消时提前退出**（主检索失败时会 cancel 这个任务，别让它跑满网关超时）。
    func testFirstNonEmptyAliasResultStopsWhenCancelled() async {
        let tried = TriedAliases()
        let task = Task {
            await DanmakuCoordinator.firstNonEmptyAliasResult(
                aliases: { _ in ["a", "b", "c", "d"] },
                search: { alias in
                    tried.record(alias)
                    return []
                },
                anime: "anime")
        }
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(tried.values.count, 4,
                          "已取消却把所有别名都试完了：\(tried.values)")
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


/// `AnimeWithEpisodes` 只有 `Decodable`、没有 memberwise init，所以用 JSON 造。
private func animeJSON(id: Int) -> String {
    #"{"animeId":\#(id),"animeTitle":"t","type":"tvseries","typeDescription":"TV","episodes":[]}"#
}

/// 记录试过哪些别名（`@unchecked Sendable`：内部用锁）。
private final class TriedAliases: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ alias: String) {
        lock.lock()
        storage.append(alias)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
