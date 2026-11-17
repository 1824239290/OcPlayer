import Foundation
import GRDB
import OcPlayerCore
import XCTest
@testable import BangumiKit

#if os(macOS)
final class RustBangumiSyncTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for retained Bangumi sync integration")
        }
        return path
    }
    private struct Fixture: Codable {
        var subjects: [BangumiSubjectDTO]
        var episodes: [String: [BangumiEpisodeDTO]]
    }
    private func fixture() -> Fixture {
        Fixture(subjects: (1...3).map { BangumiFixture.subject(id: $0, eps: $0 == 1 ? 1001 : 1, epStatus: 0) },
            episodes: ["1": [BangumiFixture.episode(id: Int.max - 1, subjectID: 1, sort: 1, status: .collect),
                BangumiFixture.episode(id: 42, subjectID: 1, sort: 2)],
                "3": [BangumiFixture.episode(id: 31, subjectID: 3, sort: 1)]])
    }
    private func database(_ directory: URL, shared: Bool = true) throws -> BangumiDatabaseOperator {
        BangumiDatabaseOperator(database: try BangumiDatabaseFactory.makeDatabase(at: directory),
            coreLibraryPath: shared ? try library() : nil, coreEnabled: shared)
    }
    private func client(_ directory: URL) throws -> BangumiAPIClient {
        let defaults = UserDefaults(suiteName: "bangumi-sync-\(UUID().uuidString)")!
        return BangumiAPIClient(store: BangumiStore(defaults: defaults, credentialsDirectory: directory), rustCoreLibraryPath: try library())
    }
    private func dependencies(_ db: BangumiDatabaseOperator, server: SyncServer, client: BangumiAPIClient,
                              stamps: Stamps, failPage: Bool = false, slow: Bool = false) -> RustBangumiSync.Dependencies {
        .init(collections: { since, limit, offset in
            let data = try await client.request(url: server.url("\(failPage ? "collections-fail" : "collections")?since=\(since)&limit=\(limit)&offset=\(offset)"), method: "GET", auth: .disabled)
            return try await client.decodeResponse(data)
        }, episodes: { subject, limit, offset in
            let data = try await client.request(url: server.url("episodes/\(subject)?limit=\(limit)&offset=\(offset)\(slow ? "&slow=1" : "")"), method: "GET", auth: .disabled)
            return try await client.decodeResponse(data)
        }, targets: { try await db.fetchEpisodeSyncTargets() }, timestamp: { stamps.values.append($0) }, validate: {})
    }
    private func active(_ sync: RustBangumiSync) throws -> Int {
        struct Stats: Decodable { var active: Int }
        return try sync.core.call("bangumiSync.stats").decodeData(Stats.self).active
    }
    func testFullSyncUsesRealHTTPPaginationPartialFailureAndNativeDatabaseParity() async throws {
        _ = try library()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-\(UUID().uuidString)")
        let sample = fixture()
        let server = try SyncServer(fixture: JSONEncoder().encode(sample)); defer { server.stop() }
        let db = try database(directory)
        if OcpCoreFeature.isEnabled {
            let automatic = BangumiDatabaseOperator(database: try BangumiDatabaseFactory.makeDatabase(at: directory))
            XCTAssertNotNil(automatic.sync)
        }
        let native = try database(directory.appendingPathComponent("native"), shared: false)
        let sync = try XCTUnwrap(db.sync)
        let stamps = await Stamps()
        let deps = dependencies(db, server: server, client: try client(directory), stamps: stamps)
        let count: Int = try await sync.run(.init(operation: "allCollections", since: 1500, startedAt: 900,
            force: true, maxConcurrent: 2, authoritativeCollection: true), dependencies: deps)
        XCTAssertEqual(count, 3)
        let stamped = await stamps.values
        XCTAssertEqual(stamped, [0, 900])
        try await native.saveSubjects(sample.subjects, authoritativeInterest: true)
        for key in ["1", "3"] { try await native.replaceEpisodes(subjectId: Int(key)!, items: sample.episodes[key]!, authoritativeCollection: true) }
        for id in 1...3 {
            let actual = try await db.subject(id: id), expected = try await native.subject(id: id)
            XCTAssertEqual(actual, expected)
            let actualEpisodes = try await db.fetchEpisodes(subjectId: id), expectedEpisodes = try await native.fetchEpisodes(subjectId: id)
            XCTAssertEqual(actualEpisodes, expectedEpisodes)
        }
        let state = try await server.stats()
        XCTAssertEqual(state.peak, 2)
        XCTAssertTrue(state.requests.contains { $0.contains("/collections?since=0&limit=100&offset=100") })
        XCTAssertTrue(state.requests.contains { $0.contains("/episodes/1?limit=1000&offset=1000") })
        XCTAssertEqual(try active(sync), 0)
    }
    func testPageFailurePreservesCommittedPageAndDoesNotAdvanceTimestamp() async throws {
        _ = try library()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-failure-\(UUID().uuidString)")
        let server = try SyncServer(fixture: JSONEncoder().encode(fixture())); defer { server.stop() }
        let db = try database(directory), sync = try XCTUnwrap(db.sync)
        let stamps = await Stamps()
        let deps = dependencies(db, server: server, client: try client(directory), stamps: stamps, failPage: true)
        do {
            let _: Int = try await sync.run(.init(operation: "allCollections", since: 1000, startedAt: 900, force: true), dependencies: deps)
            XCTFail("Second page must fail")
        } catch { XCTAssertTrue(error is BangumiError) }
        let values = await stamps.values
        XCTAssertEqual(values, [0])
        let first = try await db.subject(id: 1), third = try await db.subject(id: 3)
        XCTAssertNotNil(first); XCTAssertNil(third)
        XCTAssertEqual(try active(sync), 0)
    }
    func testClearDuringEpisodeReadRejectsThePendingTransactionalWrite() async throws {
        _ = try library()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-retire-\(UUID().uuidString)")
        let server = try SyncServer(fixture: JSONEncoder().encode(fixture())); defer { server.stop() }
        let db = try database(directory), sync = try XCTUnwrap(db.sync)
        try await db.saveSubject(fixture().subjects[0])
        let stamps = await Stamps()
        let deps = dependencies(db, server: server, client: try client(directory), stamps: stamps, slow: true)
        let task = Task { let value: Bool = try await sync.run(.init(operation: "episodes", authoritativeCollection: true, subjectId: 1), dependencies: deps); return value }
        try await server.waitForEpisodes(1)
        try await db.clearAccountLocalState()
        do { _ = try await task.value; XCTFail("Retired write must fail") }
        catch { XCTAssertTrue(error is BangumiError) }
        let episodes = try await db.fetchEpisodes(subjectId: 1), subject = try await db.subject(id: 1)
        XCTAssertTrue(episodes.isEmpty); XCTAssertNil(subject)
        XCTAssertEqual(try active(sync), 0)
    }
    func testBatchCancellationStopsQueuedWorkAndRetiresAllChildren() async throws {
        _ = try library()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-cancel-\(UUID().uuidString)")
        let server = try SyncServer(fixture: JSONEncoder().encode(fixture())); defer { server.stop() }
        let db = try database(directory), sync = try XCTUnwrap(db.sync)
        try await db.saveSubjects(fixture().subjects)
        let stamps = await Stamps()
        let deps = dependencies(db, server: server, client: try client(directory), stamps: stamps, slow: true)
        let task = Task { let value: Int = try await sync.run(.init(operation: "reconcile", maxConcurrent: 2), dependencies: deps); return value }
        try await server.waitForEpisodes(2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled batch must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try active(sync), 0)
        let state = try await server.stats()
        XCTAssertFalse(state.requests.contains { $0.hasPrefix("/episodes/3") })
    }
    func testNativeAndCoreDatabaseRevisionGuardsRejectRetiredWrites() async throws {
        _ = try library()
        for shared in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-native-guard-\(UUID().uuidString)")
            let db = try database(directory, shared: shared)
            let revision = await db.captureSyncRevision()
            try await db.clearAccountLocalState()
            do { try await db.saveSubjects(fixture().subjects, ifCurrentSyncRevision: revision); XCTFail("Retired subject write must fail") }
            catch { XCTAssertTrue(error is BangumiError) }
            do { try await db.replaceEpisodes(subjectId: 1, items: fixture().episodes["1"]!, ifCurrentSyncRevision: revision); XCTFail("Retired episode write must fail") }
            catch { XCTAssertTrue(error is BangumiError) }
            let rows = try await db.fetchEpisodes(subjectId: 1)
            XCTAssertTrue(rows.isEmpty)
        }
    }
}
@MainActor private final class Stamps { var values: [Int] = [] }
private final class SyncServer: @unchecked Sendable {
    struct Stats: Decodable { var requests: [String]; var peak: Int }
    let process = Process()
    let root: URL
    init(fixture: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-wire-\(UUID().uuidString).json")
        try fixture.write(to: file)
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "bangumi_sync_server", withExtension: "py", subdirectory: "Fixtures")!.path, file.path]
        process.standardOutput = pipe
        try process.run()
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        root = URL(string: "http://127.0.0.1:\(port)")!
    }
    func url(_ path: String) -> URL { URL(string: root.absoluteString + "/" + path)! }
    func stats() async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: url("stats"))
        return try JSONDecoder().decode(Stats.self, from: data)
    }
    func waitForEpisodes(_ count: Int) async throws {
        for _ in 0..<200 {
            if try await stats().requests.filter({ $0.hasPrefix("/episodes/") }).count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OcpCoreError(message: "Sync fixture requests did not start")
    }
    func stop() { if process.isRunning { process.terminate() } }
}
#endif
