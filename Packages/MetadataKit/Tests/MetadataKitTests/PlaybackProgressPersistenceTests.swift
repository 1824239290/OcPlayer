import CoreModel
import Foundation
import GRDB
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

    func testDiskHomeAndPagesMergeProgressWithoutReplacingProjectionMetadata() async throws {
        let store = try MetadataCache.open(at: directory.url)
        let server = StubMediaServer()
        let tenant = TenantID(profile: server.profile)
        let timestamp = Date(timeIntervalSince1970: 100)
        let original = item()
        let descriptor = MediaPageDescriptor(parentID: "lib")
        let key = descriptor.key(startIndex: 0, limit: 100)
        try await store.saveItems([original], tenant: tenant, now: timestamp)
        try await store.saveRail([original], rail: "resume", tenant: tenant, now: timestamp)
        try await store.saveRail([original], rail: "latest", tenant: tenant, now: timestamp)
        try await store.savePage(MediaItemsPage(items: [original], startIndex: 0, totalRecordCount: 1),
                                 key: key, tenant: tenant, now: timestamp)
        let progress = MediaItem.PlayState(played: false, percentage: 0.42, positionSeconds: 42)
        try await store.updatePlayState(progress, forItemID: "item", tenant: tenant)
        let repository = MediaRepository(server: server, store: store)
        let cachedItem = await repository.cachedItem(itemID: "item")
        let home = await repository.cachedHome()
        let page = await repository.cachedPage(descriptor, limit: 100)
        let itemAfterProjections = await repository.cachedItem(itemID: "item")
        let singleRail = try await store.rail("resume", tenant: tenant)
        let singlePage = try await store.page(key, tenant: tenant)
        XCTAssertEqual(cachedItem?.value.playState, progress)
        XCTAssertEqual(home?.value.resume.first?.playState, progress)
        XCTAssertEqual(home?.value.latest.first?.playState, progress)
        XCTAssertEqual(page?.value.items.first?.playState, progress)
        XCTAssertEqual(itemAfterProjections?.value.playState, progress, "rememberItems 不能把进度改旧")
        XCTAssertEqual(singleRail?.items.first?.playState, progress)
        XCTAssertEqual(singlePage?.items.first?.playState, progress)
        XCTAssertEqual(singleRail?.fetchedAt, timestamp)
        XCTAssertEqual(singlePage?.fetchedAt, timestamp)
        XCTAssertEqual(page?.value.totalCount, 1)
        XCTAssertEqual(page?.value.nextStartIndex, 1)
    }

    func testProjectionKeepsItsMetadataAndFallsBackForMissingCanonicalItems() async throws {
        let store = try MetadataCache.open(at: directory.url)
        let server = StubMediaServer()
        let tenant = TenantID(profile: server.profile)
        let projection = [item("missing"), item("shared", name: "list title"), item("no-state")]
        try await store.saveRail(projection, rail: "resume", tenant: tenant)
        var full = item("shared", name: "detail title")
        full.playState = .init(played: true, percentage: 1, positionSeconds: 42)
        try await store.saveItems([full, MediaItem(id: "no-state", name: "full", kind: .movie)], tenant: tenant)
        var other = item("shared")
        other.playState = .init(played: false, percentage: 0.99, positionSeconds: 99)
        try await store.saveItems([other], tenant: TenantID(profile: StubMediaServer(profileID: "other:user").profile))
        let cached = try await store.rail("resume", tenant: tenant)
        XCTAssertEqual(cached?.items.map(\.id), ["missing", "shared", "no-state"])
        XCTAssertEqual(cached?.items[0], projection[0])
        XCTAssertEqual(cached?.items[1].name, "list title")
        XCTAssertEqual(cached?.items[1].playState, full.playState)
        XCTAssertEqual(cached?.items[2], projection[2])
    }

    func testLargeProjectionUsesBatchesAndPreservesOrder() async throws {
        let queries = ProgressQueryCount()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { queries.record($0.description) }
        }
        let pool = try DatabasePool(path: directory.url.appendingPathComponent("query-count.sqlite").path,
                                    configuration: configuration)
        try await pool.write { try $0.execute(sql: Schema.createTables) }
        let store = MetadataStore(database: pool)
        let tenant = TenantID(profile: StubMediaServer().profile)
        let projection = (0..<1100).map { item("item-\($0)") }
        try await store.saveRail(projection, rail: "latest", tenant: tenant)
        let canonical = projection.map { item -> MediaItem in
            var updated = item
            updated.playState = .init(played: false, percentage: 0.42, positionSeconds: 42)
            return updated
        }
        try await store.saveItems(canonical, tenant: tenant)
        queries.reset()
        let cached = try await store.rail("latest", tenant: tenant)
        XCTAssertEqual(cached?.items.map(\.id), projection.map(\.id))
        XCTAssertTrue(cached?.items.allSatisfy { $0.playState?.positionSeconds == 42 } == true)
        XCTAssertLessThanOrEqual(queries.count, 2, "1100 条投影的条目查询必须分批，不能逐条查询")
        XCTAssertGreaterThan(queries.count, 0, "计数器必须观察到真实条目查询")
    }

    func testMarkPlayedAndUnplayedReachDiskProjectionsAfterMemoryEviction() async throws {
        let store = try MetadataCache.open(at: directory.url)
        let server = StubMediaServer()
        server.resumeResult = .success([item()])
        server.itemsPageRows = [item()]
        let descriptor = MediaPageDescriptor(parentID: "lib")
        let repository = MediaRepository(server: server, store: store)
        _ = await repository.refreshHome()
        _ = try await repository.refreshPage(descriptor, startIndex: 0, limit: 100)
        for played in [true, false] {
            let expected = played
                ? try await repository.markPlayed(itemID: "item")
                : try await repository.markUnplayed(itemID: "item")
            await repository.invalidateMemory()
            let home = await repository.cachedHome()
            let page = await repository.cachedPage(descriptor, limit: 100)
            XCTAssertEqual(home?.value.resume.first?.playState, expected)
            XCTAssertEqual(page?.value.items.first?.playState, expected)
        }
    }
}

/// GRDB 会从不同连接调用 trace；只计真正执行的条目 SELECT，不按源码推算查询数。
private final class ProgressQueryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record(_ sql: String) {
        let sql = sql.uppercased()
        guard sql.hasPrefix("SELECT "), sql.contains("FROM ITEM ") else { return }
        lock.withLock { value += 1 }
    }

    func reset() { lock.withLock { value = 0 } }
    var count: Int { lock.withLock { value } }
}
