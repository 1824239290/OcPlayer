import CoreModel
import Foundation
import GRDB
import JellyfinKit
import OcPlayerCore
import XCTest

@testable import MetadataKit

final class RustCacheIntegrationTests: XCTestCase {
  private func library() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
      throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for shared-cache integration")
    }
    return path
  }

  func testProductionCacheActivatesAndBothClientsReadTheSameDatabase() async throws {
    let path = try library()
    let dir = try TemporaryDirectory()
    defer { dir.cleanUp() }
    let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
    let native = MetadataStore(database: pool, coreEnabled: false)
    let shared = MetadataStore(database: pool, coreLibraryPath: path)
    let active = await shared.usesCoreCache
    XCTAssertTrue(active)
    if OcpCoreFeature.isEnabled {
      let automatic = try MetadataCache.open(at: dir.url)
      let enabled = await automatic.usesCoreCache
      XCTAssertTrue(enabled, "the production factory must activate the bundled/shared cache")
    }
    let tenant = TenantID(rawValue: "cache:user")
    let first = MediaItem(
      id: "episode", name: "详细元数据", kind: .episode, overview: "简介",
      runtimeSeconds: 100, seriesID: "series", seasonID: "season",
      seasonNumber: 2, episodeNumber: 3,
      playState: .init(played: false, percentage: 0, positionSeconds: 0, unplayedCount: 4))
    try await native.saveItems([first], tenant: tenant, now: Date(timeIntervalSince1970: 10))
    try await native.saveRail(
      [first], rail: "resume", tenant: tenant, now: Date(timeIntervalSince1970: 11))
    let read = try await shared.item(first.id, tenant: tenant)
    XCTAssertEqual(read?.item, first)
    XCTAssertEqual(read?.fetchedAt.timeIntervalSince1970, 10)
    let state = try await shared.recordPlaybackProgress(
      item: first, positionSeconds: 25,
      durationSeconds: 100, tenant: tenant, now: Date(timeIntervalSince1970: 20.125))
    XCTAssertEqual(state.unplayedCount, 4)
    let nativeRead = try await native.item(first.id, tenant: tenant)
    XCTAssertEqual(nativeRead?.item.playState?.positionSeconds, 25)
    XCTAssertEqual(nativeRead?.item.overview, first.overview)
    let rail = try await native.rail("resume", tenant: tenant)
    XCTAssertEqual(rail?.items.first?.playState?.positionSeconds, 25)
    let merged = try await shared.saveItems(
      [first], tenant: tenant,
      now: Date(timeIntervalSince1970: 30), requestStartedAt: Date(timeIntervalSince1970: 19))
    XCTAssertEqual(merged.first?.playState?.positionSeconds, 25)
    let columns = try await pool.read { db in
      let row = try Row.fetchOne(db, sql: "SELECT series_id,season_id,position_seconds FROM item")!
      return (
        row["series_id"] as String, row["season_id"] as String, row["position_seconds"] as Double
      )
    }
    XCTAssertEqual(columns.0, "series")
    XCTAssertEqual(columns.1, "season")
    XCTAssertEqual(columns.2, 25)
  }

  func testReplacementSnapshotsTMDbExpiryAndAtomicRollbackAcrossClients() async throws {
    let path = try library()
    let dir = try TemporaryDirectory()
    defer { dir.cleanUp() }
    let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
    let native = MetadataStore(database: pool, coreEnabled: false)
    let shared = MetadataStore(database: pool, coreLibraryPath: path)
    let tenant = TenantID(rawValue: "cache:user")
    let lib = MediaLibrary(id: "library", name: "Movies", collectionType: .movies)
    try await native.saveLibraries([lib], tenant: tenant)
    let fromCore = try await shared.libraries(tenant: tenant)
    XCTAssertEqual(fromCore.first?.library, lib)
    // Duplicate primary keys must roll back the deletion and entire batch.
    do {
      try await shared.saveLibraries([lib, lib], tenant: tenant)
      XCTFail("expected duplicate library failure")
    } catch { XCTAssertEqual((error as NSError).code, 1402) }
    let retained = try await native.libraries(tenant: tenant)
    XCTAssertEqual(retained.count, 1)
    try await shared.saveLibraries([], tenant: tenant)
    let removed = try await native.libraries(tenant: tenant)
    XCTAssertTrue(removed.isEmpty)
    let payload = TMDbEntityPayload.entity(TMDbEntity(id: 603, mediaType: .movie, title: "Movie"))
    try await shared.saveTMDbPayload(
      payload, key: .movie(603), language: "zh-CN", lifetime: 0,
      now: Date(timeIntervalSince1970: 100))
    let expiredNative = try await native.tmdbPayload(key: .movie(603), language: "zh-CN")
    let expiredCore = try await shared.tmdbPayload(key: .movie(603), language: "zh-CN")
    XCTAssertEqual(expiredNative?.payload, payload)
    XCTAssertEqual(expiredCore?.payload, payload, "expired metadata remains usable offline")
    let evicted = try await shared.evictExpiredTMDbEntities(now: Date(timeIntervalSince1970: 100))
    XCTAssertEqual(evicted, 1)
    let missing = try await native.tmdbPayload(key: .movie(603), language: "zh-CN")
    XCTAssertNil(missing)
  }
}
