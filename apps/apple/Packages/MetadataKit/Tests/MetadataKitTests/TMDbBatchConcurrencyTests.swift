import CoreModel
import Foundation
import XCTest
@testable import MetadataKit

/// `P1-06`：批量补全必须**并发**跑（原实现完全串行，`TMDbRateLimiter` 的
/// `maxConcurrent: 4` 从来没被用上）。
///
/// ## 为什么这是真问题
///
/// 串行时吞吐 = `1 / max(单次延迟, minimumInterval)`。生产限流器是
/// `maxConcurrent: 4, minimumInterval: 0.12`（全局 8.3 req/s 上限）：
///
/// | 单次延迟 | 串行吞吐 | 占上限 |
/// |---|---|---|
/// | ≤120 ms | 8.3 req/s | 100%（并发无收益 ← 原判「不值得改」的依据） |
/// | 200 ms | 4.8 req/s | **58%** |
/// | 300 ms | 3.2 req/s | **38%** |
/// | 500 ms | 1.9 req/s | **23%** |
///
/// `api.themoviedb.org` 在国内 / 移动网络下 200–400 ms 是常态 ——
/// 一旦超过 120 ms 那根线，串行就是在白等。
///
/// ## 这组用例为什么用「在飞峰值」而不是耗时
///
/// 耗时断言在 CI 上已被咬过三次（`P2-33`、`P1-06` 同批的 `bodyLimit`、`P2-32`）。
/// **在飞峰值是确定性的**：串行实现下它恒为 1；并发实现下只要「单次延迟 >
/// 两次派发的间隔」就必然 > 1。断言不依赖机器快慢。
final class TMDbBatchConcurrencyTests: XCTestCase {

    private var dir: TemporaryDirectory!
    private var store: MetadataStore!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        store = MetadataStore(database: try MetadataDatabaseFactory.makeDatabase(at: dir.url))
        ConcurrencyProbeProtocol.reset()
    }

    override func tearDown() {
        ConcurrencyProbeProtocol.reset()
        dir?.cleanUp()
        super.tearDown()
    }

    private var tenant: TenantID { TenantID(rawValue: "srv:user") }

    /// 生产配置的限流器（4 / 0.12），但间隔调小让用例快。
    private func makeEnricher(latency: TimeInterval, interval: TimeInterval) -> TMDbEnricher {
        ConcurrencyProbeProtocol.latency = latency
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConcurrencyProbeProtocol.self]
        let defaults = UserDefaults(suiteName: "TMDbBatchConcurrency-\(UUID().uuidString)")!
        let client = TMDbClient(
            session: URLSession(configuration: config),
            credentials: ConcurrencyProbeCredential(),
            limiter: TMDbRateLimiter(maxConcurrent: 4, minimumInterval: interval))
        return TMDbEnricher(client: client, store: store,
                            preferences: TMDbPreferences(defaults: defaults))
    }

    private func movies(_ count: Int) -> [MediaItem] {
        (0..<count).map { MediaItem(id: "c\($0)", name: "片\($0)", kind: .movie) }
    }

    /// **核心判据：确实有多个请求同时在飞。**
    ///
    /// 串行实现下 `peak` 恒为 1 → 这条红。
    func testEnrichAllIssuesConcurrentRequests() async throws {
        // 延迟 300 ms ≫ 派发间隔 50 ms：并发下峰值必然 > 1，且留足调度余量。
        let enricher = makeEnricher(latency: 0.3, interval: 0.05)
        let items = movies(6)
        let result = await enricher.enrichAll(items: items, tenant: tenant)

        XCTAssertEqual(result.processed, 6, "6 条都要处理完")
        XCTAssertGreaterThanOrEqual(
            ConcurrencyProbeProtocol.peak, 2,
            "在飞峰值只到 \(ConcurrencyProbeProtocol.peak) —— 说明批量补全仍在串行跑"
                + "（限流器给了 4 个名额，一个都没用上）")
    }

    /// **窗口宽度必须 ≤ 并发上限**（无界派发 → 红）。
    ///
    /// ## 为什么不能只看 HTTP 在飞峰值（审查 S3 实测指出）
    ///
    /// 我第一版写的是「HTTP 在飞峰值 ≤ 4」。但 `TMDbRateLimiter` **自己**就会把
    /// 并发压在 4 —— 所以把 `width` 改成 `items.count`（无界派发）后那个峰值
    /// **仍然是 4**，用例看不出来。
    ///
    /// 这条改成数**同时存活的 `contribution` 个数**（`workerObserver` 接缝）：
    /// 窗口填充下它恒 ≤ 4；无界派发时会一路涨到 `items.count`。
    func testWorkerWindowNeverExceedsConcurrencyLimit() async throws {
        // 用**立即返回**的桩把窗口撑满：派发速度 ≫ 完成速度时才看得出窗口宽度。
        let enricher = makeEnricher(latency: 0.001, interval: 0)
        let items = movies(20)

        let seen = AliveRecorder()
        TMDbEnricher.workerObserver = { alive in seen.record(alive) }
        defer { TMDbEnricher.workerObserver = nil }

        _ = await enricher.enrichAll(items: items, tenant: tenant)

        XCTAssertGreaterThanOrEqual(seen.peak, 2, "峰值 \(seen.peak)：根本没并发")
        XCTAssertLessThanOrEqual(
            seen.peak, TMDbEnricher.enrichmentConcurrency,
            "同时存活的 worker 峰值 \(seen.peak) 超过上限 "
                + "\(TMDbEnricher.enrichmentConcurrency) —— 说明是无界派发")
        XCTAssertEqual(seen.lastAlive, 0, "收尾后存活的 worker 应归零，实际 \(seen.lastAlive)")
    }

    /// **`processed` 必须按 `Contribution` 聚合，不能被硬编码成 1**（审查 S2）。
    ///
    /// 若写成 `result.processed += 1`，**非视频条目会被重复计入**
    /// （它们的 `Contribution.processed` 已经是 1，而取消时是 0）。
    /// 这条用一个「预取消」的场景：先取消再跑，worker 全部提前返回 `processed=0`，
    /// 于是正确的聚合结果是 **0**，而硬编码成 1 会得到 `items.count`。
    func testProcessedAggregatesContributionNotHardcoded() async throws {
        let enricher = makeEnricher(latency: 0.01, interval: 0.001)
        let items = movies(6)
        let tenantID = tenant
        // 先取消当前任务，再调 enrichAll：每个 worker 首行 `guard !Task.isCancelled`
        // 就会返回 `processed == 0`。
        let task = Task { () -> TMDbBatchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await enricher.enrichAll(items: items, tenant: tenantID)
        }
        let result = await task.value
        XCTAssertEqual(
            result.processed, 0,
            "预取消时每个 worker 的 Contribution.processed 都是 0，"
                + "聚合结果必须是 0；得到 \(result.processed) 说明把计数硬编码了")
    }

    /// 并发化不能改变**结果计数**（每条独立处理、失败只计数）。
    func testConcurrentRunKeepsResultCounts() async throws {
        let enricher = makeEnricher(latency: 0.02, interval: 0.01)
        let items = movies(9)
        let result = await enricher.enrichAll(items: items, tenant: tenant)
        XCTAssertEqual(result.processed, 9)
        XCTAssertEqual(result.total, 9)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertEqual(
            result.skipped + result.enriched + result.unmatched + result.failed, 9,
            "四个计数之和应等于总条数（每条只归一类）")
    }

    /// 非电影/剧类型的条目仍被计入 `processed`（不因并发漏计）。
    func testNonVideoKindsStillCounted() async throws {
        let enricher = makeEnricher(latency: 0.01, interval: 0.005)
        let items = [
            MediaItem(id: "b1", name: "合集", kind: .boxSet),
            MediaItem(id: "m1", name: "片", kind: .movie),
            MediaItem(id: "b2", name: "合集2", kind: .boxSet),
        ]
        let result = await enricher.enrichAll(items: items, tenant: tenant)
        XCTAssertEqual(result.processed, 3)
    }

    /// **取消后不得再派发新任务，且不得让窗口无限期把整批跑完**（审查 S2）。
    ///
    /// ## 这条为什么这么写（实测过一次弯路）
    ///
    /// 我第一版想断言「`group.cancelAll()` 让已派发的 4 个任务立刻抛错 → `processed ≈ 0`」。
    /// **实测是 `processed == 4`** —— 因为取消只对**协作检查点**生效：
    /// `contribution` 里的 `guard !Task.isCancelled` 在**进入时**检查一次，
    /// 之后 `performRefresh` → `URLSession.data(for:)` 并不保证中途响应取消。
    /// 所以那 4 个在飞任务会跑完，`processed == 4 == width`。
    ///
    /// 也就是说 `group.cancelAll()` 的真实作用是「**不再派发**」，而不是「掐断在飞」。
    /// 这条用例就守这个真实契约：**已处理条数必须 ≈ 窗口宽度，远小于总数**。
    /// 40 条里只处理 ≤ width 条，说明取消后确实没继续派发。
    ///
    /// 去掉 `group.cancelAll()` 后：`for await` 每收到一个就检查 `Task.isCancelled`
    /// 并置 `wasCancelled`，**但不会停止后续 dispatch** —— 因为原逻辑里
    /// `else if nextIndex < items.count { dispatch() }` 在取消分支之外。
    /// 于是它会一路派发到 40 条全部跑完，`processed` 会到 40。
    func testCancelStopsFurtherDispatch() async throws {
        let enricher = makeEnricher(latency: 0.15, interval: 0.01)
        let items = movies(40)
        let tenantID = tenant
        let task = Task { await enricher.enrichAll(items: items, tenant: tenantID) }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThanOrEqual(
            result.processed, TMDbEnricher.enrichmentConcurrency * 2,
            "取消后仍处理了 \(result.processed)/40 条 —— 说明取消后还在继续派发"
                + "（窗口宽度 \(TMDbEnricher.enrichmentConcurrency)，应止于窗口量级）")
    }

    /// 取消仍能生效（并发后不能变成「必须等全部跑完才能取消」）。
    func testCancellationStillWorks() async throws {
        let enricher = makeEnricher(latency: 0.05, interval: 0.01)
        let items = movies(40)
        let tenantID = tenant
        let task = Task { await enricher.enrichAll(items: items, tenant: tenantID) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.wasCancelled, "取消后应标记 wasCancelled")
        XCTAssertLessThan(result.processed, 40, "应中途停下，不该跑完 40 条")
    }
}

/// 非阻塞延迟的 stub：用 `asyncAfter` 而不是 `usleep`。
///
/// ⚠️ 这里踩过一次坑：第一版用 `usleep` 模拟延迟，结果把 `URLProtocol` 的队列堵住，
/// **并发实现也测出「串行」的数字**（4.8 req/s，与串行一致）。非阻塞延迟才测得准。
final class ConcurrencyProbeProtocol: URLProtocol {
    nonisolated(unsafe) static var latency: TimeInterval = 0.2
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var peakValue = 0
    nonisolated(unsafe) private static var startedValue = 0
    nonisolated(unsafe) private static let counterLock = NSLock()

    /// 桩被请求的总次数（判断「取消后还有没有继续派发」）。
    static var started: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return startedValue
    }

    static var startedCount: Int { started }

    static func resetStarted() {
        counterLock.lock(); startedValue = 0; counterLock.unlock()
    }

    static var peak: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return peakValue
    }

    static func reset() {
        counterLock.lock(); inFlight = 0; peakValue = 0; startedValue = 0; counterLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counterLock.lock()
        Self.inFlight += 1
        Self.startedValue += 1
        Self.peakValue = max(Self.peakValue, Self.inFlight)
        Self.counterLock.unlock()

        let url = request.url!
        let delay = Self.latency
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            Self.counterLock.lock(); Self.inFlight -= 1; Self.counterLock.unlock()
            // 404 → 快速走完一条（`noMatch`），不触发季请求，用例更快。
            let response = HTTPURLResponse(
                url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data())
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private struct ConcurrencyProbeCredential: TMDbCredentialProviding {
    func apiKey() -> String? { "0123456789abcdef0123456789abcdef" }
}

/// 记录 `workerObserver` 报的存活数（闭包是 `@Sendable`，用锁保护）。
final class AliveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ alive: Int) {
        lock.lock(); values.append(alive); lock.unlock()
    }

    var peak: Int {
        lock.lock(); defer { lock.unlock() }
        return values.max() ?? 0
    }

    var lastAlive: Int {
        lock.lock(); defer { lock.unlock() }
        return values.last ?? 0
    }
}
