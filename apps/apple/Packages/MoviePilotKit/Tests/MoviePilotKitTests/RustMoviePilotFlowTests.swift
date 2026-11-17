import XCTest
@testable import MoviePilotKit

#if os(macOS)
private actor RetryRecorder {
    var delays: [UInt64] = []
    var blocked = false
    var continuation: CheckedContinuation<Void, Never>?
    func record(_ delay: UInt64) { delays.append(delay) }
    func pause(_ delay: UInt64) async {
        delays.append(delay)
        await withCheckedContinuation { continuation = $0; blocked = true }
    }
    func release() { continuation?.resume(); continuation = nil; blocked = false }
}

final class RustMoviePilotFlowTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for retained request flow tests")
        }
        return path
    }
    @MainActor
    private static func session(_ server: NativeServer, library: String, username: String = "fixture",
                                token: String = "fresh", recorder: RetryRecorder? = nil, blocked: Bool = false) -> (MoviePilotAPIClient, MoviePilotStore) {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(), credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        store.updateCredentials(serverURLString: server.baseURL, username: username, password: "fixture")
        store.accessToken = token
        return (MoviePilotAPIClient(store: store, sessionConfiguration: .ephemeral, rustCoreLibraryPath: library,
            retrySleep: { delay in
                if blocked { await recorder?.pause(delay) } else { await recorder?.record(delay) }
                try Task.checkCancellation()
            }), store)
    }

    func testLoginAndCurrentUserRetainExactLargeIntegerIdentity() async throws {
        let server = try NativeServer(); defer { server.stop() }
        let (client, _) = try await Self.session(server, library: library())
        let login = try await client.login(serverURLString: server.baseURL, username: "large-id", password: "fixture")
        let user = try await client.currentUser()
        XCTAssertEqual(login.id, 9_007_199_254_741_007)
        XCTAssertEqual(user, login)
        XCTAssertEqual(user.email, "native@example.invalid")
        XCTAssertEqual(user.avatar, "/avatars/large.png")
        XCTAssertEqual(user.isSuperuser, false)
        XCTAssertEqual(user.isActive, false)
        let active = await client.activeCoreRequestFlows
        XCTAssertEqual(active, 0)
    }

    func testFailedRefreshNeverRestartsRejectedRawReadAndPreservesToken() async throws {
        let server = try NativeServer(); defer { server.stop() }
        let recorder = RetryRecorder()
        let (client, store) = try await Self.session(server, library: library(), username: "offline", token: "expired", recorder: recorder)
        do { _ = try await client.requestData(.init(path: "/api/v1/raw/value")); XCTFail("login gateway failure must propagate") }
        catch let error as MoviePilotError { XCTAssertTrue(error.isRetryable) }
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("raw/value") }.count, 1)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 3)
        XCTAssertEqual(store.accessToken, "expired")
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty, "Login transport owns its retry; the outer request must stop")
        let active = await client.activeCoreRequestFlows
        XCTAssertEqual(active, 0)
    }

    func testRefreshReplayCanUseRemainingReadRetryBudgetWithSharedBackoff() async throws {
        let server = try NativeServer(); defer { server.stop() }
        let recorder = RetryRecorder()
        let (client, store) = try await Self.session(server, library: library(), token: "expired", recorder: recorder)
        _ = try await client.requestData(.init(path: "/api/v1/raw/auth-flaky"))
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("auth-flaky") }.count, 4)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 1)
        XCTAssertEqual(store.accessToken, "fresh")
        let delays = await recorder.delays
        XCTAssertEqual(delays.count, 2)
        XCTAssertTrue((500_000_000...1_500_000_000).contains(delays[0]))
        XCTAssertTrue((1_000_000_000...3_000_000_000).contains(delays[1]))
    }

    func testNamedCommandUsesOnlyTransportRetryAfterAuthenticationReplay() async throws {
        let server = try NativeServer(); defer { server.stop() }
        let recorder = RetryRecorder()
        let (client, _) = try await Self.session(server, library: library(), token: "expired", recorder: recorder)
        _ = try await client.searchMedia(title: "named-flaky")
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.contains("media/search") }.count, 4)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 1)
        let delays = await recorder.delays
        XCTAssertTrue(delays.isEmpty)
        let active = await client.activeCoreRequestFlows
        XCTAssertEqual(active, 0)
    }

    func testSignOutWhileBackoffIsPendingRetiresFlowBeforeAnotherHTTPDispatch() async throws {
        let server = try NativeServer(); defer { server.stop() }
        let recorder = RetryRecorder()
        let (client, store) = try await Self.session(server, library: library(), recorder: recorder, blocked: true)
        let task = Task { try await client.requestData(.init(path: "/api/v1/raw/flaky")) }
        var waiting = false
        for _ in 0..<200 {
            if await recorder.blocked { waiting = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(waiting)
        let before = await client.activeCoreRequestFlows
        XCTAssertEqual(before, 1)
        _ = await client.signOut()
        let after = await client.activeCoreRequestFlows
        XCTAssertEqual(after, 0)
        await recorder.release()
        do { _ = try await task.value; XCTFail("backoff must not publish or redispatch after logout") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.accessToken)
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("flaky") }.count, 1)
    }
}
#endif
