import Foundation
import GRDB
import XCTest
@testable import BangumiKit

#if os(macOS)
@MainActor
final class BangumiAuthLifecycleTests: XCTestCase {
    private var modes: [Bool] { ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] == nil ? [false] : [true, false] }
    private func profiles() -> [BangumiProfile] {
        var first = BangumiProfile()
        first.id = Int.max; first.joinedAt = Int.max - 1
        first.username = "exact-user"; first.nickname = "昵称 🎬"; first.location = "上海"
        first.group = 2; first.site = "https://example.test/site"; first.sign = "Profile sign"
        first.avatar = .init(large: "large", medium: "medium", small: "small")
        first.permissions.subjectWikiEdit = false
        var second = first; second.id = 2; second.username = "new-user"
        return [first, second]
    }
    private struct Fixture {
        var client: BangumiAPIClient; var store: BangumiStore
        var lifecycle: BangumiAuthLifecycle; var state: AuthUIState; var db: BangumiDatabaseOperator
    }
    private func fixture(_ server: AuthFlowServer, shared: Bool) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-auth-flow-\(UUID().uuidString)")
        let store = BangumiStore(defaults: UserDefaults(suiteName: "bangumi-auth-flow-\(UUID().uuidString)")!, credentialsDirectory: directory)
        let path = shared ? ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] : nil
        let factory: (@Sendable (String?) -> URLSession)?
        if shared { factory = nil } else {
            factory = { token in
                let configuration = URLSessionConfiguration.ephemeral
                if let token { configuration.httpAdditionalHeaders = ["Authorization": "Bearer \(token)"] }
                return URLSession(configuration: configuration)
            }
        }
        let client = BangumiAPIClient(store: store, gateway: .init(baseURL: server.root, apiKey: "gateway", userAgent: "OcPlay/auth-test"),
            sessionFactory: factory, rustCoreLibraryPath: path)
        let db = BangumiDatabaseOperator(database: try BangumiDatabaseFactory.makeDatabase(at: directory), coreLibraryPath: path, coreEnabled: shared)
        let state = AuthUIState(store: store)
        let lifecycle = BangumiAuthLifecycle(client: client, effects: .init(
            retireWork: { state.events.append("retire"); db.invalidateWork() },
            fetchProfile: {
                let request = await state.nextProfileRequest()
                let data = try await client.request(url: server.url(request), method: "GET", auth: .required)
                await state.recordFetch()
                if let gate = await state.fetchGate { await gate.block() }
                if await state.injectFailure {
                    if let hook = await state.beforeFailure { try await hook() }
                    throw ProfileFailure()
                }
                guard let raw = String(data: data, encoding: .utf8) else { throw ProfileFailure() }
                return BangumiProfile(from: raw)
            },
            commitProfile: { profile in
                state.events.append("commit"); state.commits += 1
                store.setProfile(profile); store.setAuthenticated(true)
                if state.commits == 1, let gate = state.commitGate { await gate.block() }
            },
            clearProfile: {
                state.events.append("clearProfile"); store.setAuthenticated(false)
                store.setProfile(nil); store.setCollectionsUpdatedAt(0)
            },
            clearDatabase: { revision in
                guard revision == state.lifecycle?.operationRevision else { throw BangumiError(ignore: "Old database clear") }
                let workRevision = db.captureWorkRevision()
                state.events.append("clearDatabase")
                if let gate = state.clearGate { await gate.block() }
                if state.injectClearFailure { throw ProfileFailure() }
                try await db.clearAccountLocalState(ifCurrentWorkRevision: workRevision)
            }, authenticated: { store.isAuthenticated }))
        state.lifecycle = lifecycle
        XCTAssertEqual(client.account != nil, shared); XCTAssertEqual(lifecycle.flow != nil, shared)
        return Fixture(client: client, store: store, lifecycle: lifecycle, state: state, db: db)
    }
    private func state(_ client: BangumiAPIClient) async throws -> String {
        let url = try await client.buildOAuthURL()
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    }
    private func login(_ fixture: Fixture, code: String = "first") async throws {
        let callback = try await state(fixture.client)
        try await fixture.lifecycle.exchange(code: code, state: callback)
    }
    private func active(_ lifecycle: BangumiAuthLifecycle) throws -> Int {
        guard let flow = lifecycle.flow else { return 0 }
        struct Stats: Decodable { var active: Int }
        return try flow.core.call("bangumiAuthFlow.stats").decodeData(Stats.self).active
    }
    private func server() throws -> AuthFlowServer { try AuthFlowServer(profiles: JSONEncoder().encode(profiles())) }

    func testRealHTTPExchangeAndProfilePersistEveryFieldAndExactIntegerInBothModes() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            try await login(fixture)
            XCTAssertEqual(fixture.store.profile, profiles()[0]); XCTAssertTrue(fixture.store.isAuthenticated)
            XCTAssertEqual(fixture.store.auth?.accessToken, "token-first")
            XCTAssertEqual(fixture.state.events, ["retire", "fetch", "commit"])
            let refreshed = try await fixture.lifecycle.refreshProfile()
            XCTAssertEqual(refreshed, profiles()[1]); XCTAssertEqual(fixture.store.profile, refreshed)
            let requests: [AuthFlowServer.Request] = try await server.get("stats")
            XCTAssertEqual(requests.map(\.method), ["GET", "POST", "GET", "GET"])
            XCTAssertEqual(requests[2].authorization, "Bearer token-first")
            XCTAssertTrue(requests[1].body.contains("first")); XCTAssertEqual(try active(fixture.lifecycle), 0)
        }
    }
    func testFailedProfileAndCancelledProfileAfterOAuthRetireOnlyTheirCredentials() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            fixture.state.injectFailure = true
            do { try await login(fixture); XCTFail("Profile failure must propagate") }
            catch { XCTAssertTrue(error is ProfileFailure) }
            XCTAssertNil(fixture.store.auth); XCTAssertFalse(fixture.store.isAuthenticated)
            XCTAssertNil(fixture.store.profile); XCTAssertEqual(try active(fixture.lifecycle), 0)
            fixture.state.injectFailure = false
            let gate = AuthGate(); fixture.state.fetchGate = gate
            let callback = try await state(fixture.client)
            let task = Task { try await fixture.lifecycle.exchange(code: "second", state: callback) }
            await gate.started(); task.cancel(); await gate.release()
            do { try await task.value; XCTFail("Cancellation must propagate") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(fixture.store.auth); XCTAssertFalse(fixture.store.isAuthenticated)
            XCTAssertEqual(try active(fixture.lifecycle), 0)
            fixture.state.fetchGate = nil; fixture.state.injectFailure = true
            let replacementClient = fixture.client
            fixture.state.beforeFailure = {
                let url = try await replacementClient.buildOAuthURL()
                guard let callback = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { throw ProfileFailure() }
                _ = try await replacementClient.exchangeForAccessToken(code: "replacement", state: callback)
            }
            do { try await login(fixture, code: "third"); XCTFail("Profile failure must retain original error") }
            catch { XCTAssertTrue(error is ProfileFailure) }
            XCTAssertEqual(fixture.store.auth?.accessToken, "token-replacement")
            XCTAssertEqual(try active(fixture.lifecycle), 0)
        }
    }
    func testOldProfileCommitCannotPublishAfterLogoutAndNewLogin() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared), gate = AuthGate()
            fixture.state.commitGate = gate
            let callback = try await state(fixture.client)
            let old = Task { try await fixture.lifecycle.exchange(code: "first", state: callback) }
            await gate.started()
            await fixture.lifecycle.logout()
            try await login(fixture, code: "second")
            let expected = fixture.store.profile
            await gate.release()
            do { try await old.value; XCTFail("Old profile must retire") }
            catch { guard case .ignore = error as? BangumiError else { XCTFail("Unexpected: \(error)"); continue } }
            XCTAssertEqual(fixture.store.profile, expected); XCTAssertEqual(expected?.id, 2)
            XCTAssertEqual(fixture.store.auth?.accessToken, "token-second"); XCTAssertTrue(fixture.store.isAuthenticated)
            XCTAssertEqual(try active(fixture.lifecycle), 0)
        }
    }
    func testDecodedLateHTTPProfileCannotReauthenticateAfterLogout() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            try await login(fixture)
            let gate = AuthGate(); fixture.state.fetchGate = gate
            let task = Task { try await fixture.lifecycle.refreshProfile() }
            await gate.started(); await fixture.lifecycle.logout(); await gate.release()
            do { _ = try await task.value; XCTFail("Late HTTP profile must retire") }
            catch { guard case .ignore = error as? BangumiError else { XCTFail("Unexpected: \(error)"); continue } }
            XCTAssertNil(fixture.store.profile); XCTAssertNil(fixture.store.auth); XCTAssertFalse(fixture.store.isAuthenticated)
            XCTAssertEqual(try active(fixture.lifecycle), 0)
        }
    }
    func testDelayedLogoutDatabaseClearCannotDeleteNewAccountRows() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            try await login(fixture); fixture.store.setCollectionsUpdatedAt(50)
            let gate = AuthGate(); fixture.state.clearGate = gate
            let logout = Task { await fixture.lifecycle.logout() }
            await gate.started()
            fixture.state.clearGate = nil
            try await login(fixture, code: "second")
            try await fixture.db.saveSubject(BangumiFixture.subject(id: 2, eps: 1, epStatus: 0))
            await gate.release(); await logout.value
            let subject = try await fixture.db.subject(id: 2); XCTAssertNotNil(subject)
            XCTAssertEqual(fixture.store.auth?.accessToken, "token-second"); XCTAssertEqual(fixture.store.profile?.id, 2)
            XCTAssertEqual(fixture.store.collectionsUpdatedAt, 0)
            XCTAssertEqual(try active(fixture.lifecycle), 0)
        }
    }
    func testStaleOperationCannotPhysicallyClearNewCredentialsInEitherMode() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            try await login(fixture)
            let old = fixture.lifecycle.operationRevision
            try await login(fixture, code: "second")
            let before = fixture.store.auth
            let cleared = await fixture.client.clearCredentials(forOperation: old, nativeOperations: fixture.lifecycle.nativeOperations)
            XCTAssertNil(cleared); XCTAssertEqual(fixture.store.auth?.accessToken, before?.accessToken)
            XCTAssertEqual(fixture.store.auth?.refreshToken, before?.refreshToken)
            XCTAssertEqual(fixture.store.auth?.expiresAt, before?.expiresAt)
            XCTAssertEqual(fixture.store.auth?.accessToken, "token-second")
            let revision = fixture.db.captureWorkRevision(); fixture.db.invalidateWork()
            try await fixture.db.saveSubject(BangumiFixture.subject(id: 2, eps: 1, epStatus: 0))
            do { try await fixture.db.clearAccountLocalState(ifCurrentWorkRevision: revision); XCTFail("Stale clear must reject") }
            catch { guard case .ignore = error as? BangumiError else { XCTFail("Unexpected: \(error)"); continue } }
            let subject = try await fixture.db.subject(id: 2); XCTAssertNotNil(subject)
            try await fixture.db.clearAccountLocalState()
            let empty = try await fixture.db.subject(id: 2); XCTAssertNil(empty)
        }
    }
    func testPassiveInvalidationRequiresCurrentCredentialAndDoesNotClearDatabase() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            try await login(fixture)
            if let flow = fixture.lifecycle.flow {
                let generation = try XCTUnwrap(fixture.client.account).snapshot.generation
                for _ in 0..<1024 {
                    let _: RustBangumiAuthFlow.Step = try flow.call("start",
                        RustBangumiAuthFlow.Start(operation: "invalidateSession", authenticated: true, expectedGeneration: generation))
                }
                await fixture.lifecycle.invalidateSession(expectedGeneration: generation)
                XCTAssertTrue(fixture.store.isAuthenticated); XCTAssertNotNil(fixture.store.auth)
                XCTAssertEqual(try active(fixture.lifecycle), 1024)
                _ = try await fixture.lifecycle.refreshProfile()
                XCTAssertEqual(try active(fixture.lifecycle), 0)
            }
            try await fixture.db.saveSubject(BangumiFixture.subject(id: 1, eps: 1, epStatus: 0))
            let old = fixture.lifecycle.operationRevision
            await fixture.lifecycle.invalidateSession(expectedGeneration: UInt64.max)
            XCTAssertEqual(fixture.lifecycle.operationRevision, old); XCTAssertTrue(fixture.store.isAuthenticated)
            let generation = fixture.client.account?.snapshot.generation ?? 1
            await fixture.lifecycle.invalidateSession(expectedGeneration: generation)
            XCTAssertFalse(fixture.store.isAuthenticated); XCTAssertNil(fixture.store.profile); XCTAssertNil(fixture.store.auth)
            XCTAssertEqual(fixture.lifecycle.operationRevision, old &+ 1)
            let subject = try await fixture.db.subject(id: 1); XCTAssertNotNil(subject)
            XCTAssertFalse(fixture.state.events.contains("clearDatabase"))
            await fixture.lifecycle.invalidateSession(expectedGeneration: generation)
            XCTAssertEqual(fixture.lifecycle.operationRevision, old &+ 1)
        }
    }
    func testProfileDefaultToleranceAndLogoutDatabaseFailureMatchNativeBehavior() async throws {
        for shared in modes {
            let server = try server(); defer { server.stop() }
            let fixture = try fixture(server, shared: shared)
            fixture.state.profilePath = "profile-malformed"
            try await login(fixture)
            XCTAssertEqual(fixture.store.profile, BangumiProfile()); XCTAssertTrue(fixture.store.isAuthenticated)
            let callbacks = fixture.state.events
            XCTAssertEqual(callbacks, ["retire", "fetch", "commit"])
            fixture.state.injectClearFailure = true
            await fixture.lifecycle.logout()
            XCTAssertFalse(fixture.store.isAuthenticated); XCTAssertNil(fixture.store.auth)
            XCTAssertEqual(fixture.state.events.suffix(3), ["retire", "clearProfile", "clearDatabase"])
            XCTAssertEqual(try active(fixture.lifecycle), 0)
        }
    }
}

private struct ProfileFailure: Error {}
@MainActor private final class AuthUIState {
    let store: BangumiStore
    weak var lifecycle: BangumiAuthLifecycle?
    var events: [String] = [], commits = 0, requests = 0
    var fetchGate, commitGate, clearGate: AuthGate?
    var beforeFailure: (@Sendable () async throws -> Void)?
    var injectFailure = false
    var injectClearFailure = false
    var profilePath = "profile"
    init(store: BangumiStore) { self.store = store }
    func recordFetch() { events.append("fetch") }
    func nextProfileRequest() -> String {
        defer { requests += 1 }
        return profilePath == "profile" ? "profile?index=\(requests)" : profilePath
    }
}
private actor AuthGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func block() async {
        await withCheckedContinuation { waiter = $0; observers.forEach { $0.resume() }; observers.removeAll() }
    }
    func started() async {
        if waiter != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { waiter?.resume(); waiter = nil }
}
private final class AuthFlowServer: @unchecked Sendable {
    struct Request: Decodable { var method, path, body: String; var authorization: String? }
    let process = Process(), root: URL
    init(profiles: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-auth-flow-wire-\(UUID().uuidString).json")
        try profiles.write(to: file)
        let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "bangumi_auth_flow_server", withExtension: "py", subdirectory: "Fixtures")!.path, file.path]
        process.standardOutput = pipe; try process.run()
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        root = URL(string: "http://127.0.0.1:\(port)")!
    }
    func url(_ path: String) -> URL { URL(string: root.absoluteString + "/" + path)! }
    func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: url(path)); return try JSONDecoder().decode(T.self, from: data)
    }
    func stop() { if process.isRunning { process.terminate() } }
}
#endif
