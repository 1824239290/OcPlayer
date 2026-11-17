import Foundation
import XCTest
@testable import MoviePilotKit

final class MoviePilotSessionRaceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSwitchCancelsOldRetryWithoutSendingOldToken() async throws {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
            credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        await MainActor.run {
            store.updateCredentials(serverURLString: "https://old.invalid", username: "old", password: "old-password")
            store.accessToken = "synthetic-old-token"
        }
        let backoff = expectation(description: "retry held")
        let retryGate = Gate()
        let client = MoviePilotAPIClient(store: store, sessionConfiguration: TestSupport.mockedSessionConfiguration(), retrySleep: { _ in
            backoff.fulfill()
            await retryGate.wait()
        })
        let first = expectation(description: "first request")
        let lock = NSLock()
        var requests: [URLRequest] = []
        MockURLProtocol.handler = { request in
            let count = lock.withLock { requests.append(request); return requests.count }
            if count == 1 {
                first.fulfill()
                return MockURLProtocol.response("{}", status: 503, for: request.url!)
            }
            return MockURLProtocol.response("{}", status: 200, for: request.url!)
        }
        let pending = Task { try await client.requestData(.init(path: "/api/v1/user/current")) }
        await fulfillment(of: [first, backoff], timeout: 3)
        _ = await client.signOut()
        await MainActor.run {
            store.updateCredentials(serverURLString: "https://new.invalid", username: "new", password: "new-password")
            store.accessToken = "synthetic-new-token"
        }
        await retryGate.release()
        do { _ = try await pending.value; XCTFail("旧会话应取消") } catch is CancellationError { }
        let observed = lock.withLock { requests }
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.last?.url?.host, "old.invalid")
        XCTAssertEqual(observed.last?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-old-token")
    }

    func testSignOutRejectsLateLogin() async throws {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
            credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        await MainActor.run {
            store.updateCredentials(serverURLString: "https://old.invalid", username: "old", password: "old-password")
        }
        let client = MoviePilotAPIClient(store: store, sessionConfiguration: TestSupport.mockedSessionConfiguration())
        let started = expectation(description: "login request started")
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            if request.url!.path.contains("access-token") {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
                return MockURLProtocol.response(#"{"access_token":"synthetic-stale-login","token_type":"bearer"}"#, status: 200, for: request.url!)
            }
            return MockURLProtocol.response(#"{"id":1,"name":"old","is_superuser":true,"is_active":true}"#, status: 200, for: request.url!)
        }
        let pending = Task { try await client.login() }
        await fulfillment(of: [started], timeout: 3)
        _ = await client.signOut()
        XCTAssertNil(store.accessToken)
        gate.signal()
        do { _ = try await pending.value; XCTFail("旧会话应取消") } catch is CancellationError { }
        XCTAssertNil(store.accessToken)
    }
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }

    func testFailedConfiguredLoginPreservesExistingCredentials() async throws {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(), credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        await MainActor.run {
            store.updateCredentials(serverURLString: "https://old.invalid", username: "old", password: "old-password")
            store.accessToken = "old-token"
        }
        let previous = store.credentialSnapshot()
        let client = MoviePilotAPIClient(store: store, sessionConfiguration: TestSupport.mockedSessionConfiguration())
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "new.invalid")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return MockURLProtocol.response("{}", status: 400, for: request.url!)
        }
        do {
            _ = try await client.login(serverURLString: "https://new.invalid", username: "new", password: "wrong")
            XCTFail("Login must fail")
        } catch is MoviePilotError { }
        XCTAssertEqual(store.credentialSnapshot(), previous)
    }

    func testNewerLoginWinsAgainstLateSuccessAndFailure() async throws {
        for oldStatus in [200, 400] {
            let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(), credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
            let client = MoviePilotAPIClient(store: store, sessionConfiguration: TestSupport.mockedSessionConfiguration())
            let started = expectation(description: "old login held")
            let gate = DispatchSemaphore(value: 0)
            MockURLProtocol.handler = { request in
                if request.url?.host == "old.invalid" {
                    started.fulfill()
                    _ = gate.wait(timeout: .now() + 5)
                    return MockURLProtocol.response(#"{"access_token":"old-token"}"#, status: oldStatus, for: request.url!)
                }
                let body = request.url!.path.contains("access-token") ? #"{"access_token":"new-token"}"# : #"{"id":2,"name":"new"}"#
                return MockURLProtocol.response(body, status: 200, for: request.url!)
            }
            let old = Task { try await client.login(serverURLString: "https://old.invalid", username: "old", password: "old-pass") }
            await fulfillment(of: [started], timeout: 3)
            // URLProtocol's callback queue is serial. Let the obsolete response finish;
            // the new attempt is registered first, before either response can commit.
            let new = Task { try await client.login(serverURLString: "https://new.invalid", username: "new", password: "new-pass") }
            // A request on the actor establishes the new attempt before releasing the transport.
            while await client.currentGeneration() < 2 { await Task.yield() }
            gate.signal()
            _ = try await new.value
            do { _ = try await old.value; XCTFail("Late attempt must cancel") } catch is CancellationError { }
            XCTAssertEqual(store.accessToken, "new-token")
            XCTAssertEqual(store.username, "new")
            XCTAssertEqual(store.baseURL?.host, "new.invalid")
        }
    }

    func testLateOldToken401ReplaysAlreadyRefreshedToken() async throws {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(), credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        await MainActor.run {
            store.updateCredentials(serverURLString: "https://old.invalid", username: "user", password: "password")
            store.accessToken = "expired"
        }
        let firstGate = Gate(), secondGate = Gate()
        let firstStarted = expectation(description: "first held")
        let secondStarted = expectation(description: "second held")
        let count = LoginCount()
        AsyncRaceURLProtocol.handler = { request in
            let path = request.url!.path
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                if path == "/first" { firstStarted.fulfill(); await firstGate.wait() }
                else { secondStarted.fulfill(); await secondGate.wait() }
                return MockURLProtocol.response("{}", status: 401, for: request.url!)
            }
            if path.contains("access-token") {
                count.increment()
                return MockURLProtocol.response(#"{"access_token":"fresh"}"#, status: 200, for: request.url!)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return MockURLProtocol.response("{}", status: 200, for: request.url!)
        }
        defer { AsyncRaceURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AsyncRaceURLProtocol.self]
        let client = MoviePilotAPIClient(store: store, sessionConfiguration: configuration)
        let first = Task { try await client.requestData(.init(path: "/first")) }
        await fulfillment(of: [firstStarted], timeout: 3)
        let second = Task { try await client.requestData(.init(path: "/second")) }
        await fulfillment(of: [secondStarted], timeout: 3)
        await firstGate.release()
        _ = try await first.value
        await secondGate.release()
        _ = try await second.value
        XCTAssertEqual(count.value, 1)
        XCTAssertEqual(store.accessToken, "fresh")
    }

    func testDirectConfigurationChangeRejectsOldNotificationAndToken() async throws {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(), credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        let client = MoviePilotAPIClient(store: store, sessionConfiguration: TestSupport.mockedSessionConfiguration())
        MockURLProtocol.handler = { request in
            let body = request.url!.path.contains("access-token") ? #"{"access_token":"old-token"}"# : #"{"id":1,"name":"old"}"#
            return MockURLProtocol.response(body, status: 200, for: request.url!)
        }
        _ = try await client.login(serverURLString: "https://old.invalid", username: "old", password: "old-pass")
        let generation = await client.currentGeneration()
        await MainActor.run { store.serverURLString = "https://new.invalid" }
        XCTAssertNil(store.accessToken)
        await MainActor.run { store.accessToken = "new-token" }
        let cleared = await client.clearSession(ifCurrent: generation)
        XCTAssertNil(cleared)
        XCTAssertEqual(store.accessToken, "new-token")
    }

    private final class LoginCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

}

private final class AsyncRaceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async -> (HTTPURLResponse, Data))?
    private var pending: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        pending = Task {
            let (response, data) = await handler(request)
            guard !Task.isCancelled else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { pending?.cancel() }
}
