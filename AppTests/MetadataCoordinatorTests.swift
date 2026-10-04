import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// `MetadataCoordinator`：建库、包装降级、体积上报、清空、淘汰。
///
/// 这一层是 App 与 `MetadataKit` 的接线，**没测就等于没接**：包内 50 个用例
/// 全绿也可能因为这里少调一次 `wrap` 而完全失效。
@MainActor
final class MetadataCoordinatorTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeReadyCoordinator() async throws -> MetadataCoordinator {
        let coordinator = MetadataCoordinator()
        coordinator.setup(directory: directory)
        let ok = await coordinator.waitUntilReady()
        XCTAssertTrue(ok, "临时目录建库应成功")
        XCTAssertNil(coordinator.setupError)
        return coordinator
    }

    // MARK: - 建库

    /// 建库后应就绪、能给出存储句柄与离线读句柄。
    func testSetupMakesStoreAndHydratorAvailable() async throws {
        let coordinator = try await makeReadyCoordinator()
        XCTAssertTrue(coordinator.isReady)
        XCTAssertNotNil(coordinator.activeStore)

        let stub = StubMediaServer()
        XCTAssertNotNil(coordinator.hydrator(for: stub), "就绪后应能取到离线读句柄")
    }

    /// **未建库时必须降级为直通**：缓存是可选增强，不该因为建库失败就整个 App 不能用
    /// （磁盘满 / 权限异常都可能建库失败）。
    func testWrapFallsBackToRawServerBeforeSetup() async {
        let coordinator = MetadataCoordinator()
        let stub = StubMediaServer()
        let wrapped = await coordinator.wrap(stub)

        XCTAssertFalse(coordinator.isReady)
        XCTAssertNil(coordinator.hydrator(for: stub), "没就绪就没有离线读")
        // 直通：拿回来的就是原来那个对象（不是装饰器）。
        XCTAssertTrue((wrapped as AnyObject) === stub, "未就绪必须原样返回内层服务器")
    }

    /// 就绪后 `wrap` 必须真的包上装饰器（包装漏了 = 一条都不落盘）。
    func testWrapReturnsDecoratorWhenReady() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        let wrapped = await coordinator.wrap(stub)

        XCTAssertTrue(wrapped is CachedMediaServer, "就绪后应返回写穿装饰器")
        // 包了之后仍然透传档案（地址决议器等读的是它）。
        XCTAssertEqual(wrapped.profile.id, stub.profile.id)
        // 全字段转发：链路上的请求照样打到底层。
        stub.itemResult = .success(MediaItem(id: "m1", name: "电影", kind: .movie))
        _ = try await wrapped.item("m1")
        XCTAssertEqual(stub.callCount("item"), 1)
    }

    // MARK: - 体积

    /// 写入后体积统计必须 > 0（含 WAL）——设置页那一行显示的就是它。
    func testRefreshSizeReportsNonZeroAfterWrites() async throws {
        let coordinator = try await makeReadyCoordinator()
        let store = try XCTUnwrap(coordinator.activeStore)
        try await store.saveItems([MediaItem(id: "m1", name: "电影", kind: .movie)],
                                  tenant: TenantID(rawValue: "srv:user"))
        coordinator.refreshSize()
        XCTAssertGreaterThan(coordinator.databaseBytes, 0, "体积统计要含 WAL，不能报 0")
    }

    // MARK: - 清空

    /// 清空当前租户：内容消失、体积回落到「至少不再是原值」。
    func testClearCurrentTenantEmptiesCache() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        // 先经 wrap 认租（tenant 由档案派生）。
        _ = await coordinator.wrap(stub)
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: stub.profile)
        try await store.saveItems([MediaItem(id: "m1", name: "电影", kind: .movie)], tenant: tenant)
        let before = try await store.itemCount(tenant: tenant)
        XCTAssertEqual(before, 1)

        let cleared = await coordinator.clearCurrentTenant()
        XCTAssertTrue(cleared)
        let after = try await store.itemCount(tenant: tenant)
        XCTAssertEqual(after, 0)
    }

    // MARK: - 淘汰

    /// 维护在「远未到上限」时是空操作，但不该报错、也不该删东西。
    func testMaintenanceIsNoOpUnderLimits() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        _ = await coordinator.wrap(stub)
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: stub.profile)
        try await store.saveItems([
            MediaItem(id: "a", name: "A", kind: .movie),
            MediaItem(id: "b", name: "B", kind: .movie),
        ], tenant: tenant)

        await coordinator.runMaintenance()

        let count = try await store.itemCount()
        XCTAssertEqual(count, 2, "未超上限不该删任何东西")
    }

    /// 维护可重复调用（每日定时器会反复打进来）。
    func testMaintenanceIsIdempotent() async throws {
        let coordinator = try await makeReadyCoordinator()
        await coordinator.runMaintenance()
        await coordinator.runMaintenance()
        XCTAssertTrue(coordinator.isReady, "重复维护不该把协调器搞坏")
    }

    /// **条数上限**独立生效：删最旧的，留最新的。
    func testMaintenanceEvictsByCount() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        _ = await coordinator.wrap(stub)
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: stub.profile)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, id) in ["oldest", "middle", "newest"].enumerated() {
            try await store.saveItems([MediaItem(id: id, name: id, kind: .movie)],
                                      tenant: tenant,
                                      now: base.addingTimeInterval(TimeInterval(offset)))
        }

        // 用极小上限触发（真实上限 3 万条，用例不可能真写到那个量级）。
        await coordinator.runMaintenance(maxItems: 1, maxBytes: .max)

        let count = try await store.itemCount()
        XCTAssertEqual(count, 1)
        let newest = try await store.item("newest", tenant: tenant)
        let oldest = try await store.item("oldest", tenant: tenant)
        XCTAssertNotNil(newest, "最新的要留下")
        XCTAssertNil(oldest, "最旧的先走")
    }

    /// **体积上限独立生效**——这是曾经写错的一处。
    ///
    /// 旧实现是「体积超了就删到条数上限的 90%」：实测每条约 1 KB，3 万条的条数
    /// 上限折合才 ≈30 MB，**永远先于 200 MB 触发**，于是体积那一道在条数未超限时
    /// 恒为空操作（上限形同虚设）。现在按「当前条数的 10%」删，与条数解耦。
    /// 本用例把体积上限压到 1 字节，验证它在**条数远未超限**时也会真的删。
    func testMaintenanceEvictsByBytesEvenUnderCountLimit() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        _ = await coordinator.wrap(stub)
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: stub.profile)
        try await store.saveItems((0..<10).map { MediaItem(id: "i\($0)", name: "条目\($0)", kind: .movie) },
                                  tenant: tenant)

        // 条数上限给得很宽（100），体积上限压到 1 字节 → 只有体积那一道能动。
        await coordinator.runMaintenance(maxItems: 100, maxBytes: 1)

        let count = try await store.itemCount()
        XCTAssertLessThan(count, 10, "体积超限必须真的删东西，而不是空操作")
        XCTAssertEqual(count, 9, "按当前条数的 10% 删：10 条删 1 条")
    }

    /// 两条上限都没超 = 一条都不删（每日空跑不该消耗数据）。
    func testMaintenanceKeepsEverythingWhenBothLimitsAreFine() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        _ = await coordinator.wrap(stub)
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: stub.profile)
        try await store.saveItems((0..<5).map { MediaItem(id: "i\($0)", name: "条目\($0)", kind: .movie) },
                                  tenant: tenant)

        await coordinator.runMaintenance(maxItems: 100, maxBytes: .max)

        let count = try await store.itemCount()
        XCTAssertEqual(count, 5)
    }

    // MARK: - 建库失败

    /// 目录指向一个**普通文件**时建库必败：必须暴露错误态、且**不崩**。
    func testSetupFailureIsExposedNotFatal() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-blocker-\(UUID().uuidString)")
        try Data("block".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let coordinator = MetadataCoordinator()
        coordinator.setup(directory: blocker)
        let ok = await coordinator.waitUntilReady()

        XCTAssertFalse(ok)
        XCTAssertFalse(coordinator.isReady)
        XCTAssertNotNil(coordinator.setupError, "失败必须暴露原因供设置页/诊断展示")
        XCTAssertNil(coordinator.activeStore)

        // 降级路径仍然可用：直通、不崩。
        let stub = StubMediaServer()
        let wrapped = await coordinator.wrap(stub)
        XCTAssertTrue((wrapped as AnyObject) === stub)
    }
}
