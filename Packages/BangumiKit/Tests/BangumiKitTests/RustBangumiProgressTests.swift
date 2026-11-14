import Foundation
import GRDB
import OcPlayerCore
import XCTest
@testable import BangumiKit

#if os(macOS)
final class RustBangumiProgressTests: XCTestCase {
    private struct Fixture: Codable {
        var subject: BangumiSubjectDTO
        var episodes: [BangumiEpisodeDTO]
    }
    private func sample(id: Int = 1, status: BangumiEpisodeCollectionType = .none) -> Fixture {
        Fixture(subject: BangumiFixture.subject(id: id, eps: 2, epStatus: 0, collectedAt: 1),
            episodes: [BangumiFixture.episode(id: Int.max - 1, subjectID: id, sort: 1, status: status),
                BangumiFixture.episode(id: 42, subjectID: id, sort: 2, status: status)])
    }
    private func database(shared: Bool = true) throws -> BangumiDatabaseOperator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-progress-\(UUID().uuidString)")
        var path: String?
        if shared {
            guard let library = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
                throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for Bangumi progress integration")
            }
            path = library
        }
        return BangumiDatabaseOperator(database: try BangumiDatabaseFactory.makeDatabase(at: directory), coreLibraryPath: path, coreEnabled: shared)
    }
    private func active(_ progress: RustBangumiProgress) throws -> Int {
        struct Stats: Decodable { var active: Int }
        return try progress.core.call("bangumiProgress.stats").decodeData(Stats.self).active
    }
    private func dependencies(_ db: BangumiDatabaseOperator, server: ProgressServer, events: ProgressEvents,
                              readFailure: Bool = false, watchingFailure: Bool = false) async -> RustBangumiProgress.Dependencies {
        let revision = await db.captureSyncRevision()
        return .init(validate: {
            guard db.isCurrentWorkRevision(revision) else { throw BangumiError(ignore: "Retired fixture") }
        }, subject: { _ in try await server.get(readFailure ? "subject-fail" : "subject") },
        lookup: { _ in
            do { let interest: BangumiSubjectInterest = try await server.get("lookup"); return .collected(interest) }
            catch { return .unknown(String(describing: error)) }
        }, episodes: { _, limit, offset in try await server.get("episodes?limit=\(limit)&offset=\(offset)") },
        subjectMutation: { id, type, rate in
            try await server.post(watchingFailure && type == 3 ? "mutation-fail" : "subject-mutation",
                body: ["subjectId": id, "type": type, "rate": rate].compactMapValues { $0 })
        }, episodeMutation: { id, type, batch in
            try await server.post("episode-mutation", body: Mutation(episodeId: id, type: type, batch: batch))
        }, notify: { subject, membership in events.notifications.append([subject, membership ? 1 : 0]) }, now: { 1000 })
    }
    private struct Mutation: Encodable { var episodeId: Int; var type: Int; var batch: Bool }
    private func seed(_ fixture: Fixture, db: BangumiDatabaseOperator) async throws {
        try await db.saveSubject(fixture.subject, authoritativeInterest: true)
        try await db.replaceEpisodes(subjectId: fixture.subject.id, items: fixture.episodes, authoritativeCollection: true)
    }

    func testHTTPSubjectLoadPagingAndReconcileMatchNativeDatabase() async throws {
        let db = try database(), native = try database(shared: false)
        let progress = try XCTUnwrap(db.progress), fixture = sample()
        let server = try ProgressServer(fixture: JSONEncoder().encode(fixture)); defer { server.stop() }
        let events = await ProgressEvents(), deps = await dependencies(db, server: server, events: events)
        _ = try await progress.run(.init(operation: "ensureSubject", subjectId: 1, authoritativeCollection: true), dependencies: deps)
        try await seed(fixture, db: native)
        let actual = try await db.subject(id: 1), expected = try await native.subject(id: 1)
        let actualEpisodes = try await db.fetchEpisodes(subjectId: 1), expectedEpisodes = try await native.fetchEpisodes(subjectId: 1)
        XCTAssertEqual(actual, expected); XCTAssertEqual(actualEpisodes, expectedEpisodes)
        _ = try await progress.run(.init(operation: "reconcileSubject", subjectId: 1, authoritativeCollection: true), dependencies: deps)
        let notifications = await events.notifications
        XCTAssertEqual(notifications, [[1, 0]])
        let requests: [ProgressServer.Request] = try await server.get("stats")
        XCTAssertTrue(requests.contains { $0.path == "/episodes?limit=1000&offset=1000" })
        XCTAssertEqual(requests.filter { $0.path == "/lookup" }.count, 1)
        XCTAssertEqual(try active(progress), 0)
    }

    func testBatchKeepsOptimisticProgressWhenWatchingAndReconcileHTTPFail() async throws {
        let db = try database(), progress = try XCTUnwrap(db.progress)
        var fixture = sample(); fixture.subject.interest?.type = .wish
        let server = try ProgressServer(fixture: JSONEncoder().encode(fixture)); defer { server.stop() }
        try await seed(fixture, db: db)
        let events = await ProgressEvents()
        let deps = await dependencies(db, server: server, events: events, readFailure: true, watchingFailure: true)
        let result = try await progress.run(.init(operation: "updateEpisode", episodeId: 42, type: 2, batch: true, prepareWatching: true), dependencies: deps)
        XCTAssertTrue(result)
        let episodes = try await db.fetchEpisodes(subjectId: 1), subject = try await db.subject(id: 1)
        XCTAssertEqual(episodes.map { $0.collection?.status }, [2, 2])
        XCTAssertEqual(subject?.interest?.epStatus, 2)
        let notices = await events.notifications; XCTAssertEqual(notices, [[1, 0]])
        let requests: [ProgressServer.Request] = try await server.get("stats")
        XCTAssertEqual(requests.map(\.path), ["/lookup", "/mutation-fail", "/episode-mutation", "/subject-fail"])
        XCTAssertEqual(requests[2].body?["episodeId"]?.integer, 42)
        XCTAssertEqual(requests[2].body?["batch"]?.boolean, true)
        XCTAssertEqual(try active(progress), 0)
    }

    func testCompletionPromotionAfterReadFailureAndManualSignedIdentifierMutation() async throws {
        let db = try database(), progress = try XCTUnwrap(db.progress), fixture = sample(id: Int.max, status: .collect)
        let server = try ProgressServer(fixture: JSONEncoder().encode(fixture)); defer { server.stop() }
        try await seed(fixture, db: db)
        let events = await ProgressEvents(), deps = await dependencies(db, server: server, events: events, readFailure: true)
        _ = try await progress.run(.init(operation: "refreshAfterProgress", subjectId: Int.max), dependencies: deps)
        var subject = try await db.subject(id: Int.max)
        XCTAssertEqual(subject?.interest?.type, .collect)
        _ = try await progress.run(.init(operation: "updateSubject", subjectId: Int.max, type: 4), dependencies: deps)
        _ = try await progress.run(.init(operation: "updateRating", subjectId: Int.max, rate: 10), dependencies: deps)
        subject = try await db.subject(id: Int.max)
        XCTAssertEqual(subject?.interest?.type, .onHold); XCTAssertEqual(subject?.interest?.rate, 10)
        let notices = await events.notifications
        XCTAssertEqual(notices, [[Int.max, 1], [Int.max, 1], [Int.max, 0]])
        let requests: [ProgressServer.Request] = try await server.get("stats")
        XCTAssertEqual(requests.last?.body?["subjectId"]?.integer, Int.max)
        XCTAssertEqual(requests.last?.body?["rate"]?.integer, 10)
    }

    func testLateRemoteReceiptCannotWriteOrNotifyAfterAccountRetirement() async throws {
        for clear in [false, true] {
            let db = try database(), progress = try XCTUnwrap(db.progress), fixture = sample()
            try await seed(fixture, db: db)
            let server = try ProgressServer(fixture: JSONEncoder().encode(fixture)); defer { server.stop() }
            let events = await ProgressEvents(), gate = ProgressGate()
            var deps = await dependencies(db, server: server, events: events)
            deps.episodeMutation = { _, _, _ in await gate.block() }
            let captured = deps
            let task = Task { try await progress.run(.init(operation: "updateEpisode", episodeId: 42, type: 2), dependencies: captured) }
            await gate.started()
            if clear { try await db.clearAccountLocalState(); try await seed(fixture, db: db) }
            else { db.invalidateWork() }
            await gate.release()
            do { _ = try await task.value; XCTFail("Late mutation must retire") } catch { }
            let episodes = try await db.fetchEpisodes(subjectId: 1)
            XCTAssertEqual(episodes.map { $0.collection?.status }, [0, 0])
            let notices = await events.notifications; XCTAssertTrue(notices.isEmpty)
            XCTAssertEqual(try active(progress), 0)
        }
    }

    func testCancelledRemoteEffectDoesNotApplyLocalMutationAndReleasesReceipt() async throws {
        let db = try database(), progress = try XCTUnwrap(db.progress), fixture = sample()
        try await seed(fixture, db: db)
        let server = try ProgressServer(fixture: JSONEncoder().encode(fixture)); defer { server.stop() }
        let events = await ProgressEvents(), gate = ProgressGate()
        var deps = await dependencies(db, server: server, events: events)
        deps.subjectMutation = { _, _, _ in await gate.block() }
        let captured = deps
        let task = Task { try await progress.run(.init(operation: "updateRating", subjectId: 1, rate: 10), dependencies: captured) }
        await gate.started(); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let subject = try await db.subject(id: 1); XCTAssertEqual(subject?.interest?.rate, 0)
        let notices = await events.notifications; XCTAssertTrue(notices.isEmpty)
        XCTAssertEqual(try active(progress), 0)
    }

    func testNativeFallbackRejectsEveryStaleProgressWriteAfterRetirement() async throws {
        let db = try database(shared: false), fixture = sample()
        try await seed(fixture, db: db)
        let revision = await db.captureSyncRevision(); db.invalidateWork()
        func rejected(_ work: () async throws -> Void) async {
            do { try await work(); XCTFail("Stale fallback write must reject") }
            catch { guard case .ignore = error as? BangumiError else { XCTFail("Unexpected error: \(error)"); return } }
        }
        await rejected { try await db.saveSubject(fixture.subject, ifCurrentSyncRevision: revision) }
        await rejected { _ = try await db.saveSubjects([fixture.subject], ifCurrentSyncRevision: revision) }
        await rejected { try await db.replaceEpisodes(subjectId: 1, items: [], ifCurrentSyncRevision: revision) }
        await rejected { _ = try await db.updateEpisodeCollection(episodeId: 42, type: .collect, ifCurrentSyncRevision: revision) }
        await rejected { try await db.updateSubjectCollectionType(subjectId: 1, type: .collect, ifCurrentSyncRevision: revision) }
        await rejected { try await db.updateSubjectRating(subjectId: 1, rate: 10, ifCurrentSyncRevision: revision) }
        let subject = try await db.subject(id: 1), episodes = try await db.fetchEpisodes(subjectId: 1)
        XCTAssertEqual(subject?.interest?.rate, 0); XCTAssertEqual(subject?.interest?.type, .doing)
        XCTAssertEqual(episodes.map { $0.collection?.status }, [0, 0])
        try await db.updateSubjectRating(subjectId: 1, rate: 9)
        let updated = try await db.subject(id: 1); XCTAssertEqual(updated?.interest?.rate, 9)
    }
}

@MainActor private final class ProgressEvents { var notifications: [[Int]] = [] }
private actor ProgressGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func block() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            for observer in observers { observer.resume() }; observers.removeAll()
        }
    }
    func started() async {
        if waiter != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { waiter?.resume(); waiter = nil }
}
private final class ProgressServer: @unchecked Sendable {
    enum Scalar: Decodable {
        case integer(Int), boolean(Bool)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let integer = try? value.decode(Int.self) { self = .integer(integer) }
            else { self = .boolean(try value.decode(Bool.self)) }
        }
        var integer: Int? { if case .integer(let value) = self { value } else { nil } }
        var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }
    }
    struct Request: Decodable { var method, path: String; var body: [String: Scalar]? }
    let process = Process()
    let root: URL
    init(fixture: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-progress-wire-\(UUID().uuidString).json")
        try fixture.write(to: file)
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "bangumi_progress_server", withExtension: "py", subdirectory: "Fixtures")!.path, file.path]
        process.standardOutput = pipe
        try process.run()
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        root = URL(string: "http://127.0.0.1:\(port)")!
    }
    func url(_ path: String) -> URL { URL(string: root.absoluteString + "/" + path)! }
    func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BangumiError.request("Fixture HTTP failure") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func post<T: Encodable>(_ path: String, body: T) async throws {
        var request = URLRequest(url: url(path)); request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BangumiError.request("Fixture HTTP failure") }
    }
    func stop() { if process.isRunning { process.terminate() } }
}
#endif
