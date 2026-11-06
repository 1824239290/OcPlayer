import CoreModel
import Foundation
import MetadataKit
@testable import OcPlayer
import XCTest

/// 控制建库等待点，而非靠磁盘速度或 sleep 撞中竞态。
actor MetadataSetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func open(at directory: URL) async throws -> MetadataStore {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return try MetadataCache.open(at: directory)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class MetadataSessionConsistencyTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func coordinator(gate: MetadataSetupGate) -> MetadataCoordinator {
        let coordinator = MetadataCoordinator(openStore: { try await gate.open(at: $0) })
        coordinator.setup(directory: directory)
        return coordinator
    }

    func testConcurrentColdRepositoryUsesOneInstance() async throws {
        let gate = MetadataSetupGate()
        let coordinator = coordinator(gate: gate)
        let server = StubMediaServer()
        coordinator.setActiveServer(server)
        let started = expectation(description: "all callers entered the readiness wait")
        started.expectedFulfillmentCount = 16
        let tasks = (0..<16).map { _ in
            Task { @MainActor in
                started.fulfill()
                return await coordinator.currentRepository()
            }
        }
        await fulfillment(of: [started], timeout: 5)
        await gate.release()
        var repositories: [MediaRepository] = []
        for task in tasks {
            let result = await task.value
            repositories.append(try XCTUnwrap(result))
        }
        XCTAssertEqual(Set(repositories.map { ObjectIdentifier($0) }).count, 1)

    }

    private func verifyInvalidation(_ change: (MetadataCoordinator, StubMediaServer) -> Void) async throws {
        let gate = MetadataSetupGate()
        let coordinator = coordinator(gate: gate)
        let first = StubMediaServer(profileID: "a:user")
        coordinator.setActiveServer(first)
        let started = expectation(description: "old caller entered the readiness wait")
        let stale = Task { @MainActor in
            started.fulfill()
            return await coordinator.currentRepository()
        }
        await fulfillment(of: [started], timeout: 5)
        change(coordinator, first)
        await gate.release()
        let result = await stale.value
        XCTAssertNil(result, "失效的创建调用必须返回空，不能复活旧会话")
        XCTAssertNil(coordinator.repositoryIfReady)
    }

    func testSwitchDuringSetupRejectsOldCreation() async throws {
        try await verifyInvalidation { coordinator, _ in
            coordinator.setActiveServer(StubMediaServer(profileID: "b:user"))
        }
    }

    func testSignOutDuringSetupRejectsOldCreation() async throws {
        try await verifyInvalidation { coordinator, _ in coordinator.setActiveServer(nil) }
    }

    func testSwitchBackToSameInstanceStillRejectsOldGeneration() async throws {
        try await verifyInvalidation { coordinator, first in
            coordinator.setActiveServer(StubMediaServer(profileID: "b:user"))
            coordinator.setActiveServer(first)
        }
    }

    func testReauthenticationDuringSetupRejectsOldCreation() async throws {
        try await verifyInvalidation { coordinator, first in
            coordinator.setActiveServer(StubMediaServer(profileID: first.profile.id))
        }
    }
    func testFinalProgressDuringSetupKeepsOriginalTenantWithoutInstallingRepository() async throws {
        let gate = MetadataSetupGate()
        let coordinator = coordinator(gate: gate)
        let original = StubMediaServer(profileID: "a:user")
        coordinator.setActiveServer(original)
        let item = MediaItem(id: "shared", name: "original", kind: .movie)
        let finish = coordinator.finishPlaybackProgress(item: item, positionSeconds: 42, durationSeconds: 100)
        let next = StubMediaServer(profileID: "b:user")
        coordinator.setActiveServer(next)
        await gate.release()
        await finish?.value
        let store = try XCTUnwrap(coordinator.activeStore)
        let old = try await store.item("shared", tenant: TenantID(profile: original.profile))
        let new = try await store.item("shared", tenant: TenantID(profile: next.profile))
        XCTAssertEqual(old?.item.playState?.positionSeconds, 42)
        XCTAssertNil(new)
        XCTAssertNil(coordinator.repositoryIfReady)
    }

}
