import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

#if os(macOS)
  final class RustTMDbEnrichmentTests: XCTestCase {
    private struct Credential: TMDbCredentialProviding { func apiKey() -> String? { "fixture" } }
    private final class Server {
      let process = Process()
      let base: URL
      init() throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
          "-u",
          try XCTUnwrap(
            Bundle.module.url(
              forResource: "tmdb_enrichment_server", withExtension: "py", subdirectory: "Fixtures")
          ).path,
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        base = URL(string: "http://127.0.0.1:\(port)")!
      }
      deinit {
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
    }
    private final class Harness {
      let dir: TemporaryDirectory
      let isShared: Bool
      let store: MetadataStore
      let enricher: TMDbEnricher
      let tenant = TenantID(rawValue: "fixture:user")
      let defaults: UserDefaults
      init(server: Server, shared: Bool, library: String) throws {
        isShared = shared
        dir = try TemporaryDirectory()
        store = MetadataStore(
          database: try MetadataDatabaseFactory.makeDatabase(at: dir.url),
          coreLibraryPath: shared ? library : nil, coreEnabled: shared)
        defaults = UserDefaults(suiteName: "TMDbEnrichment-\(UUID().uuidString)")!
        let prefs = TMDbPreferences(defaults: defaults)
        prefs.language = "en-US"
        let base = server.base.appendingPathComponent(shared ? "shared" : "native")
        let client = TMDbClient(
          session: .shared, credentials: Credential(),
          limiter: TMDbRateLimiter(maxConcurrent: 4, minimumInterval: 0),
          endpointProvider: { .init(apiBaseURL: base, imageBaseURL: base) },
          rustCoreLibraryPath: shared ? library : nil, useSharedCore: shared)
        enricher = TMDbEnricher(
          client: client, store: store, preferences: prefs,
          rustCoreLibraryPath: shared ? library : nil, useSharedCore: shared)
        XCTAssertEqual(client.usesCoreTransport, shared)
      }
      deinit { dir.cleanUp() }
    }
    private func equal<T: Equatable>(
      _ value: T, _ expected: T, _ message: String = "", file: StaticString = #filePath,
      line: UInt = #line
    ) { XCTAssertEqual(value, expected, message, file: file, line: line) }
    private func isTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertTrue(value, file: file, line: line)
    }
    private func isFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertFalse(value, file: file, line: line)
    }
    private func isNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertNil(value, file: file, line: line)
    }
    private func library() throws -> String {
      guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
        throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for enrichment differential HTTP tests")
      }
      return path
    }
    private func pair(_ server: Server) throws -> [Harness] {
      let path = try library()
      return try [
        Harness(server: server, shared: false, library: path),
        Harness(server: server, shared: true, library: path),
      ]
    }
    private func movie(_ id: String, provider: Int? = nil) -> MediaItem {
      var item = MediaItem(id: id, name: "作品", kind: .movie)
      item.year = 2024
      if let provider { item.tmdbID = String(provider) }
      return item
    }
    private struct Record: Decodable {
      let path: String
      let query: [String: [String]]
    }
    private func records(_ server: Server) async throws -> [Record] {
      let (data, _) = try await URLSession.shared.data(
        from: server.base.appendingPathComponent("stats"))
      return try JSONDecoder().decode([Record].self, from: data)
    }
    private func assertTraceParity(_ server: Server) async throws {
      let rows = try await records(server)
      func trace(_ prefix: String) -> [String] {
        rows.filter { $0.path.hasPrefix(prefix) }.map { row in
          String(row.path.dropFirst(prefix.count)) + " "
            + row.query.keys.sorted().map { key in
              key + "=" + row.query[key]!.joined(separator: ",")
            }.joined(separator: "&")
        }.sorted()
      }
      XCTAssertEqual(trace("/shared"), trace("/native"))
    }

    func testCompleteRefreshAuthorityFreshnessSearchAndFailureModelsMatchNative() async throws {
      _ = try library()
      let server = try Server()
      for h in try pair(server) {
        let active = await h.enricher.usesCoreEnrichment
        XCTAssertEqual(active, h.isShared)
        let provider = movie("provider", provider: 1)
        equal(await h.enricher.performRefresh(item: provider, tenant: h.tenant), .fetched)
        equal(await h.enricher.performRefresh(item: provider, tenant: h.tenant), .skipped)
        let search = movie("search")
        equal(await h.enricher.performRefresh(item: search, tenant: h.tenant), .fetched)
        let guess = movie("upgrade", provider: 1)
        try await h.store.saveTMDbLink(
          itemID: guess.id, entityKey: .movie(2), source: .search, confidence: 0.95,
          tenant: h.tenant)
        try await h.store.saveTMDbPayload(
          .entity(.init(id: 2, mediaType: .movie, title: "Old")), key: .movie(2), language: "en-US",
          lifetime: 0, now: Date().addingTimeInterval(-86400))
        equal(await h.enricher.performRefresh(item: guess, tenant: h.tenant), .fetched)
        let link = try await h.store.tmdbLink(itemID: guess.id, tenant: h.tenant)
        XCTAssertEqual(link?.entityKey, .movie(1))
        XCTAssertEqual(link?.source, .providerID)
        let manual = movie("manual", provider: 1)
        try await h.store.saveTMDbLink(
          itemID: manual.id, entityKey: .movie(500), source: .manual, confidence: 1,
          tenant: h.tenant)
        let stale = TMDbEntity(id: 500, mediaType: .movie, title: "Stale")
        try await h.store.saveTMDbPayload(
          .entity(stale), key: .movie(500), language: "en-US", lifetime: 0,
          now: Date().addingTimeInterval(-86400))
        equal(
          await h.enricher.performRefresh(item: manual, tenant: h.tenant), .fetched,
          "Existing payload remains usable after a failed refresh")
        equal(
          try await h.store.tmdbPayload(key: .movie(500), language: "en-US")?.payload,
          .entity(stale))
        equal(await h.enricher.reportedFailure(), .http(status: 500))
      }
      try await assertTraceParity(server)
    }

    func testCollectionResolutionBudgetManualBindingAndExactCacheIDsMatchNative() async throws {
      _ = try library()
      let server = try Server()
      for h in try pair(server) {
        let box = MediaItem(id: "box", name: "Collection", kind: .boxSet)
        let members = [movie("none", provider: 2), movie("found", provider: 1)]
        equal(
          await h.enricher.refreshCollection(item: box, members: members, tenant: h.tenant),
          .fetched)
        equal(
          await h.enricher.refreshCollection(item: box, members: members, tenant: h.tenant),
          .skipped)
        equal(await h.enricher.link(for: box.id, tenant: h.tenant)?.entityKey, .collection(10))
        let big = Int.max
        isTrue(
          await h.enricher.bindManually(itemID: "exact", entityKey: .movie(big), tenant: h.tenant))
        let exact = try await h.store.tmdbPayload(key: .movie(big), language: "en-US")
        guard case .entity(let entity) = exact?.payload else {
          return XCTFail("Missing exact payload")
        }
        XCTAssertEqual(entity.id, big)
        XCTAssertEqual(entity.collectionID, big - 1)
        let manual = await h.enricher.link(for: "exact", tenant: h.tenant)
        XCTAssertEqual(manual?.source, .manual)
        let budget = [2, 3, 4, 1].enumerated().map {
          movie("budget\($0.offset)", provider: $0.element)
        }
        equal(
          await h.enricher.refreshCollection(
            item: .init(id: "budget", name: "Budget", kind: .boxSet), members: budget,
            tenant: h.tenant), .noMatch)
        equal(
          await h.enricher.refreshCollection(
            item: .init(id: "failed", name: "Failed", kind: .boxSet),
            members: [movie("fail", provider: 500)], tenant: h.tenant), .failed)
        equal(
          await h.enricher.refreshCollection(
            item: .init(id: "mixed", name: "Mixed", kind: .boxSet),
            members: [movie("fail", provider: 500), movie("none", provider: 2)], tenant: h.tenant),
          .noMatch)
      }
      try await assertTraceParity(server)
    }

    func testBatchAiringSeasonRefreshUnsupportedCountsAndResumeMatchNative() async throws {
      _ = try library()
      let server = try Server()
      var results: [TMDbBatchResult] = []
      for h in try pair(server) {
        var series = MediaItem(id: "series", name: "作品", kind: .series)
        series.tmdbID = "10"
        let entity = TMDbEntity(
          id: 10, mediaType: .tv, title: "作品",
          seasons: [.init(seasonNumber: 0), .init(seasonNumber: 1)])
        let old = Date().addingTimeInterval(-10 * 86400)
        try await h.store.saveTMDbLink(
          itemID: series.id, entityKey: .tv(10), source: .providerID, confidence: 1,
          tenant: h.tenant)
        try await h.store.saveTMDbPayload(
          .entity(entity), key: .tv(10), language: "en-US", lifetime: 90 * 86400)
        for number in [0, 1] {
          let season = TMDbSeason(
            seasonNumber: number,
            episodes: [.init(episodeNumber: 1, airDate: number == 0 ? nil : "2000-01-01")])
          try await h.store.saveTMDbPayload(
            .season(season), key: .season(tvID: 10, number: number), language: "en-US",
            lifetime: 90 * 86400, now: old)
        }
        let items = [
          movie("movie", provider: 1), series, .init(id: "other", name: "Other", kind: .folder),
        ]
        let result = await h.enricher.enrichAll(items: items, tenant: h.tenant)
        XCTAssertEqual(result.processed, 3)
        XCTAssertEqual(result.enriched, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.seasons, 1)
        results.append(result)
        let resumed = await h.enricher.enrichAll(items: items, tenant: h.tenant)
        XCTAssertEqual(resumed.processed, 3)
        XCTAssertEqual(resumed.skipped, 2)
        XCTAssertEqual(resumed.seasons, 0)
      }
      XCTAssertEqual(results.first, results.last)
      try await assertTraceParity(server)
    }

    func testCancellationInProgressStopsRefillAndDrainsFourEnteredWorkers() async throws {
      _ = try library()
      let server = try Server()
      var results: [TMDbBatchResult] = []
      for h in try pair(server) {
        let items = (0..<20).map { movie("cancel\($0)", provider: 200 + $0) }
        let enricher = h.enricher
        let tenant = h.tenant
        let task = Task {
          await enricher.enrichAll(items: items, tenant: tenant) { progress in
            if progress.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
          }
        }
        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.processed, 4)
        XCTAssertEqual(result.enriched, 4)
        results.append(result)
      }
      XCTAssertEqual(results.first, results.last)
      try await assertTraceParity(server)
    }

    func testSingleFlightLanguageIsolationFailureAndRetirementMatchNative() async throws {
      _ = try library()
      let server = try Server()
      for h in try pair(server) {
        let enricher = h.enricher
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
          for _ in 0..<10 {
            group.addTask { await enricher.fetchAndStore(key: .movie(200), language: "en-US") }
          }
          var values: [Bool] = []
          for await value in group { values.append(value) }
          return values
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        isTrue(await h.enricher.fetchAndStore(key: .movie(200), language: "zh-CN"))
        isFalse(await h.enricher.fetchAndStore(key: .movie(401)))
        equal(await h.enricher.reportedFailure(), .unauthorized)
        isTrue(await h.enricher.fetchAndStore(key: .movie(1)))
        isNil(await h.enricher.reportedFailure())
      }
      let rows = try await records(server)
      for prefix in ["/native", "/shared"] {
        let same = rows.filter { $0.path == prefix + "/movie/200" }
        XCTAssertEqual(same.count, 2)
        XCTAssertEqual(Set(same.compactMap { $0.query["language"]?.first }), ["en-US", "zh-CN"])
      }
      try await assertTraceParity(server)
    }

    func testAiringAndFreshnessDecisionsMatchNativeAcrossCompleteDateCases() throws {
      let path = try library()
      let core = try XCTUnwrap(RustTMDbEnricher.make(libraryPath: path))
      let now = Date()
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      formatter.locale = Locale(identifier: "en_US_POSIX")
      let dates: [String?] = [
        nil, "", "invalid", "2026-13-45", "2000-01-01", formatter.string(from: now),
        formatter.string(from: now.addingTimeInterval(86400)),
        formatter.string(from: now.addingTimeInterval(-3 * 86400)),
      ]
      for a in dates {
        for b in dates {
          let season = TMDbSeason(
            seasonNumber: 0,
            episodes: [.init(episodeNumber: 1, airDate: a), .init(episodeNumber: 2, airDate: b)])
          XCTAssertEqual(
            try core.policy("airing", cache: .init(season: season, now: now)),
            season.nativeIsAiring(now: now))
          for age in [0.0, 86399.0, 86400.0, 86401.0, 10 * 86400.0] {
            let cached = CachedTMDbPayload(
              payload: .season(season), fetchedAt: now.addingTimeInterval(-age),
              expiresAt: now.addingTimeInterval(90 * 86400))
            XCTAssertEqual(
              try core.policy("fresh", cache: .init(cached, now: now)),
              TMDbEnricher.nativeIsFresh(cached, now: now))
          }
        }
      }
    }
  }
#endif
