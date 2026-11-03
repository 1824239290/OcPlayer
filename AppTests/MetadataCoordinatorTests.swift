import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// `MetadataCoordinator`：建库、会话仓储、体积上报、清空、淘汰。
///
/// 这一层是 App 与 `MetadataKit` 的接线：包内用例全绿，也可能因为这里没把
/// 服务器交给仓储而完全失效。
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

    // MARK: - 建库与会话

    func testSetupMakesStoreAvailable() async throws {
        let coordinator = try await makeReadyCoordinator()
        XCTAssertTrue(coordinator.isReady)
        XCTAssertNotNil(coordinator.activeStore)
        let noRepository = await coordinator.currentRepository()
        XCTAssertNil(noRepository, "没有活动服务器就没有仓储")
    }

    /// 未建库也能给仓储：退化为内存模式，读取协议不变。
    func testRepositoryWorksInMemoryModeWithoutSetup() async throws {
        let coordinator = MetadataCoordinator()
        let stub = StubMediaServer()
        stub.userViewsResult = .success([
            MediaLibrary(id: "lib", name: "库", collectionType: .movies)
        ])
        coordinator.setActiveServer(stub)

        let repository = await coordinator.currentRepository()
        XCTAssertNotNil(repository)
        let refreshed = await repository?.refreshHome()
        XCTAssertEqual(refreshed?.snapshot.value.libraries.map(\.id), ["lib"])
        XCTAssertFalse(coordinator.isReady)
    }

    /// 换服务器实例必须换仓储（旧实例的内存投影属于旧会话）。
    func testSwitchingServerReplacesRepository() async throws {
        let coordinator = try await makeReadyCoordinator()
        let first = StubMediaServer(profileID: "srv:user")
        coordinator.setActiveServer(first)
        let repoA = await coordinator.currentRepository()
        XCTAssertNotNil(repoA)

        let second = StubMediaServer(profileID: "srv:user")
        coordinator.setActiveServer(second)
        let repoB = await coordinator.currentRepository()
        XCTAssertNotNil(repoB)
        XCTAssertFalse(repoA === repoB, "新服务器实例对应新仓储")
    }

    // MARK: - 体积与清空

    func testRefreshSizeReportsNonZeroAfterWrites() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        stub.itemResult = .success(MediaItem(id: "i1", name: "条目", kind: .movie))
        coordinator.setActiveServer(stub)
        let created = await coordinator.currentRepository()
        let repository = try XCTUnwrap(created)
        _ = try await repository.refreshItem(itemID: "i1")
        // 走一次 WAL checkpoint 之外的体积统计：文件本身应已存在。
        coordinator.refreshSize()
        XCTAssertGreaterThan(coordinator.databaseBytes, 0)
    }

    /// 清空当前租户：磁盘与仓储内存一起清，不能只清一边。
    func testClearCurrentTenantEmptiesStoreAndMemory() async throws {
        let coordinator = try await makeReadyCoordinator()
        let stub = StubMediaServer()
        stub.itemResult = .success(MediaItem(id: "i1", name: "条目", kind: .movie))
        coordinator.setActiveServer(stub)
        let created = await coordinator.currentRepository()
        let repository = try XCTUnwrap(created)
        _ = try await repository.refreshItem(itemID: "i1")
        let beforeClear = await repository.cachedItem(itemID: "i1")
        XCTAssertNotNil(beforeClear)

        let cleared = await coordinator.clearCurrentTenant()
        XCTAssertTrue(cleared)
        let afterClear = await repository.cachedItem(itemID: "i1")
        XCTAssertNil(afterClear, "内存投影必须一起清")
        let store = try XCTUnwrap(coordinator.activeStore)
        let cached = try await store.item("i1", tenant: TenantID(profile: stub.profile))
        XCTAssertNil(cached, "磁盘条目必须清空")
    }

    // MARK: - 维护

    func testMaintenanceEvictsByCount() async throws {
        let coordinator = try await makeReadyCoordinator()
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: StubMediaServer().profile)
        try await store.saveItems(
            (0..<20).map { MediaItem(id: "i\($0)", name: "条目\($0)", kind: .movie) },
            tenant: tenant)
        let initialCount = try await store.itemCount()
        XCTAssertEqual(initialCount, 20)

        await coordinator.runMaintenance(maxItems: 5, maxBytes: .max)

        let remaining = try await store.itemCount()
        XCTAssertEqual(remaining, 5)
    }

    func testMaintenanceIsIdempotent() async throws {
        let coordinator = try await makeReadyCoordinator()
        let store = try XCTUnwrap(coordinator.activeStore)
        let tenant = TenantID(profile: StubMediaServer().profile)
        try await store.saveItems(
            (0..<4).map { MediaItem(id: "i\($0)", name: "条目\($0)", kind: .movie) },
            tenant: tenant)

        await coordinator.runMaintenance(maxItems: 100, maxBytes: .max)
        let first = try await store.itemCount()
        await coordinator.runMaintenance(maxItems: 100, maxBytes: .max)

        let second = try await store.itemCount()
        XCTAssertEqual(second, first)
    }

    /// 建库失败必须被暴露，而不是静默当成「没有缓存」。
    func testSetupFailureIsExposedNotFatal() async throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        let coordinator = MetadataCoordinator()
        coordinator.setup(directory: file)

        let ready = await coordinator.waitUntilReady()

        XCTAssertFalse(ready)
        XCTAssertNotNil(coordinator.setupError)
        XCTAssertFalse(coordinator.isReady)
    }
}
