import CoreModel
import Foundation
import JellyfinKit
import XCTest
@testable import MetadataKit

final class PlaybackProgressPersistenceTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws { directory = try TemporaryDirectory() }
    override func tearDown() { directory.cleanUp() }

    private func item(_ id: String = "item", name: String = "projection", played: Bool = false) -> MediaItem {
        MediaItem(id: id, name: name, kind: .movie,
                  playState: .init(played: played, percentage: played ? 1 : 0, positionSeconds: 0))
    }

    func testFinalProgressSurvivesShutdownWhileOldNetworkWritesStayBlocked() async throws {
        let store = try MetadataCache.open(at: directory.url)
        let server = StubMediaServer()
        let tenant = TenantID(profile: server.profile)
        let timestamp = Date(timeIntervalSince1970: 100)
        try await store.saveItems([item(name: "full metadata", played: true)], tenant: tenant, now: timestamp)
        let repository = MediaRepository(server: server, store: store)
        await repository.shutdown()
        await repository.recordFinalPlaybackProgress(item: item(), positionSeconds: 42, durationSeconds: 100)
        server.itemResult = .success(item(name: "stale network"))
        _ = try await repository.refreshItem(itemID: "item")
        let cached = try await store.item("item", tenant: tenant)
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 42)
        XCTAssertEqual(cached?.item.playState?.played, true, "普通进度写回不能取消已看标记")
        XCTAssertEqual(cached?.item.name, "full metadata")
        XCTAssertEqual(cached?.fetchedAt, timestamp)
    }

    func testFinalProgressSeedsMissingItem() async throws {
        let store = try MetadataCache.open(at: directory.url)
        let server = StubMediaServer()
        let repository = MediaRepository(server: server, store: store)
        await repository.recordFinalPlaybackProgress(item: item(), positionSeconds: 42, durationSeconds: 100)
        let cached = try await store.item("item", tenant: TenantID(profile: server.profile))
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 42)
        XCTAssertEqual(cached?.item.playState?.percentage, 0.42)
        XCTAssertEqual(cached?.item.name, "projection")
    }
}
