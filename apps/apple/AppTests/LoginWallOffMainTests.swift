import AppDesignKit
import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
import XCTest

@testable import OcPlayer

/// **`resolvePosters` 必须真的不在主线程上跑。**
///
/// ## 为什么要有这条
///
/// 「`nonisolated async` 会离开主线程」在本工程成立，但那是**编译设置**的产物，
/// 不是 Swift 语法保证。独立审查实测：
///
/// ```
/// 当前设置                                   → pthread_main_np = 0（离开主线程）
/// -enable-upcoming-feature NonisolatedNonsendingByDefault → = 1（跑回主 actor）
/// -enable-upcoming-feature ApproachableConcurrency        → = 1
/// ```
///
/// 开关一旦被打开，P1-09 的全部收益（5 760 次 × 21.74 µs）会静默还回去，而别的
/// 用例一条都不会红。所以这里用**主线程心跳计数**把这个前提钉住。
///
/// ## 判据为什么用心跳而不是直接读线程
///
/// Swift 6 在 async 上下文里禁用 `Thread.isMainThread`；而 `pthread_main_np()` 只能
/// 证明「某个瞬间」不在主线程，证明不了「整段工作都不在主线程」。心跳法是行为判据：
/// 另一个任务在主 actor 上每 1 ms 跳一次，若 `resolvePosters` 占住主线程，心跳数
/// 会接近 0。
final class LoginWallOffMainTests: XCTestCase {

    /// 心跳计数器（`@MainActor` 隔离，`@unchecked Sendable` 只为了让任务闭包能捕获）。
    @MainActor
    private final class Ticker {
        var ticks = 0
        var stop = false
    }

    @MainActor
    func testResolvePostersDoesNotBlockMainThread() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offmain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pipeline = ImagePipeline(cacheDirectory: dir, protocolClasses: [])
        let profile = ServerProfile(
            id: "srv:user", serverName: "offmain",
            baseURL: URL(string: "https://media.example.com")!, userID: "user")
        // 21 个身份 × 3 档 = 63 次/候选；800 候选 ≈ 50 400 次判定 ≈ 1 s 量级。
        let identities: [String] = (0..<21).map { index in
            "id" + String(repeating: "0", count: 9) + "\(index)"
        }
        var candidates: [CachedItem] = []
        candidates.reserveCapacity(800)
        for index in 0..<800 {
            let item = MediaItem(
                id: "item\(index)", name: "Item \(index)", kind: .movie,
                primaryImageTag: "tag\(index)")
            candidates.append(CachedItem(item: item, fetchedAt: Date(), progressFetchedAt: nil))
        }

        let ticker = Ticker()
        let heartbeat = Task { @MainActor in
            while !ticker.stop {
                ticker.ticks += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        // 让心跳先跑起来，量出「纯心跳」的基线速率。
        try await Task.sleep(for: .milliseconds(50))
        let baselineTicks = ticker.ticks
        XCTAssertGreaterThan(baselineTicks, 0, "心跳任务没跑起来，判据无效")

        let started = CFAbsoluteTimeGetCurrent()
        _ = await LoginWallCatalogLoader.resolvePosters(
            candidates: candidates, profile: profile, identities: identities,
            pipeline: pipeline, limit: 800)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        ticker.stop = true
        _ = await heartbeat.value
        let ticksDuring = ticker.ticks - baselineTicks

        // 工作必须够久，这条判据才有意义（否则一次调度空隙都能通过）。
        try XCTSkipIf(elapsed < 0.15, "工作面太小（\(elapsed)s），心跳判据不可靠")

        // 若在主线程同步执行，整段期间主 actor 被占住，心跳数会是 0（或个位数）。
        // 实测（不在主线程时）：1.18 s 工作里有 188 次心跳。
        XCTAssertGreaterThan(
            ticksDuring, 3,
            "resolvePosters 占住了主线程：\(String(format: "%.2f", elapsed)) s 工作期间"
                + "主线程只跳了 \(ticksDuring) 次。"
                + "很可能是编译设置变化（打开 NonisolatedNonsendingByDefault /"
                + " ApproachableConcurrency）让它跑回了主 actor。")
    }
}
