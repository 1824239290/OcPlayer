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
  func testAllTypedCacheReadsRetainWideIntegersAndSkipMalformedPayloads() async throws {
    let path = try library()
    let dir = try TemporaryDirectory()
    defer { dir.cleanUp() }
    let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
    let native = MetadataStore(database: pool, coreEnabled: false)
    let shared = MetadataStore(database: pool, coreLibraryPath: path)
    let key = PageKey(
      parentID: "series", kinds: nil, sort: nil, watchState: nil,
      searchTerm: nil, startIndex: Int.max - 4, limit: Int.max - 5)
    let query = PageQuery(
      parentID: "series", kinds: nil, sort: nil, watchState: nil, searchTerm: nil)
    let episode = MediaItem(
      id: "episode", name: "Exact", kind: .episode, year: Int.max,
      runtimeSeconds: 100, seriesID: "series", seasonID: "season",
      seasonNumber: Int.max - 1, episodeNumber: Int.max - 2,
      playState: .init(
        played: false, percentage: 0, positionSeconds: 0,
        unplayedCount: Int.max - 3), childCount: Int.max - 4,
      primaryImageTag: "poster")
    var season = episode
    season.id = "season"
    season.kind = .season
    var movie = episode
    movie.id = "movie"
    movie.kind = .movie
    let info = try JSONDecoder().decode(
      MediaFileInfo.self,
      from: JSONSerialization.data(withJSONObject: [
        "sizeBytes": Int.max, "sourceCount": Int.max - 1,
        "video": ["width": Int.max - 2, "height": Int.max - 3, "bitrate": Int.max - 4],
        "audioTracks": [["sampleRate": Int.max - 5, "bitrate": Int.max - 6]],
      ]))
    // Both write directions use the same persisted format; every read goes
    // through the real shared ABI response, including nested snapshots.
    for (index, writer) in [native, shared].enumerated() {
      let tenant = TenantID(rawValue: "exact:\(index)")
      try await writer.saveItems([episode, season, movie], tenant: tenant)
      try await writer.saveRail([episode], rail: "resume", tenant: tenant)
      try await writer.savePage(
        .init(items: [episode], startIndex: key.startIndex, totalRecordCount: Int.max - 6),
        key: key, tenant: tenant)
      try await writer.saveMediaFileInfo(info, itemID: episode.id, tenant: tenant)
      for reader in [native, shared] {
        let item = try await reader.item(episode.id, tenant: tenant)
        XCTAssertEqual(item?.item, episode)
        let items = try await reader.items([episode.id], tenant: tenant)
        XCTAssertEqual(items.map(\.item), [episode])
        let posters = try await reader.posterCandidates(tenant: tenant, limit: 10)
        XCTAssertEqual(posters.map(\.item).sorted { $0.id < $1.id }, [movie])
        let rail = try await reader.rail("resume", tenant: tenant)
        XCTAssertEqual(rail?.items, [episode])
        let home = try await reader.homeSnapshotParts(tenant: tenant)
        XCTAssertEqual(home.rails["resume"]?.items, [episode])
        let page = try await reader.page(key, tenant: tenant)
        XCTAssertEqual(page?.items, [episode])
        XCTAssertEqual(page?.totalRecordCount, Int.max - 6)
        XCTAssertEqual(page?.startIndex, key.startIndex)
        XCTAssertEqual(page?.limit, key.limit)
        let pages = try await reader.pages(matching: query, tenant: tenant)
        XCTAssertEqual(pages.first?.items, [episode])
        XCTAssertEqual(pages.first?.totalRecordCount, Int.max - 6)
        let seasons = try await reader.seasons(seriesID: "series", tenant: tenant)
        XCTAssertEqual(seasons, [season])
        let episodes = try await reader.episodes(
          seriesID: "series", seasonID: "season", tenant: tenant)
        XCTAssertEqual(episodes, [episode])
        let file = try await reader.mediaFileInfo(itemID: episode.id, tenant: tenant)
        XCTAssertEqual(file?.info, info)
      }
      let progress = try await shared.recordPlaybackProgress(
        item: episode, positionSeconds: 25,
        durationSeconds: 100, tenant: tenant)
      XCTAssertEqual(progress.unplayedCount, Int.max - 3)
      try await pool.write { db in
        try db.execute(
          sql: "UPDATE item SET payload = ? WHERE tenant_id = ? AND item_id = ?",
          arguments: [Data("null".utf8), tenant.rawValue, episode.id])
      }
      let missing = try await shared.item(episode.id, tenant: tenant)
      XCTAssertNil(missing)
      let retained = try await shared.items([episode.id, season.id], tenant: tenant)
      XCTAssertEqual(retained.map(\.item), [season])
      let invalidEpisodes = try await shared.episodes(
        seriesID: "series", seasonID: "season", tenant: tenant)
      XCTAssertTrue(invalidEpisodes.isEmpty)
    }
  }

}
