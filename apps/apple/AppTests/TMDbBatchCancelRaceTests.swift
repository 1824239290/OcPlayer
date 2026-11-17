import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 「取消补全 → 再补全」的状态机竞态复现（**临时证据用例**）。
///
/// 症状（iPhone 实测报障）：取消一次批量补全后，下一次补全会「多个补全一起在跑」。
///
/// ⚠️ 本用例**钉住的是当前（有缺陷的）行为**：它是复现证据，不是回归防线。
/// 修好之后这些断言应当**全部反过来**（第二次不再被放行、取消要真的停住、
/// 迟到的那次不得改写状态）——那时请把它改成对应的回归用例。
///
/// 复现手法不碰网络：用闸门把「枚举候选」这一步挂住，从而精确控制
/// 「第一次补全还活着」与「第二次补全还在跑」这两个时刻，再观察状态字段被谁改写。
/// 条目用 `.boxSet`：`enrichAll` 对非电影/剧只计数、不发请求，所以整条链路是纯状态机。
@MainActor
final class TMDbBatchCancelRaceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var gates: [AsyncGate] = []

    override func setUp() async throws {
        suiteName = "TMDbBatchCancelRaceTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TMDbBatchCancelRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        gates = []
    }

    override func tearDown() async throws {
        // 用例中途失败时闸门可能还关着：全部放开，别把挂起的任务留给下一个用例。
        gates.forEach { $0.open() }
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var tenant: TenantID { TenantID(rawValue: "srv:user") }

    private func makeGate() -> AsyncGate {
        let gate = AsyncGate()
        gates.append(gate)
        return gate
    }

    /// 轮询等待一个主线程状态条件成立（状态由 `MainActor.run` 写入，靠 `Task.sleep` 让出主线程）。
    private func waitUntil(_ label: String,
                           timeout: TimeInterval = 5,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("等待超时：\(label)")
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func makeCoordinator() throws -> TMDbCoordinator {
        let coordinator = TMDbCoordinator(defaults: defaults)
        coordinator.setAPIKey("0123456789abcdef0123456789abcdef")
        coordinator.attach(store: try MetadataCache.open(at: directory))
        return coordinator
    }

    /// 取消后的收尾会把「下一次补全」的状态一起复位，于是下一次补全能再被启动一次，
    /// 第二次与第三次同时挂着；而取消只能停掉最后那一次。
    func testRestartAfterCancelRunsTwoBatchesAtOnce() async throws {
        let coordinator = try makeCoordinator()
        let calls = CallCounter()
        let firstGate = makeGate()
        let secondGate = makeGate()
        let thirdGate = makeGate()

        // 三次补全的条目数不同（1 / 2 / 3），这样「最终结果是谁写的」可以靠 total 区分。
        func start(_ label: String, items: Int, gate: AsyncGate) {
            coordinator.startBatch(tenant: tenant) {
                calls.bump()
                await gate.wait()
                return (1...items).map {
                    MediaItem(id: "\(label)-\($0)", name: label, kind: .boxSet)
                }
            }
        }

        // ① 第一次补全：卡在枚举里（取消时它一定「还活着」）。
        start("b1", items: 1, gate: firstGate)
        XCTAssertTrue(coordinator.isBatching)

        // ② 用户点「取消补全」：状态**立刻**复位，UI 又把「补全整个媒体库」摆出来。
        coordinator.cancelBatch()
        XCTAssertFalse(coordinator.isBatching, "取消后状态立刻复位（UI 恢复可点）")

        // ③ 用户随即再点一次：第二次补全开始，同样卡在枚举里。
        start("b2", items: 2, gate: secondGate)
        XCTAssertTrue(coordinator.isBatching, "第二次补全已开始")
        await waitUntil("第二次枚举开始") { calls.calls >= 2 }

        // ④ 放行第一次的枚举。它已收到取消，`enrichAll` 会在循环开头 break，
        //    但随后仍然执行「完成」回调——而那一段**不认领自己属于哪一次运行**。
        firstGate.open()
        await waitUntil("第一次的完成回调落定") { coordinator.lastBatchResult != nil }

        // ⑤ 复现：第二次补全仍在跑（它的枚举还挂着），状态却被第一次的收尾改写了。
        XCTAssertFalse(coordinator.isBatching,
                       "复现：第二次补全仍在进行，isBatching 却被上一次的收尾写成 false")
        XCTAssertEqual(coordinator.lastBatchResult?.total, 1,
                       "复现：上一次（已取消）的结果被写进 lastBatchResult")
        XCTAssertEqual(coordinator.lastBatchResult?.wasCancelled, true)
        XCTAssertEqual(coordinator.batchProgress?.total, 1,
                       "复现：进度条也被上一次的收尾改写（现在是「已取消那次」的进度）")

        // ⑥ 于是 `startBatch` 的 `!isBatching` 守卫形同虚设：再点一次就又多一个并发补全。
        start("b3", items: 3, gate: thirdGate)
        await waitUntil("第三次枚举开始") { calls.calls >= 3 }
        XCTAssertEqual(calls.calls, 3, "复现：第三次补全被放行，三个补全同时在跑")
        XCTAssertTrue(coordinator.isBatching)

        // ⑦ 取消只能停掉 `batchTask` 里记着的那一个（第三次）；第二次已失去句柄。
        coordinator.cancelBatch()

        // 只放行第二次：它若真收到取消，`enrichAll` 会在循环开头 break
        // （processed 停在 0、wasCancelled = true）；跑完 2 条则说明**根本没收到取消**。
        secondGate.open()
        await waitUntil("第二次跑完") { coordinator.lastBatchResult?.total == 2 }
        XCTAssertEqual(coordinator.lastBatchResult?.processed, 2,
                       "复现：第二次补全没收到取消，取消之后仍然把 2 条全跑完了")
        XCTAssertEqual(coordinator.lastBatchResult?.wasCancelled, false,
                       "复现：第二次补全自认为从未被取消")
    }

    /// 另一半窗口：取消发生在**枚举候选**那一步。
    ///
    /// `tmdbBatchCandidates()` 是 `(try? await server.items(...)) ?? []`——请求被取消后
    /// 拿到的是**空数组**（设备日志里那行 `请求被取消（任务取消，非故障）GET /Items`
    /// 就是这个事件），于是走的是「空列表」分支：它同样把 `isBatching` 写回 false，
    /// 还会给正在跑的那次补全扣上一句「没有找到可补全的电影或剧集」。
    func testCancelDuringEnumeratePoisonsNextRun() async throws {
        let coordinator = try makeCoordinator()
        let calls = CallCounter()
        let firstGate = makeGate()
        let secondGate = makeGate()

        coordinator.startBatch(tenant: tenant) {
            calls.bump()
            await firstGate.wait()
            return []   // 被取消的枚举：请求抛错 → try? → 空数组
        }
        coordinator.cancelBatch()

        coordinator.startBatch(tenant: tenant) {
            calls.bump()
            await secondGate.wait()
            return (1...2).map { MediaItem(id: "b2-\($0)", name: "b2", kind: .boxSet) }
        }
        await waitUntil("第二次枚举开始") { calls.calls >= 2 }

        firstGate.open()
        await waitUntil("第一次的空列表分支落定") { coordinator.batchError != nil }

        XCTAssertFalse(coordinator.isBatching,
                       "复现：第二次补全仍在跑，isBatching 却被上一次的空列表分支写成 false")
        XCTAssertEqual(coordinator.batchError, "没有找到可补全的电影或剧集",
                       "复现：正在跑的那次补全被扣上一句不属于它的错误")

        secondGate.open()
        await waitUntil("第二次跑完") { coordinator.lastBatchResult?.total == 2 }
        XCTAssertEqual(coordinator.lastBatchResult?.processed, 2,
                       "复现：第二次补全照常跑完")
    }
}

// MARK: - 测试替身

/// 可控闸门：`wait()` 挂起到 `open()`；已 open 过则立刻返回。
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// 枚举调用计数（闭包是 `@Sendable`，用锁而非 actor）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
