import CoreModel
import Foundation
import MetadataKit
@testable import OcPlayer
import XCTest

@MainActor
final class QueuedPlaybackProgressTests: XCTestCase {
    func testSnapshotWaitingForSetupKeepsNewerExplicitState() async throws {
        for played in [false, true] { try await exerciseQueue(waitForPrecedingWrite: false, played: played) }
    }

    func testSnapshotWaitingForPrecedingWriteKeepsNewSessionExplicitState() async throws {
        for played in [false, true] { try await exerciseQueue(waitForPrecedingWrite: true, played: played) }
    }

    private func exerciseQueue(waitForPrecedingWrite: Bool, played: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await Task.detached { try MetadataCache.open(at: directory) }.value
        let server = StubMediaServer(); let tenant = TenantID(profile: server.profile)
        let old = MediaItem(id: "queued", name: "Movie", kind: .movie,
                            playState: .init(played: !played, percentage: played ? 0 : 1, positionSeconds: 0))
        try await store.saveItems([old], tenant: tenant)
        let gate = QueuedPlaybackStoreGate(store: store)
        let coordinator = MetadataCoordinator(openStore: { _ in await gate.open() })
        coordinator.setup(directory: directory)
        coordinator.setActiveServer(server)
        if waitForPrecedingWrite {
            let first = MediaItem(id: "first", name: "First", kind: .movie)
            _ = coordinator.finishPlaybackProgress(item: first, positionSeconds: 21, durationSeconds: 100)
            coordinator.setActiveServer(StubMediaServer(profileID: server.profile.id))
        }
        let queued = coordinator.finishPlaybackProgress(item: old, positionSeconds: 42, durationSeconds: 100)
        // A newer session writes to the same tenant while the old final snapshot waits in the queue.
        let newerSession = MediaRepository(server: server, store: store)
        let marked = played ? try await newerSession.markPlayed(itemID: old.id)
            : try await newerSession.markUnplayed(itemID: old.id)
        await gate.release()
        await queued?.value
        let row = try await store.item(old.id, tenant: tenant)
        XCTAssertEqual(row?.item.playState?.played, marked.played)
        XCTAssertEqual(row?.item.playState?.positionSeconds, 0)
        if waitForPrecedingWrite {
            let first = try await store.item("first", tenant: tenant)
            XCTAssertEqual(first?.item.playState?.positionSeconds, 21)
        }
    }
}

private actor QueuedPlaybackStoreGate {
    let store: MetadataStore
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(store: MetadataStore) { self.store = store }
    func open() async -> MetadataStore {
        if !released { await withCheckedContinuation { continuation = $0 } }
        return store
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
