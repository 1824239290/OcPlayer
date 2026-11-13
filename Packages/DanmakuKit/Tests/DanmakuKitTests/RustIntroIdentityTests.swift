import Foundation
import OcPlayerCore
import XCTest
@testable import DanmakuKit

final class RustIntroIdentityTests: XCTestCase {
    private func policy() throws -> RustDanmakuPolicy {
        guard let policy = RustDanmakuPolicy.active else { throw XCTSkip("Enable Core for identity comparisons") }
        return policy
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSearchTitlesAndSHAKeysMatchNativeUnicodeRules() throws {
        _ = try policy()
        let titles = ["ＡＢＣ", "作品名稱", "作品名称", "二十世紀電氣目録", "ΟΣ", "ΟΣΑ", "İstanbul", "Cafe\u{301}", "！？", "\u{feff}Title", "A\u{20dd}"]
        let spaces = ["", " ", "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}", "\u{200b}", "\u{3000}"]
        for index in 0..<900 {
            let title = spaces[index % spaces.count] + titles[index % titles.count] + spaces[(index + 1) % spaces.count]
            let identity = AniSkipAnimeIdentity(malID: index % 2 == 0 ? Int.max : nil,
                anilistID: index % 3 == 0 ? Int.max : nil, title: title,
                alternativeTitles: [titles[(index + 1) % titles.count], title.lowercased(), "\n！？", titles[(index + 2) % titles.count]],
                seasonNumber: index % 4 == 0 ? nil : index % 7, year: index % 5 == 0 ? nil : 2026)
            XCTAssertEqual(identity.searchTitles, identity.searchTitlesNative, "titles \(index)")
            XCTAssertEqual(AniSkipIDResolver.cacheKey(for: identity), AniSkipIDResolver.cacheKeyNative(for: identity), "key \(index)")
        }
    }

    func testBestMatchAgainstNativeAtGraphemeAndIDBoundaries() throws {
        _ = try policy()
        let queries = ["作品名称第季", "作品名称", "longquery", "Re", "ΟΣＡ作品名称", "ＡＢＣＤＥＦ", "！？", "a\u{301}bcdef"]
        for index in 0..<900 {
            let query = queries[index % queries.count]
            let media = (0..<6).map { candidate in
                AniListClient.SearchMedia(anilistID: Int.max - candidate, idMal: candidate == index % 6 ? nil : (candidate == 0 ? 0 : candidate),
                    native: candidate == index % 5 ? query : query + " extra",
                    romaji: nil, english: candidate == index % 4 ? query.uppercased() : "wrong",
                    synonyms: candidate == index % 3 ? [query] : [])
            }
            let native = AniListClient.bestMatchNative(in: media, for: query)
            let shared = AniListClient.bestMatch(in: media, for: query)
            XCTAssertEqual(native?.media.anilistID, shared?.media.anilistID, "candidate \(index)")
            XCTAssertEqual(native?.media.idMal, shared?.media.idMal)
            XCTAssertEqual(native?.rule, shared?.rule)
        }
    }

    func testPlanSevenDayBoundaryDirectAndPositiveZeroID() throws {
        let policy = try policy()
        let identity = AniSkipAnimeIdentity(title: "作品名稱")
        let empty = AniSkipIDRecord(malID: nil, resolvedAt: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertNotNil(policy.identityPlan(identity, record: empty, force: false, now: Date(timeIntervalSinceReferenceDate: 604799)).ready)
        XCTAssertNil(policy.identityPlan(identity, record: empty, force: false, now: Date(timeIntervalSinceReferenceDate: 604800)).ready)
        XCTAssertNil(policy.identityPlan(identity, record: empty, force: true, now: Date(timeIntervalSinceReferenceDate: 0)).ready)
        let zero = AniSkipIDRecord(malID: 0, anilistID: -1, resolvedAt: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(policy.identityPlan(identity, record: zero, force: false, now: Date(timeIntervalSinceReferenceDate: 1e9)).ready,
                       AniSkipResolvedIDs(malID: 0, anilistID: -1))
        let direct = policy.identityPlan(AniSkipAnimeIdentity(malID: 1, anilistID: -1), record: empty, force: true, now: Date())
        XCTAssertNil(direct.cacheKey)
        XCTAssertEqual(direct.ready, AniSkipResolvedIDs(malID: 1, anilistID: -1))
    }

    func testNativeAndCoreStoreInteroperabilityAndCachedEmptyRepair() async throws {
        _ = try policy()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let native = AniSkipIDStore(directory: dir, useCore: false)
        let shared = AniSkipIDStore(directory: dir, useCore: true)
        let activated = await shared.usesCoreIDs
        XCTAssertTrue(activated)
        let record = AniSkipIDRecord(malID: Int.max, anilistID: Int.max - 1, resolvedAt: Date(timeIntervalSinceReferenceDate: 777.125))
        await native.setRecord(record, for: "native")
        let read = await shared.record(for: "native")
        XCTAssertEqual(read, record)
        await shared.setRecord(record, for: "shared")
        let reopened = AniSkipIDStore(directory: dir, useCore: false)
        let back = await reopened.record(for: "shared")
        XCTAssertEqual(back, record)
        let file = dir.appendingPathComponent("aniskip-ids.json")
        try Data("{".utf8).write(to: file)
        let corrupted = AniSkipIDStore(directory: dir, useCore: true)
        let missing = await corrupted.record(for: "shared")
        XCTAssertNil(missing)
        try JSONEncoder().encode(["shared": record]).write(to: file)
        let stillMissing = await corrupted.record(for: "shared")
        XCTAssertNil(stillMissing)
        await corrupted.setRecord(record, for: "repair")
        let map = try JSONDecoder().decode([String: AniSkipIDRecord].self, from: Data(contentsOf: file))
        XCTAssertEqual(Set(map.keys), ["repair"])
    }

    func testStoreWritesThroughMemoryWhenAtomicWriteFails() async throws {
        _ = try policy()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("aniskip-ids.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let shared = AniSkipIDStore(directory: dir, useCore: true)
        let native = AniSkipIDStore(directory: dir, useCore: false)
        let record = AniSkipIDRecord(malID: 42, resolvedAt: Date(timeIntervalSinceReferenceDate: 10))
        await shared.setRecord(record, for: "shared")
        await native.setRecord(record, for: "native")
        let a = await shared.record(for: "shared")
        let b = await native.record(for: "native")
        XCTAssertEqual(a, b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    #if os(macOS)
    private final class Fixture {
        let process = Process()
        let base: URL
        init() throws {
            guard OcpCoreFeature.isEnabled, ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] != nil else {
                throw XCTSkip("Enable Core with its library path for identity HTTP fixtures")
            }
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", Bundle.module.url(forResource: "intro_provider_server", withExtension: "py", subdirectory: "Fixtures")!.path]
            process.standardOutput = pipe
            try process.run()
            let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        deinit { if process.isRunning { process.terminate() } }
        struct Record: Decodable { let path, method, body: String; let port: Int }
        func records() async throws -> [Record] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try JSONDecoder().decode([Record].self, from: data)
        }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ seconds: Double) { date = Date(timeIntervalSinceReferenceDate: seconds) }
        var value: Date {
            get { lock.withLock { date } }
            set { lock.withLock { date = newValue } }
        }
    }

    func testCompleteNetworkResolverMatchesNativeOrderedFlow() async throws {
        let f = try Fixture()
        let client = AniListClient(session: DanmakuNetworking.makeSession(), baseURL: f.base)
        XCTAssertTrue(client.usesCoreTransport)
        let cases = [["first", "later"], ["bad", "http503", "later"], ["contained-one", "later"], ["exact-last"], ["short"], ["no-mal", "empty"]]
        for titles in cases {
            let shared = await client.resolveIDs(anilistID: nil, searchTitles: titles)
            let native = await client.resolveIDsNative(anilistID: nil, searchTitles: titles)
            XCTAssertEqual(shared, native, "titles \(titles)")
        }
        for id in [42, 404, 503, 99, Int.max, -1, 0] {
            let shared = await client.resolveIDs(anilistID: id, searchTitles: [])
            let native = await client.resolveIDsNative(anilistID: id, searchTitles: [])
            XCTAssertEqual(shared, native, "lookup \(id)")
        }
        let records = try await f.records()
        XCTAssertEqual(Set(records.map(\.port)).count, 1)
    }

    func testStoredResolverActivationCacheForceAndPostRequestClock() async throws {
        let f = try Fixture()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(0)
        let store = AniSkipIDStore(directory: dir, useCore: true)
        let resolver = AniSkipIDResolver(store: store, now: { clock.value }, baseURL: f.base.appendingPathComponent("slow"))
        let active = await resolver.usesCoreResolution
        XCTAssertTrue(active)
        let identity = AniSkipAnimeIdentity(anilistID: 42)
        let task = Task { await resolver.resolve(for: identity) }
        for _ in 0..<100 {
            if !(try await f.records()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        clock.value = Date(timeIntervalSinceReferenceDate: 123.75)
        let result = await task.value
        XCTAssertEqual(result, AniSkipResolvedIDs(malID: 100000, anilistID: 42))
        let saved = await store.record(for: AniSkipIDResolver.cacheKey(for: identity))
        XCTAssertEqual(saved?.resolvedAt, clock.value)
        let cached = await resolver.resolve(for: identity)
        XCTAssertEqual(cached, result)
        let first = try await f.records()
        XCTAssertEqual(first.count, 1)
        let refreshed = await resolver.resolve(for: identity, forceRefresh: true)
        XCTAssertEqual(refreshed, result)
        let last = try await f.records()
        XCTAssertEqual(last.count, 2)
    }

    func testCancelStoredResolutionDoesNotWriteNegativeCache() async throws {
        let f = try Fixture()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AniSkipIDStore(directory: dir, useCore: true)
        let resolver = AniSkipIDResolver(store: store, baseURL: f.base.appendingPathComponent("slow"))
        let identity = AniSkipAnimeIdentity(title: "first", alternativeTitles: ["later"])
        let task = Task { await resolver.resolve(for: identity) }
        for _ in 0..<100 {
            if !(try await f.records()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.isEmpty)
        let empty = await store.record(for: AniSkipIDResolver.cacheKey(for: identity))
        XCTAssertNil(empty)
        let records = try await f.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("aniskip-ids.json").path))
        let next = AniSkipIDResolver(store: store, baseURL: f.base)
        let successful = await next.resolve(for: identity)
        XCTAssertEqual(successful, AniSkipResolvedIDs(malID: 78, anilistID: 56))
    }
    #endif
}
