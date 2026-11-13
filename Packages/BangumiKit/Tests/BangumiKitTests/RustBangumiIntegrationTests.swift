import Foundation
import XCTest
@testable import BangumiKit

#if os(macOS)
final class RustBangumiIntegrationTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for native Bangumi integration")
        }
        return path
    }
    private func makeClient(_ server: Server, token: String? = "fresh", expired: Bool = false, gatewayKey: String = "gateway") throws -> (BangumiAPIClient, BangumiStore) {
        let defaults = UserDefaults(suiteName: "bangumi-rust-\(UUID().uuidString)")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-rust-\(UUID().uuidString)")
        let store = BangumiStore(defaults: defaults, credentialsDirectory: directory)
        if let token {
            var auth = BangumiAuth(response: .init(accessToken: token, expiresIn: 3600, refreshToken: "refresh"))
            if expired { auth.expiresAt = .distantPast }
            store.auth = auth
            store.setAuthenticated(true)
        }
        return (BangumiAPIClient(store: store,
                                gateway: .init(baseURL: server.root, apiKey: gatewayKey, userAgent: "OcPlay/test (macOS)"),
                                rustCoreLibraryPath: try library()), store)
    }
    func testCompleteResponseAuthErrorsAndMutationNotReplayed() async throws {
        _ = try library()
        let server = try Server(); defer { server.stop() }
        let (client, _) = try makeClient(server)
        let data = try await client.request(url: server.url("mirror/p1/subjects/1?limit=5&offset=10"), method: "GET")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["name_cn"] as? String, "中文")
        XCTAssertNotNil(raw["unknown"])
        let empty = try await client.request(url: server.url("empty"), method: "GET", auth: .disabled)
        XCTAssertTrue(empty.isEmpty)
        let search = try await client.request(url: server.url("mirror/p1/search/subjects"), method: "POST",
                                               body: BangumiSubjectService.searchRequestBody(keyword: "Anime & title", filter: .anime))
        XCTAssertFalse(search.isEmpty)
        for path in ["missing", "wrong-user"] {
            do { _ = try await client.request(url: server.url(path), method: "GET"); XCTFail("404 expected") }
            catch let error as BangumiError {
                guard case .notFound(let body) = error else { return XCTFail("preserve 404 body") }
                let lookup = BangumiCollectionService.classifyCollectionResponse(status: 404, body: Data(body.utf8))
                switch lookup {
                case .notCollected: XCTAssertEqual(path, "missing")
                case .unknown: XCTAssertEqual(path, "wrong-user")
                case .collected: XCTFail("must not fabricate collection")
                }
            }
        }
        do { _ = try await client.request(url: server.url("server-error"), method: "GET"); XCTFail("503 expected") }
        catch let error as BangumiError {
            guard case .http(let code, let body, let id) = error else { return XCTFail("HTTP error expected") }
            XCTAssertEqual(code, 503); XCTAssertEqual(id, "fixture-request"); XCTAssertTrue(body.contains("upstream failed"))
        }
        do { _ = try await client.request(url: server.url("limited"), method: "GET"); XCTFail("429 expected") }
        catch let error as BangumiError {
            guard case .rateLimited(let seconds) = error else { return XCTFail("rate limit expected") }
            XCTAssertEqual(seconds, 0)
        }
        do { _ = try await client.request(url: server.url("mirror/p1/collections/episodes/1"), method: "PATCH", body: .object(["type": .int(2), "batch": .bool(true)])); XCTFail("503 expected") }
        catch { XCTAssertTrue(error is BangumiError) }
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("server-error") }.count, 3, "no nested Swift retries")
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("limited") }.count, 3)
        XCTAssertEqual(requests.filter { $0.method == "PATCH" }.count, 1)
        XCTAssertEqual(requests.first?.authorization, "Bearer fresh")
        XCTAssertNil(requests.first { $0.path == "/empty" }?.authorization)
    }
    func testOAuthAndSingleFlightRefreshUseCoreWithoutLeakingTokenToGateway() async throws {
        _ = try library()
        let server = try Server(); defer { server.stop() }
        let (client, store) = try makeClient(server, token: nil)
        let authorize = try await client.buildOAuthURL()
        let state = try XCTUnwrap(URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        _ = try await client.exchangeForAccessToken(code: "fixture-code", state: state)
        XCTAssertEqual(store.auth?.accessToken, "fresh")
        let (expired, refreshedStore) = try makeClient(server, token: "expired", expired: true)
        async let first = expired.request(url: server.url("one"), method: "GET", auth: .required)
        async let second = expired.request(url: server.url("two"), method: "GET", auth: .required)
        _ = try await (first, second)
        XCTAssertEqual(refreshedStore.auth?.accessToken, "fresh")
        XCTAssertEqual(refreshedStore.auth?.refreshToken, "refresh")
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("oauth/refresh") }.count, 1)
        for request in requests.filter({ $0.path.contains("/oauth/") }) {
            XCTAssertNil(request.authorization)
            XCTAssertEqual(request.apiKey, "gateway")
            XCTAssertTrue(request.userAgent?.hasPrefix("OcPlay/") == true)
        }
    }
    func testSignOutCancelsAuthorizedRustRequestAndRejectsStalePublication() async throws {
        _ = try library()
        let server = try Server(); defer { server.stop() }
        let (client, _) = try makeClient(server)
        let task = Task { try await client.request(url: server.url("slow"), method: "GET", auth: .required) }
        var started = false
        for _ in 0..<100 {
            if try await !server.requests().isEmpty { started = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(started)
        let start = ContinuousClock.now
        _ = await client.clearCredentials()
        do { _ = try await task.value; XCTFail("retired request must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }
    func testGatewayPermissionEnvelopeKeepsItsSemanticMessage() async throws {
        _ = try library()
        let server = try Server(); defer { server.stop() }
        let (client, _) = try makeClient(server, token: nil, gatewayKey: "scope")
        do { _ = try await client.buildOAuthURL(); XCTFail("permission failure expected") }
        catch let error as BangumiError {
            guard case .notice(let message) = error else { return XCTFail("gateway envelope must be preserved") }
            XCTAssertEqual(message, "网关 API Key 缺少 bgm:oauth 权限")
        }
        let requests = try await server.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTaskCancellationDropsRustRequest() async throws {
        _ = try library()
        let server = try Server(); defer { server.stop() }
        let (client, _) = try makeClient(server)
        let task = Task { try await client.request(url: server.url("slow"), method: "GET", auth: .disabled) }
        for _ in 0..<100 {
            if try await !server.requests().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class Server: @unchecked Sendable {
    struct Request: Decodable {
        let path, method, body: String
        let authorization, apiKey, userAgent: String?
    }
    let process = Process()
    let root: URL
    init() throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "native_bangumi", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = pipe
        try process.run()
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        root = URL(string: "http://127.0.0.1:\(port)")!
    }
    func url(_ path: String) -> URL { URL(string: root.absoluteString + "/" + path)! }
    func requests() async throws -> [Request] {
        let (data, _) = try await URLSession.shared.data(from: url("stats"))
        return try JSONDecoder().decode([Request].self, from: data)
    }
    func stop() { if process.isRunning { process.terminate() } }
}
#endif
