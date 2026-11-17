import CoreModel
import Foundation
import GRDB
import JellyfinKit
import OcPlayerCore
import XCTest

@testable import MetadataKit

final class RustMediaRepositoryTests: XCTestCase {
  private func library() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
      throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for shared repository/database differential tests")
    }
    return path
  }
  private func core(limit: Int = 2) throws -> RustMediaRepository {
    let path = try library()
    return try XCTUnwrap(
      RustMediaRepository.make(
        configuration: .init(
          itemLimit: limit, detailLimit: limit, episodeListLimit: limit, pageLimit: limit),
        libraryPath: path))
  }
  func testEveryMemoryBucketMatchesNativeLRUAcrossMutationAndWideIntegerCorpus() throws {
    for limit in [0, 1, 2, 8] {
      let rust = try core(limit: limit)
      for bucket in ["items", "details", "episodes", "pages", "home"] {
        var native = MemoryLRU<String, MediaItem>(limit: bucket == "home" ? 1 : limit)
        var shared = MemoryLRU<String, MediaItem>(limit: limit, rust: rust, bucket: bucket)
        var seed: UInt64 = 47
        for index in 0..<300 {
          seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          let key = ["作品", "quoted\"", "newline\n", "é", "e\u{301}", "\0"][Int((seed >> 32) % 6)]
          switch index % 11 {
          case 0:
            native.removeAll()
            shared.removeAll()
          case 1, 2, 3, 4, 5:
            let item = makeItem(
              id: key, name: "Value \(index)", year: Int.max - index,
              seasonNumber: Int.min + index,
              playState: .init(
                played: false, percentage: 0.25, positionSeconds: 4, unplayedCount: Int.max))
            let entry = MemoryEntry(
              value: item, fetchedAt: Date(timeIntervalSinceReferenceDate: Double(index) + 0.125))
            native[key] = entry
            shared[key] = entry
          case 6:
            native[key] = nil
            shared[key] = nil
          default:
            let a = native[key]
            let b = shared[key]
            XCTAssertEqual(a?.value, b?.value)
            XCTAssertEqual(a?.fetchedAt, b?.fetchedAt)
          }
          XCTAssertEqual(native.allValues.mapValues(\.value), shared.allValues.mapValues(\.value))
          XCTAssertEqual(
            native.allValues.mapValues(\.fetchedAt), shared.allValues.mapValues(\.fetchedAt))
        }
      }
    }
  }
  func testStructuredPageAndEpisodeKeysRetainNativeIdentity() throws {
    let rust = try core(limit: 8)
    let descriptors: [MediaPageDescriptor] = [
      .init(parentID: nil), .init(parentID: ""), .init(parentID: "series", kinds: []),
      .init(parentID: "series", kinds: [.movie, .series]),
      .init(parentID: "series", kinds: [.series, .movie]),
      .init(parentID: "series", recursive: false),
      .init(
        parentID: "series", sort: .init(field: .dateAdded, ascending: false),
        watchState: .unwatched, searchTerm: "猫\n"),
    ]
    var memory = MemoryLRU<MediaPageDescriptor, MediaPageContent>(
      limit: 8, rust: rust, bucket: "pages")
    for (index, key) in descriptors.enumerated() {
      memory[key] = .init(
        value: .init(
          items: [makeItem(id: "\(index)")], totalCount: Int.max, nextStartIndex: index,
          lastPageWasFull: true), fetchedAt: Date(timeIntervalSince1970: 100))
    }
    XCTAssertEqual(memory.allValues.count, descriptors.count)
    for (index, key) in descriptors.enumerated() {
      XCTAssertEqual(memory[key]?.value.items.first?.id, "\(index)")
    }
    var episodes = MemoryLRU<MediaRepository.EpisodeKey, [MediaItem]>(
      limit: 8, rust: rust, bucket: "episodes")
    let key = MediaRepository.EpisodeKey(seriesID: "series/\"", seasonID: "season\n")
    episodes[key] = .init(
      value: [makeItem(id: "wide", episodeNumber: Int.max)],
      fetchedAt: Date(timeIntervalSince1970: 10.125))
    XCTAssertEqual(episodes[key]?.value.first?.episodeNumber, Int.max)
    XCTAssertEqual(episodes.allValues.keys.first, key)
  }
  func testPublicMemoryOnlyRepositoryHomeDetailPageAndProgressMatchIndependentNative() async throws
  {
    let path = try library()
    var results: [MediaHomeContent] = []
    for shared in [false, true] {
      let server = StubMediaServer()
      let item = makeItem(
        id: "movie", name: "作品", year: Int.max,
        playState: .init(played: false, percentage: 0, positionSeconds: 0, unplayedCount: Int.max))
      server.userViewsResult = .success([.init(id: "lib", name: "Library", collectionType: .movies)]
      )
      server.resumeResult = .success([item])
      server.nextUpResult = .success([item])
      server.latestResult = .success([item])
      server.itemResult = .success(item)
      server.itemsPageRows = [item]
      let repo = MediaRepository(
        server: server, store: nil, now: { Date(timeIntervalSince1970: 123.25) },
        rustCoreLibraryPath: shared ? path : nil, useSharedCore: shared)
      let active = await repo.usesCoreRepository
      XCTAssertEqual(active, shared)
      let refreshed = await repo.refreshHome()
      XCTAssertEqual(refreshed.snapshot.source, .network)
      XCTAssertTrue(refreshed.snapshot.value.nextUp.isEmpty)
      _ = try await repo.refreshDetail(itemID: item.id, kindHint: .movie)
      let descriptor = MediaPageDescriptor(parentID: "lib", kinds: [.movie])
      _ = try await repo.refreshPage(descriptor, startIndex: 0, limit: 2)
      await repo.applyPlayState(
        .init(played: true, percentage: 1, positionSeconds: 30, unplayedCount: Int.max),
        forItemID: item.id, persistToStore: true)
      let home = await repo.cachedHome()
      let detail = await repo.cachedDetail(itemID: item.id)
      let page = await repo.cachedPage(descriptor, limit: 2)
      XCTAssertEqual(home?.source, .memory)
      XCTAssertEqual(home?.fetchedAt, Date(timeIntervalSince1970: 123.25))
      XCTAssertEqual(home?.value.latest.first?.playState?.positionSeconds, 30)
      XCTAssertEqual(detail?.value.item.playState?.unplayedCount, Int.max)
      XCTAssertEqual(page?.value.items.first?.year, Int.max)
      results.append(try XCTUnwrap(home?.value))
      await repo.invalidateMemory()
      let cleared = await repo.cachedHome()
      XCTAssertNil(cleared)
      XCTAssertEqual(server.callCount("item"), 1)
      XCTAssertEqual(server.callCount("itemsPage"), 1)
    }
    XCTAssertEqual(results.first, results.last)
  }
  func testCancelledWaiterAndInvalidationDoNotCancelOrRetireSharedRefresh() async throws {
    let path = try library()
    for shared in [false, true] {
      let server = StubMediaServer()
      server.itemHook = {
        try await Task.sleep(for: .milliseconds(80))
        return makeItem(id: "movie")
      }
      let repo = MediaRepository(
        server: server, store: nil, rustCoreLibraryPath: shared ? path : nil, useSharedCore: shared)
      let tasks = (0..<8).map { _ in Task { try await repo.refreshItem(itemID: "movie") } }
      while server.callCount("item") == 0 { await Task.yield() }
      tasks.last?.cancel()
      await repo.invalidateMemory()
      for task in tasks {
        let value = try await task.value
        XCTAssertEqual(value.id, "movie")
      }
      XCTAssertEqual(server.callCount("item"), 1)
      _ = try await repo.refreshItem(itemID: "movie")
      XCTAssertEqual(server.callCount("item"), 2)
      if let rust = await repo.rust {
        struct Stats: Decodable { let flights: Int }
        let stats = try rust.command("stats", [:]).decodeData(Stats.self)
        XCTAssertEqual(stats.flights, 0)
      }
    }
  }
  func testNativeAndCoreDatabaseMigrationRebuildAndFileAccountingMatch() async throws {
    let path = try library()
    for shared in [false, true] {
      let dir = try TemporaryDirectory()
      defer { dir.cleanUp() }
      let file = dir.url.appendingPathComponent("Media.sqlite")
      try Data("corrupt".utf8).write(to: file)
      try Data("bad wal".utf8).write(to: URL(fileURLWithPath: file.path + "-wal"))
      try Data("bad shm".utf8).write(to: URL(fileURLWithPath: file.path + "-shm"))
      let report = dir.url.appendingPathComponent("original-report.txt")
      try Data("retain".utf8).write(to: report)
      let pool = try MetadataDatabaseFactory.makeDatabase(
        at: dir.url, coreLibraryPath: shared ? path : nil, useSharedCore: shared)
      let ledger = try await pool.read { db in
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
      }
      XCTAssertEqual(
        ledger,
        [
          "addLocalProgressV3", "addTMDbSchemaV2", "createMediaSchemaV1",
          "makeLocalProgressIndependentV4",
        ])
      // journal_size_limit is configured on the native writer connection.
      let pragmas = try await pool.writeWithoutTransaction { db in
        (
          try String.fetchOne(db, sql: "PRAGMA journal_mode"),
          try Int.fetchOne(db, sql: "PRAGMA journal_size_limit")
        )
      }
      XCTAssertEqual(pragmas.0, "wal")
      XCTAssertEqual(pragmas.1, 8 * 1024 * 1024)
      XCTAssertEqual(try Data(contentsOf: report), Data("retain".utf8))
      let nativeBytes = MetadataDatabaseFactory.totalBytes(at: dir.url, useSharedCore: false)
      let core = try XCTUnwrap(RustMetadataDatabase.make(libraryPath: path))
      XCTAssertEqual(try core.size(at: dir.url), nativeBytes)
      let store = MetadataStore(
        database: pool, coreLibraryPath: shared ? path : nil, coreEnabled: shared)
      let tenant = TenantID(rawValue: "database:user")
      try await store.saveItems([makeItem(id: "kept", year: Int.max)], tenant: tenant)
      let reopened = try MetadataCache.open(
        at: dir.url, coreLibraryPath: shared ? path : nil, useSharedCore: shared)
      let cached = try await reopened.item("kept", tenant: tenant)
      XCTAssertEqual(cached?.item.year, Int.max)
    }
  }
  func testUnrecoverableDatabaseParentFailureIsReturnedByBothImplementations() throws {
    let path = try library()
    let dir = try TemporaryDirectory()
    defer { dir.cleanUp() }
    let parent = dir.url.appendingPathComponent("parent-file")
    try Data("keep parent".utf8).write(to: parent)
    for shared in [false, true] {
      XCTAssertThrowsError(
        try MetadataDatabaseFactory.makeDatabase(
          at: parent, coreLibraryPath: shared ? path : nil, useSharedCore: shared))
      XCTAssertEqual(try Data(contentsOf: parent), Data("keep parent".utf8))
    }
  }
}
