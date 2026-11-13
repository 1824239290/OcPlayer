import Foundation
import GRDB
import OcPlayerCore
import XCTest

@testable import BangumiKit

final class RustBangumiStoreIntegrationTests: XCTestCase {
  private func library() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
      throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for shared Bangumi cache tests")
    }
    return path
  }
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bangumi-core-store-\(UUID().uuidString)")
  }

  func testProductionActivationAndBidirectionalRecords() async throws {
    let lib = try library()
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pool = try BangumiDatabaseFactory.makeDatabase(at: dir)
    let native = BangumiDatabaseOperator(database: pool, coreEnabled: false)
    let shared = BangumiDatabaseOperator(database: pool, coreLibraryPath: lib)
    let active = await shared.usesCoreStore
    XCTAssertTrue(active)
    if OcpCoreFeature.isEnabled {
      let automatic = BangumiDatabaseOperator(database: pool)
      let autoActive = await automatic.usesCoreStore
      XCTAssertTrue(autoActive)
    }
    var original = BangumiFixture.subject(id: 1, eps: 12, epStatus: 5)
    original.interest?.private = true
    original.interest?.volStatus = 2
    original.summary = "full description"
    original.images = BangumiSubjectImages(large: "image")
    try await native.saveSubject(original)
    let initial = try await shared.subject(id: 1)
    let nativeRoundTrip = try await native.subject(id: 1)
    XCTAssertEqual(initial, nativeRoundTrip)
    let targets = try await shared.fetchEpisodeSyncTargets()
    XCTAssertEqual(targets, [1])
    var slim = original.slim
    slim.name = "changed title"
    slim.interest?.rate = 8
    try await shared.saveSubject(slim)
    let updated = try await native.subject(id: 1)
    XCTAssertEqual(updated?.name, "changed title")
    XCTAssertEqual(updated?.interest?.rate, 8)
    XCTAssertEqual(updated?.interest?.private, true)
    XCTAssertEqual(updated?.interest?.volStatus, 2)
    XCTAssertEqual(updated?.summary, original.summary)
    let migrations = try await pool.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    XCTAssertEqual(migrations, ["addEpisodesSyncedAt", "createBangumiSchemaV1"])
    try await shared.saveSubject(
      BangumiSubjectDTO(id: 1, name: "fresh", type: .anime), authoritativeInterest: true)
    let cleared = try await native.subject(id: 1)
    XCTAssertNil(cleared?.interest)
    XCTAssertEqual(cleared?.images?.large, "image")
  }

  func testLargeEpisodePruningUsesCompleteKeepSetForBothImplementations() async throws {
    let lib = try library()
    for useCore in [false, true] {
      let dir = directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let pool = try BangumiDatabaseFactory.makeDatabase(at: dir)
      let store = BangumiDatabaseOperator(
        database: pool, coreLibraryPath: useCore ? lib : nil, coreEnabled: useCore)
      try await store.saveSubject(BangumiFixture.subject(id: 1, eps: 1905, epStatus: 0))
      let episodes = (1...1905).map {
        BangumiFixture.episode(id: $0, subjectID: 1, sort: Float($0))
      }
      try await store.saveEpisodes(subjectId: 1, items: episodes)
      try await store.saveSubject(BangumiFixture.subject(id: 2, eps: 1, epStatus: 0))
      try await store.saveEpisodes(
        subjectId: 2, items: [BangumiFixture.episode(id: 2000, subjectID: 2, sort: 1)])
      let keep = Set(1...1701)
      try await store.deleteEpisodesNotIn(subjectId: 1, episodeIds: keep)
      let retained = try await store.fetchEpisodes(subjectId: 1)
      XCTAssertEqual(Set(retained.map(\.id)), keep)
      let unaffected = try await store.fetchEpisodes(subjectId: 2)
      XCTAssertEqual(unaffected.map(\.id), [2000])
      try await store.replaceEpisodes(
        subjectId: 1, items: [episodes[0], episodes[1700]], authoritativeCollection: true)
      let replaced = try await store.fetchEpisodes(subjectId: 1)
      XCTAssertEqual(replaced.map(\.id), [1, 1701])
    }
  }

  func testFractionalBatchThresholdAndWatchedCountDoNotRegress() async throws {
    let lib = try library()
    for useCore in [false, true] {
      let dir = directory()
      defer { try? FileManager.default.removeItem(at: dir) }
      let pool = try BangumiDatabaseFactory.makeDatabase(at: dir)
      let store = BangumiDatabaseOperator(
        database: pool, coreLibraryPath: useCore ? lib : nil, coreEnabled: useCore)
      try await store.saveSubject(BangumiFixture.subject(id: 1, eps: 12, epStatus: 12))
      try await store.saveEpisodes(
        subjectId: 1,
        items: [
          BangumiFixture.episode(id: 1, subjectID: 1, sort: 0.5),
          BangumiFixture.episode(id: 2, subjectID: 1, sort: 0.7),
        ])
      _ = try await store.updateEpisodeCollection(episodeId: 2, type: .collect, batch: true)
      let watched = try await store.fetchEpisodes(subjectId: 1)
      XCTAssertTrue(
        watched.allSatisfy { $0.collection?.status == 2 },
        "batch includes the selected fractional episode")
      let subject = try await store.subject(id: 1)
      XCTAssertEqual(subject?.interest?.epStatus, 12)
      _ = try await store.updateEpisodeCollection(episodeId: 2, type: .none)
      let revoked = try await store.subject(id: 1)
      XCTAssertEqual(revoked?.interest?.epStatus, 1)
    }
  }

  func testMalformedJSONBlobsUseTheSameFallbacksAcrossClients() async throws {
    let lib = try library(), dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pool = try BangumiDatabaseFactory.makeDatabase(at: dir)
    let native = BangumiDatabaseOperator(database: pool, coreEnabled: false)
    let shared = BangumiDatabaseOperator(database: pool, coreLibraryPath: lib)
    try await native.saveSubject(BangumiFixture.subject(id: 1, eps: 12, epStatus: 5))
    try await pool.write { db in
      try db.execute(sql: "UPDATE subjects SET airtime_data=?, collection_data=?, images_data=?, infobox_data=?, meta_tags_data=?, tags_data=?, platform_data=?, rating_data=?, interest_data=? WHERE subject_id=1",
        arguments: [Data("[]".utf8), Data(#"{"doing":"bad"}"#.utf8), Data(#""bad""#.utf8),
          Data(#"[{"value":"missing key"}]"#.utf8), Data("[2]".utf8), Data("[[]]".utf8), Data(#"{"alias":3}"#.utf8),
          Data("[]".utf8), Data(#"{"type":3}"#.utf8)])
    }
    let expected = try await native.subject(id: 1)
    let actual = try await shared.subject(id: 1)
    XCTAssertEqual(actual, expected)
  }

  func testRustCreatedDatabaseLoadsThroughGRDBAndNewSlimDefaultsDecode() async throws {
    let lib = try library()
    let dir = directory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let core = try OcpCoreClient(
      config: ["bangumiDatabasePath": dir.appendingPathComponent("Bangumi.sqlite").path],
      libraryPath: lib)
    let response = try core.call(
      "bangumiStore.saveSlimSubject", arguments: ["item": ["id": 1, "name": "minimal", "type": 2]])
    XCTAssertTrue(response.ok)
    let pool = try BangumiDatabaseFactory.makeDatabase(at: dir)
    let native = BangumiDatabaseOperator(database: pool, coreEnabled: false)
    let subject = try await native.subject(id: 1)
    XCTAssertEqual(subject?.name, "minimal")
    XCTAssertEqual(subject?.platform, BangumiSubjectPlatform(name: ""))
  }
}
