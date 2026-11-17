import CoreModel
import Foundation
import GRDB
import OcPlayerCore
import XCTest
@testable import MetadataKit

final class RustProgressCompatibilityTests: XCTestCase {
    private struct ProgressEnvelope: Decodable {
        struct Progress: Decodable {
            let positionSeconds: Double
            let recordedAt: Double
            let confirmedAt: Double?
            let completed: Bool
            let item: MediaItem
        }
        let progress: Progress
    }

    private func core(at directory: URL) throws -> OcpCoreClient {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for native SQLite compatibility tests")
        }
        return try OcpCoreClient(config: ["dataDirectory": directory.path], libraryPath: path)
    }

    func testSwiftWritesRustReadsAndRustUpdatesCanonicalSwiftPayload() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = MetadataStore(database: try MetadataDatabaseFactory.makeDatabase(at: directory.url), coreEnabled: false)
        let tenant = TenantID(rawValue: "compatibility:user")
        let item = MediaItem(id: "episode", name: "Full metadata", kind: .episode,
                             overview: "Keep this overview", runtimeSeconds: 100,
                             seriesID: "series", seasonNumber: 2, episodeNumber: 3,
                             playState: .init(played: false, percentage: 0, positionSeconds: 0))
        try await store.saveItems([item], tenant: tenant, now: Date(timeIntervalSince1970: 90))
        _ = try await store.recordPlaybackProgress(item: item, positionSeconds: 25, durationSeconds: 100,
                                                   tenant: tenant, now: Date(timeIntervalSince1970: 100.125))
        let native = try core(at: directory.url)
        let read = try native.call("progress.get", arguments: ["tenantId": tenant.rawValue, "itemId": item.id])
        XCTAssertTrue(read.ok)
        let progress = try read.data.decode(ProgressEnvelope.self).progress
        XCTAssertEqual(progress.recordedAt, 100.125)
        XCTAssertEqual(progress.positionSeconds, 25)
        XCTAssertEqual(progress.item.name, item.name)
        XCTAssertFalse(progress.completed)

        let write = try native.call("progress.save", arguments: [
            "tenantId": tenant.rawValue, "itemId": item.id, "positionSeconds": 42.5,
            "durationSeconds": 100, "recordedAt": 101.75, "played": false,
        ])
        XCTAssertTrue(write.ok)
        let cached = try await store.item(item.id, tenant: tenant)
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 42.5)
        XCTAssertEqual(cached?.item.playState?.percentage, 0.425)
        XCTAssertEqual(cached?.item.overview, item.overview)
        XCTAssertEqual(cached?.item.seriesID, item.seriesID)
        XCTAssertEqual(cached?.fetchedAt, Date(timeIntervalSince1970: 90))

        // A delayed Swift network reply must respect the Rust local-progress boundary.
        let merged = try await store.saveItems([item], tenant: tenant, now: Date(timeIntervalSince1970: 103),
                                               requestStartedAt: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(merged.first?.playState?.positionSeconds, 42.5)
        let old = try native.call("progress.save", arguments: [
            "tenantId": tenant.rawValue, "itemId": item.id, "positionSeconds": 1,
            "recordedAt": 101.5,
        ])
        XCTAssertEqual(try old.data.decode(ProgressEnvelope.self).progress.positionSeconds, 42.5)
    }

    func testRustCreatesDatabaseSwiftMigratesAndReadsIndependentProgress() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }
        let native = try core(at: directory.url)
        let write = try native.call("progress.save", arguments: [
            "tenantId": "rust:user", "itemId": "movie", "positionSeconds": 99,
            "durationSeconds": 100, "recordedAt": 200.5,
            "item": ["id": "movie", "name": "Native movie", "kind": "movie", "unknownField": "retain"],
        ])
        XCTAssertTrue(write.ok)
        let pool = try MetadataDatabaseFactory.makeDatabase(at: directory.url)
        let record = try await pool.read { db -> LocalPlaybackProgress? in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations"), 4)
            return try MetadataStore.newerProgressRecord(db, itemID: "movie", tenant: TenantID(rawValue: "rust:user"),
                                                        recordedAt: Date(timeIntervalSince1970: 200))
        }
        XCTAssertEqual(record?.recordedAt, Date(timeIntervalSince1970: 200.5))
        XCTAssertEqual(record?.item.name, "Native movie")
        XCTAssertEqual(record?.item.playState?.positionSeconds, 99)
        XCTAssertEqual(record?.completed, true)
        XCTAssertEqual(record?.item.playState?.played, false, "completion and watched state have distinct meanings")
        XCTAssertNil(record?.confirmedAt)
    }
}
