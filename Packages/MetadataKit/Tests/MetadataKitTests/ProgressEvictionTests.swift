import Foundation
import CoreModel
import JellyfinKit
import XCTest
import GRDB
@testable import MetadataKit

final class ProgressEvictionTests: XCTestCase {
    private func movie(_ id: String = "item") -> MediaItem {
        MediaItem(id: id, name: id, kind: .movie,
                  playState: .init(played: false, percentage: 0, positionSeconds: 0))
    }
    func testPendingPositionSurvivesAutomaticMetadataEvictionAndReopen() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        var store = try MetadataCache.open(at: dir.url)
        try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 1))
        try await store.recordPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100,
                                              tenant: tenant, now: Date(timeIntervalSince1970: 20))
        try await store.saveItems([movie("other")], tenant: tenant, now: Date(timeIntervalSince1970: 30))
        let before = try await store.item("item", tenant: tenant)
        XCTAssertEqual(before?.item.playState?.positionSeconds, 42)
        _ = try await store.evictItems(keepingAtMost: 1)
        store = try MetadataCache.open(at: dir.url)
        let response = try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 50),
                                                 requestStartedAt: Date(timeIntervalSince1970: 45))
        XCTAssertEqual(response.first?.playState?.positionSeconds, 42,
                       "Automatic cache pressure must not erase an unconfirmed final playback position")
    }
    func testPendingPositionSurvivesReopenWhenMetadataLimitIsNotReached() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        var store = try MetadataCache.open(at: dir.url)
        try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 1))
        try await store.recordPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100,
                                              tenant: tenant, now: Date(timeIntervalSince1970: 20))
        _ = try await store.evictItems(keepingAtMost: 1)
        store = try MetadataCache.open(at: dir.url)
        let response = try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 50),
                                                 requestStartedAt: Date(timeIntervalSince1970: 45))
        XCTAssertEqual(response.first?.playState?.positionSeconds, 42)
    }
}

extension ProgressEvictionTests {
    func testOfflineRailsAndPagesUseIndependentProgressAfterEviction() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let server = StubMediaServer(); let tenant = TenantID(profile: server.profile)
        var store = try MetadataCache.open(at: dir.url)
        let descriptor = MediaPageDescriptor(parentID: "library")
        let key = descriptor.key(startIndex: 0, limit: 100)
        var listItem = movie(); listItem.name = "projection title"
        try await store.saveItems([movie()], tenant: tenant)
        try await store.saveRail([listItem], rail: "resume", tenant: tenant)
        try await store.savePage(.init(items: [listItem], startIndex: 0, totalRecordCount: 1), key: key, tenant: tenant)
        try await store.recordPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100, tenant: tenant)
        _ = try await store.evictItems(keepingAtMost: 0)
        store = try MetadataCache.open(at: dir.url)
        let repository = MediaRepository(server: server, store: store)
        let home = await repository.cachedHome()
        let page = await repository.cachedPage(descriptor, limit: 100)
        XCTAssertEqual(home?.value.resume.first?.playState?.positionSeconds, 42)
        XCTAssertEqual(home?.value.resume.first?.name, "projection title")
        XCTAssertEqual(page?.value.items.first?.playState?.positionSeconds, 42)
        let emptyResume = try await store.saveItemsAndRail([], rail: "resume", tenant: tenant)
        XCTAssertEqual(emptyResume.first?.playState?.positionSeconds, 42)
    }

    func testConfirmedProgressAllowsEvictionButStillBlocksVeryLateReplies() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        try await store.recordPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100,
                                              tenant: tenant, now: Date(timeIntervalSince1970: 10))
        var acknowledged = movie(); acknowledged.playState?.positionSeconds = 42
        _ = try await store.saveItems([acknowledged], tenant: tenant, now: Date(timeIntervalSince1970: 20),
                                      requestStartedAt: Date(timeIntervalSince1970: 15))
        _ = try await store.evictItems(keepingAtMost: 0)
        let count = try await store.itemCount(); XCTAssertEqual(count, 0)
        let old = try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 30),
                                            requestStartedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(old.first?.playState?.positionSeconds, 42)
        var rewound = movie(); rewound.playState?.positionSeconds = 12
        _ = try await store.saveItems([rewound], tenant: tenant, now: Date(timeIntervalSince1970: 40),
                                      requestStartedAt: Date(timeIntervalSince1970: 35))
        let veryLate = try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 50),
                                                 requestStartedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(veryLate.first?.playState?.positionSeconds, 12)
    }
}

extension ProgressEvictionTests {
    func testV4MigrationPreservesPendingAndConfirmedV3Records() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA foreign_keys = ON") }
            let pool = try DatabasePool(path: dir.url.appendingPathComponent("Media.sqlite").path, configuration: configuration)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("createMediaSchemaV1") { try $0.execute(sql: Schema.createTables) }
            migrator.registerMigration("addTMDbSchemaV2") { try $0.execute(sql: Schema.createTMDbTables) }
            migrator.registerMigration("addLocalProgressV3") { try $0.execute(sql: Schema.createLocalProgressTable) }
            try migrator.migrate(pool)
            let writer = MetadataStore(database: pool)
            try await writer.saveItems([movie("pending"), movie("confirmed")], tenant: tenant)
            try await writer.recordPlaybackProgress(item: movie("pending"), positionSeconds: 42, durationSeconds: 100,
                                                   tenant: tenant, now: Date(timeIntervalSince1970: 10))
            try await writer.updatePlayState(.init(played: true, percentage: 1, positionSeconds: 0),
                                            forItemID: "confirmed", tenant: tenant, now: Date(timeIntervalSince1970: 20))
            try await writer.saveRail([movie("pending")], rail: "resume", tenant: tenant)
        }
        let store = try MetadataCache.open(at: dir.url)
        let before = try await store.rail("resume", tenant: tenant)
        XCTAssertEqual(before?.items.first?.playState?.positionSeconds, 42)
        _ = try await store.evictItems(keepingAtMost: 0)
        let rows = try await store.saveItems([movie("pending"), movie("confirmed")], tenant: tenant,
                                            now: Date(timeIntervalSince1970: 30), requestStartedAt: Date(timeIntervalSince1970: 15))
        XCTAssertEqual(rows[0].playState?.positionSeconds, 42)
        XCTAssertEqual(rows[1].playState?.played, true)
        let pool = try DatabasePool(path: dir.url.appendingPathComponent("Media.sqlite").path)
        let foreignKeys = try await pool.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_list(local_progress)").count }
        XCTAssertEqual(foreignKeys, 0)
    }

    func testEvictionCompactsConfirmedMetadataAndKeepsPendingMetadata() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let tenant = TenantID(profile: StubMediaServer().profile)
        let store = try MetadataCache.open(at: dir.url)
        var pending = movie("pending"); pending.overview = String(repeating: "detail", count: 1000)
        var confirmed = movie("confirmed"); confirmed.overview = pending.overview
        try await store.saveItems([pending, confirmed], tenant: tenant)
        try await store.recordPlaybackProgress(item: pending, positionSeconds: 42, durationSeconds: 100, tenant: tenant)
        try await store.updatePlayState(.init(played: true, percentage: 1, positionSeconds: 0), forItemID: "confirmed", tenant: tenant)
        _ = try await store.evictItems(keepingAtMost: 0)
        let pool = try DatabasePool(path: dir.url.appendingPathComponent("Media.sqlite").path)
        let payloads = try await pool.read { db -> [String: Data] in
            var result: [String: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT item_id, payload FROM local_progress") {
                result[row["item_id"] as String] = row["payload"] as Data
            }
            return result
        }
        let preserved = PayloadCodec.decode(MediaItem.self, from: payloads["pending"]!, storedVersion: Schema.payloadVersion)
        let compact = PayloadCodec.decode(MediaItem.self, from: payloads["confirmed"]!, storedVersion: Schema.payloadVersion)
        XCTAssertEqual(preserved?.overview, pending.overview)
        XCTAssertEqual(preserved?.playState?.positionSeconds, 42)
        XCTAssertNil(compact?.overview)
        XCTAssertEqual(compact?.playState?.played, true)
        try await store.clear(tenant: tenant)
        let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_progress") }
        XCTAssertEqual(count, 0)
    }
}
