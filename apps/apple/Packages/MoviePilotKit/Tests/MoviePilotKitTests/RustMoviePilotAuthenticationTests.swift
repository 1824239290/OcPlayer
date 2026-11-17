import XCTest
@testable import MoviePilotKit

#if os(macOS)
final class RustMoviePilotAuthenticationTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for native integration tests")
        }
        return path
    }

    @MainActor
    private static func session(_ server: NativeServer, library: String?, username: String = "fixture", token: String? = "fresh", configuration: URLSessionConfiguration = .ephemeral) -> (MoviePilotAPIClient, MoviePilotStore) {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(UUID().uuidString),
                                   credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        store.updateCredentials(serverURLString: server.baseURL, username: username, password: "fixture")
        store.accessToken = token
        let client = MoviePilotAPIClient(store: store, sessionConfiguration: configuration, rustCoreLibraryPath: library,
                                        retrySleep: { _ in try Task.checkCancellation() })
        return (client, store)
    }

    private func waitForRequest(_ server: NativeServer, containing text: String) async throws {
        for _ in 0..<200 {
            if try await server.requests().contains(where: { $0.path.contains(text) || $0.body?.contains(text) == true }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("fixture request did not start: \(text)")
    }

    func testInitialLoginUsesCoreAndRetainsAuthenticatedCookieConnection() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path, token: nil)
        let user = try await client.login(serverURLString: server.baseURL, username: "cookie", password: "密 码+&=/%")
        XCTAssertEqual(user.name, "cookie")
        XCTAssertEqual(user.isSuperuser, true)
        XCTAssertEqual(store.accessToken, "user:cookie")
        XCTAssertEqual(store.username, "cookie")
        _ = try await client.searchMedia(title: "after-login")
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap(\.port)).count, 1)
        XCTAssertEqual(requests[0].authorization, "")
        XCTAssertEqual(requests[0].contentType, "application/x-www-form-urlencoded")
        var body = URLComponents()
        body.percentEncodedQuery = requests[0].body
        XCTAssertEqual(body.queryItems?.first(where: { $0.name == "username" })?.value, "cookie")
        // Form encoding uses + for spaces; the literal + is encoded as %2B.
        XCTAssertTrue(requests[0].body?.contains("%2B%26%3D%2F%25") == true)
        XCTAssertTrue(requests[1].cookie?.contains("Login=issued") == true)
        XCTAssertTrue(requests[2].cookie?.contains("MoviePilot=fixture") == true)
    }

    func testProductionConfigurationLoadsCoreWithoutExplicitLibraryOverride() async throws {
        _ = try library()
        guard ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1" else {
            throw XCTSkip("Production activation requires OCP_CORE_ENABLED=1")
        }
        let server = try NativeServer()
        defer { server.stop() }
        let (client, _) = await Self.session(server, library: nil, token: nil, configuration: .default)
        _ = try await client.login(serverURLString: server.baseURL, username: "cookie", password: "fixture")
        let active = await client.usesCoreTransport
        XCTAssertTrue(active)
        _ = try await client.searchMedia(title: "production")
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap(\.port)).count, 1)
    }

    func testRejectedLoginAndInvalidUserCannotReplaceCommittedCredentials() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path)
        let original = store.credentialSnapshot()
        for username in ["reject", "baduser", "empty"] {
            do {
                _ = try await client.login(serverURLString: server.baseURL, username: username, password: "fixture")
                XCTFail("invalid login must fail")
            } catch { XCTAssertTrue(error is MoviePilotError) }
            XCTAssertEqual(store.credentialSnapshot(), original)
            XCTAssertEqual(store.accessToken, "fresh")
        }
    }

    func testLoginTokenIssuanceRetriesTransientGatewayAndSendsNoBearer() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path)
        _ = try await client.login(serverURLString: server.baseURL, username: "retry", password: "fixture")
        XCTAssertEqual(store.accessToken, "fresh")
        let requests = try await server.requests()
        let logins = requests.filter { $0.method == "POST" }
        XCTAssertEqual(logins.count, 3)
        XCTAssertTrue(logins.allSatisfy { $0.authorization == "" })
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("user/current") }.count, 1)
    }

    func testSignOutCancelsInitialCoreLoginAndKeepsTokenCleared() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path)
        let pending = Task { try await client.login(serverURLString: server.baseURL, username: "slow", password: "fixture") }
        try await waitForRequest(server, containing: "username=slow")
        let start = ContinuousClock.now
        _ = await client.signOut()
        do { _ = try await pending.value; XCTFail("retired login must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertNil(store.accessToken)
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testNewerCoreLoginWinsAndCancelsEarlierAttempt() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path)
        let older = Task { try await client.login(serverURLString: server.baseURL, username: "older", password: "fixture") }
        try await waitForRequest(server, containing: "username=older")
        let user = try await client.login(serverURLString: server.baseURL, username: "newer", password: "fixture")
        XCTAssertEqual(user.name, "newer")
        do { _ = try await older.value; XCTFail("earlier login must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.username, "newer")
        XCTAssertEqual(store.accessToken, "user:newer")
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("user/current") }.count, 1)
    }

    func testRawBinaryJSONAndFormResponsesPreserveBytesAndQuery() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, _) = await Self.session(server, library: path)
        let binary = try await client.requestData(.init(path: "/api/v1/raw/binary", query: [
            URLQueryItem(name: "q", value: "中 文+&/%"), URLQueryItem(name: "q", value: "two"), URLQueryItem(name: "flag", value: nil),
        ]))
        XCTAssertEqual(binary, Data([0, 255, 128, 10, 13, 65]))
        struct Body: Encodable { let zero = 0; let flag = false; let title = "中文 + &" }
        let json = try await client.requestData(.init(path: "/api/v1/raw/echo", method: "POST", jsonBody: Body()))
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: json)
        XCTAssertEqual(fields["zero"], .number(0))
        XCTAssertEqual(fields["flag"], .bool(false))
        let form = try await client.requestData(.init(path: "/api/v1/raw/echo", method: "POST", formBody: ["name": "中 文+&/%"]))
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap(\.port)).count, 1)
        XCTAssertEqual(Data(base64Encoded: requests[2].bodyBase64 ?? ""), form)
        XCTAssertTrue(requests[0].path.contains("q=%E4%B8%AD%20%E6%96%87+%26/%25&q=two&flag"))
        XCTAssertEqual(requests[1].contentType, "application/json")
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer fresh" })
    }

    func testRawHTTPErrorMappingAndExplicitNonIdempotencyNeverReplay() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, _) = await Self.session(server, library: path)
        for status in [400, 403, 404, 422, 503] {
            do {
                _ = try await client.requestData(.init(path: "/api/v1/raw/status", query: [URLQueryItem(name: "status", value: String(status))], idempotent: false))
                XCTFail("HTTP error must fail")
            } catch let error as MoviePilotError {
                switch (status, error) {
                case (400, .badRequest("wire message")), (403, .forbidden("wire message")), (404, .notFound("wire message")),
                     (422, .http(422, "wire message")), (503, .http(503, "wire message")): break
                default: XCTFail("unexpected typed error: \(error)")
                }
            }
        }
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertFalse(requests.contains { $0.path.contains("access-token") })
    }

    func testRawRetryOwnerRetriesReadExactlyThreeTimesAndCreationOnce() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, _) = await Self.session(server, library: path)
        _ = try await client.requestData(.init(path: "/api/v1/raw/flaky"))
        do {
            _ = try await client.requestData(.init(path: "/api/v1/raw/create", method: "POST", jsonBody: ["zero": 0]))
            XCTFail("creation must fail")
        } catch { XCTAssertTrue(error is MoviePilotError) }
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("flaky") }.count, 3)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("create") }.count, 1)
    }

    func testRawTimeoutRemainsTypedAndDoesNotRetryWhenDisabled() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, _) = await Self.session(server, library: path)
        do {
            _ = try await client.requestData(.init(path: "/api/v1/raw/slow", timeout: 0.08, idempotent: false))
            XCTFail("slow response must time out")
        } catch let error as MoviePilotError {
            guard case .network(.timedOut, _) = error else { return XCTFail("timeout classification lost: \(error)") }
        }
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testConcurrentRawAndNamedExpiryShareOneTokenOnlyRelogin() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path, token: "expired")
        async let raw = client.requestData(.init(path: "/api/v1/raw/value"))
        async let named = client.currentUser()
        async let late = client.requestData(.init(path: "/api/v1/raw/late-expired"))
        _ = try await (raw, named, late)
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 1)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("user/current") }.count, 2)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("late-expired") }.count, 2)
        XCTAssertEqual(store.accessToken, "fresh")
    }

    func testMalformedSilentLoginTripsFuseAndClearsExpiredToken() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path, username: "malformed", token: "expired")
        for _ in 0..<2 {
            do { _ = try await client.currentUser(); XCTFail("invalid authentication response must fail") }
            catch let error as MoviePilotError { XCTAssertTrue(error.isAuthenticationFailure) }
        }
        XCTAssertNil(store.accessToken)
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 1)
    }

    func testRejectedSilentLoginClearsTokenNotifiesAndDoesNotReissuePassword() async throws {
        let path = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let (client, store) = await Self.session(server, library: path, username: "reject", token: "expired")
        let notification = expectation(forNotification: MoviePilotAPIClient.authenticationRequiredNotification, object: nil)
        for _ in 0..<2 {
            do { _ = try await client.currentUser(); XCTFail("authentication must fail") }
            catch let error as MoviePilotError { XCTAssertTrue(error.isAuthenticationFailure) }
        }
        await fulfillment(of: [notification], timeout: 1)
        XCTAssertNil(store.accessToken)
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 1)
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("user/current") }.count, 1)
    }
}
#endif
