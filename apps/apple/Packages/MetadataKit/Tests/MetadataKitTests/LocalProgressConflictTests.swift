import CoreModel
import Foundation
import JellyfinKit
import GRDB
import XCTest
@testable import MetadataKit

final class LocalProgressConflictTests: XCTestCase {
    private func item(_ position: Double, name: String = "movie") -> MediaItem {
        MediaItem(id: "item", name: name, kind: .movie,
                  playState: .init(played: false, percentage: position / 100, positionSeconds: position))
    }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testPendingProgressSurvivesReopenAndMergesFreshMetadata() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        var store = try MetadataCache.open(at: dir.url)
        try await store.recordPlaybackProgress(item: item(0), positionSeconds: 42, durationSeconds: 100,
                                               tenant: tenant, now: date(10))
        store = try MetadataCache.open(at: dir.url)
        let rows = try await store.saveItems([item(0, name: "fresh title")], tenant: tenant,
                                             now: date(20), requestStartedAt: date(15))
        let cached = try await store.item("item", tenant: tenant)
        XCTAssertEqual(rows.first?.playState?.positionSeconds, 42)
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 42)
        XCTAssertEqual(cached?.item.name, "fresh title")
        let missing = try await store.saveItemsAndRail([], rail: "resume", tenant: tenant,
                                                       now: date(30), requestStartedAt: date(25))
        XCTAssertEqual(missing.first?.name, "fresh title", "补入继续观看不能覆盖刚刷新的元数据")
    }

    func testConfirmationKeepsOlderInflightRepliesProtectedButAllowsNewRemoteRewind() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        try await store.recordPlaybackProgress(item: item(0), positionSeconds: 42, durationSeconds: 100,
                                               tenant: tenant, now: date(10))
        _ = try await store.saveItems([item(42)], tenant: tenant, now: date(20), requestStartedAt: date(15))
        let late = try await store.saveItems([item(0)], tenant: tenant, now: date(30), requestStartedAt: date(15))
        XCTAssertEqual(late.first?.playState?.positionSeconds, 42)
        let new = try await store.saveItems([item(12)], tenant: tenant, now: date(40), requestStartedAt: date(35))
        XCTAssertEqual(new.first?.playState?.positionSeconds, 12)
        let laterOld = try await store.saveItems([item(0)], tenant: tenant, now: date(50), requestStartedAt: date(15))
        XCTAssertEqual(laterOld.first?.playState?.positionSeconds, 12, "旧请求应保留最新已确认的服务端位置")
    }

    func testReplyStartedBeforeLocalWriteCannotConfirmCoincidentallyMatchingPosition() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        try await store.recordPlaybackProgress(item: item(0), positionSeconds: 42, durationSeconds: 100,
                                               tenant: tenant, now: date(10))
        _ = try await store.saveItems([item(42)], tenant: tenant, now: date(20), requestStartedAt: date(5))
        let next = try await store.saveItems([item(0)], tenant: tenant, now: date(30), requestStartedAt: date(25))
        XCTAssertEqual(next.first?.playState?.positionSeconds, 42)
    }

    func testNewLocalRewindReplacesPriorPendingPositionAndOtherTenantIsUnaffected() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        for (position, time) in [(42.0, 10.0), (12.0, 20.0)] {
            try await store.recordPlaybackProgress(item: item(0), positionSeconds: position, durationSeconds: 100,
                                                   tenant: tenant, now: date(time))
        }
        let old = try await store.saveItems([item(42)], tenant: tenant, now: date(30), requestStartedAt: date(25))
        XCTAssertEqual(old.first?.playState?.positionSeconds, 12)
        let other = TenantID(profile: StubMediaServer(profileID: "other:user").profile)
        let rows = try await store.saveItems([item(0)], tenant: other, now: date(30), requestStartedAt: date(25))
        XCTAssertEqual(rows.first?.playState?.positionSeconds, 0)
    }

    func testExplicitMarkUnplayedReleasesPendingProtection() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        try await store.recordPlaybackProgress(item: item(0), positionSeconds: 42, durationSeconds: 100,
                                               tenant: tenant, now: date(10))
        try await store.updatePlayState(item(0).playState!, forItemID: "item", tenant: tenant, now: date(20))
        let fresh = try await store.saveItems([item(0)], tenant: tenant, now: date(30), requestStartedAt: date(25))
        XCTAssertEqual(fresh.first?.playState?.positionSeconds, 0)
    }

    func testEmptyResumeKeepsOnlyUnconfirmedLocalPlayback() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        try await store.recordPlaybackProgress(item: item(0), positionSeconds: 42, durationSeconds: 100,
                                               tenant: tenant, now: date(10))
        let pending = try await store.saveItemsAndRail([], rail: "resume", tenant: tenant,
                                                       now: date(20), requestStartedAt: date(15))
        XCTAssertEqual(pending.first?.playState?.positionSeconds, 42)
        _ = try await store.saveItems([item(42)], tenant: tenant, now: date(30), requestStartedAt: date(25))
        let confirmed = try await store.saveItemsAndRail([], rail: "resume", tenant: tenant,
                                                         now: date(40), requestStartedAt: date(35))
        XCTAssertTrue(confirmed.isEmpty)
    }

    func testV3MigrationPreservesV2ItemsAndRails() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        do {
            let pool = try DatabasePool(path: dir.url.appendingPathComponent("Media.sqlite").path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("createMediaSchemaV1") { try $0.execute(sql: Schema.createTables) }
            migrator.registerMigration("addTMDbSchemaV2") { try $0.execute(sql: Schema.createTMDbTables) }
            try migrator.migrate(pool)
            // 直接写旧 schema 的 item，不调用已依赖 v3 的新写接口。
            let oldPayload = PayloadCodec.encode(item(7))!
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO item(tenant_id,item_id,kind,name,fetched_at,payload_version,payload) VALUES (?,?,?,?,?,?,?)",
                               arguments: [tenant.rawValue, "item", "Movie", "old", 1, Schema.payloadVersion, oldPayload])
            }
            try await MetadataStore(database: pool).saveRail([item(7)], rail: "resume", tenant: tenant)
        }
        let store = try MetadataCache.open(at: dir.url)
        let preserved = try await store.item("item", tenant: tenant)
        let rail = try await store.rail("resume", tenant: tenant)
        XCTAssertEqual(preserved?.item.playState?.positionSeconds, 7)
        XCTAssertEqual(rail?.items.first?.playState?.positionSeconds, 7)
        try await store.recordPlaybackProgress(item: item(7), positionSeconds: 42, durationSeconds: 100, tenant: tenant)
        let merged = try await store.saveItems([item(7)], tenant: tenant)
        XCTAssertEqual(merged.first?.playState?.positionSeconds, 42)
    }

    func testNaturalCompletionAcceptsServerPlayedFlagAndClearedResumePosition() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let server = StubMediaServer()
        var finished = item(0)
        finished.playState = .init(played: true, percentage: 1, positionSeconds: 0)
        server.latestResult = .success([finished])
        let store = try MetadataCache.open(at: dir.url)
        let repository = MediaRepository(server: server, store: store)
        await repository.recordFinalPlaybackProgress(item: item(0), positionSeconds: 99, durationSeconds: 100)
        let home = await repository.refreshHome()
        let disk = try await store.item("item", tenant: TenantID(profile: server.profile))
        XCTAssertTrue(home.snapshot.value.resume.isEmpty)
        XCTAssertEqual(disk?.item.playState, finished.playState)
        let refreshed = try await store.saveItems([finished], tenant: TenantID(profile: server.profile))
        XCTAssertEqual(refreshed.first?.playState, finished.playState)
    }

    func testRepositoryProtectsAllNetworkProjectionsInDiskAndMemoryModes() async throws {
        for disk in [false, true] {
            let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
            let server = StubMediaServer()
            server.itemResult = .success(item(0, name: "fresh title"))
            server.resumeResult = .success([item(0)])
            server.latestResult = .success([item(0)])
            server.episodesResult = .success([item(0)])
            server.itemsPageRows = [item(0)]
            let store = disk ? try MetadataCache.open(at: dir.url) : nil
            let repository = MediaRepository(server: server, store: store)
            await repository.recordFinalPlaybackProgress(item: item(0), positionSeconds: 42, durationSeconds: 100)
            let home = await repository.refreshHome()
            let detail = try await repository.refreshDetail(itemID: "item")
            let page = try await repository.refreshPage(.init(parentID: "lib"), startIndex: 0, limit: 100)
            let episodes = try await repository.refreshEpisodes(seriesID: "series", seasonID: "season")
            XCTAssertEqual(home.snapshot.value.resume.first?.playState?.positionSeconds, 42)
            XCTAssertEqual(home.snapshot.value.latest.first?.playState?.positionSeconds, 42)
            XCTAssertEqual(detail.snapshot.value.item.playState?.positionSeconds, 42)
            XCTAssertEqual(detail.snapshot.value.item.name, "fresh title")
            XCTAssertEqual(page.value.items.first?.playState?.positionSeconds, 42)
            XCTAssertEqual(episodes.first?.playState?.positionSeconds, 42)
        }
    }
}
