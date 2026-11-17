import Foundation
import XCTest
@testable import JellyfinKit

#if os(macOS)
final class RustLoginIntegrationTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        let process = Process()
        let baseURL: URL
        init() throws {
            guard ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1",
                  ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] != nil else {
                throw XCTSkip("Enable Core with OCP_CORE_LIBRARY_PATH for native login fixtures")
            }
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", Bundle.module.url(forResource: "media_login_server", withExtension: "py", subdirectory: "Fixtures")!.path]
            process.standardOutput = pipe
            try process.run()
            let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            baseURL = URL(string: "http://127.0.0.1:\(port)")!
        }
        deinit { if process.isRunning { process.terminate() } }
        func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }
        func start(_ path: String, configuration: URLSessionConfiguration = .default) async throws -> any ServerLoginSession {
            try await MediaServerLogin.start(urlString: url(path).absoluteString, sessionConfiguration: configuration)
        }
        struct Record: Decodable { let path: String; let method: String; let authorization: String?; let embyAuthorization: String?; let agent: String?; let port: Int; let body: [String: String]? }
        func records() async throws -> [Record] {
            let (data, _) = try await URLSession.shared.data(from: url("stats"))
            return try JSONDecoder().decode([Record].self, from: data)
        }
    }

    func testDefaultProductionJellyfinLoginUsesCoreStableIdentityAndStoresAvatar() async throws {
        let fixture = try Fixture()
        let key = ClientIdentity.customUserAgentKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        UserDefaults.standard.set("login-agent/1", forKey: key)
        let session = try await fixture.start("proxy/jellyfin")
        XCTAssertTrue(try XCTUnwrap(session as? JellyfinLoginSession).usesCoreTransport)
        UserDefaults.standard.set("login-agent/2", forKey: key)
        let result = try await session.signIn(username: "中 &", password: "p &中")
        XCTAssertEqual(result.token, "token")
        XCTAssertEqual(result.userID, "u1")
        XCTAssertEqual(result.primaryImageTag, "avatar")
        let suite = "RustLogin-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
        let server = try session.finish(result, store: store)
        XCTAssertEqual(server.profile.id, "server-1:u1")
        XCTAssertEqual(server.profile.primaryImageTag, "avatar")
        let records = try await fixture.records()
        XCTAssertEqual(records.map(\.path), ["/proxy/jellyfin/System/Info/Public", "/proxy/jellyfin/Users/AuthenticateByName"])
        XCTAssertEqual(Set(records.map(\.port)).count, 1)
        XCTAssertEqual(records.last?.body, ["Username":"中 &", "Pw":"p &中"])
        XCTAssertEqual(records.first?.agent, "login-agent/1")
        XCTAssertEqual(records.last?.agent, "login-agent/2")
        for record in records {
            XCTAssertEqual(record.authorization, ClientIdentity.mediaBrowserAuthorizationHeader())
            XCTAssertEqual(record.embyAuthorization, record.authorization)
        }
    }

    func testEmbyLoginKeepsPrefixAndProductIdentity() async throws {
        let fixture = try Fixture()
        let session = try await fixture.start("proxy/embyserver", configuration: .ephemeral)
        XCTAssertTrue(try XCTUnwrap(session as? EmbyLoginSession).usesCoreTransport)
        XCTAssertFalse(session.supportsQuickConnect)
        XCTAssertEqual(session.baseURL.path, "/proxy/embyserver/emby")
        let result = try await session.signIn(username: "optionalTypes", password: "p")
        XCTAssertNil(result.userName)
        XCTAssertNil(result.primaryImageTag)
        do { _ = try await session.signIn(quickConnectSecret: "secret"); XCTFail("Emby cannot pair") }
        catch let error as JellyfinError { guard case .quickConnectDisabled = error.kind else { return XCTFail("\(error)") } }
        var events = 0
        for try await _ in session.quickConnectEvents { events += 1 }
        XCTAssertEqual(events, 0)
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.path, "/proxy/embyserver/emby/Users/AuthenticateByName")
        XCTAssertEqual(records.last?.authorization, ClientIdentity.authorizationHeader(scheme: "Emby"))
    }

    func testProductionProbeRetainsTransientRetry() async throws {
        let fixture = try Fixture()
        let session = try await fixture.start("retryprobe")
        XCTAssertTrue(try XCTUnwrap(session as? JellyfinLoginSession).usesCoreTransport)
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 3)
    }

    func testAuthenticationFailuresRemainTypedAndNeverReplay() async throws {
        let fixture = try Fixture()
        let session = try await fixture.start("jellyfin")
        for name in ["status400","status401","status403","status410","status411","status503","invalidJSON","missingToken","wrongToken","missingID"] {
            do { _ = try await session.signIn(username: name, password: "p"); XCTFail("\(name) must fail") }
            catch let error as JellyfinError {
                switch (name, error.kind) {
                case ("status403", .forbidden), ("status410", .http(status:410)), ("status411", .http(status:411)), ("status503", .http(status:503)): break
                case (_, .unauthorized) where name != "status403" && name != "status503": break
                default: XCTFail("unexpected \(name): \(error)")
                }
            }
        }
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 11, "probe plus one attempt per login")
    }

    func testPublicQuickConnectPairsAndAuthenticates() async throws {
        let fixture = try Fixture()
        let session = try await fixture.start("qc")
        var events: [QuickConnectEvent] = []
        for try await event in session.quickConnectEvents { events.append(event) }
        XCTAssertEqual(events, [.polling("123456"), .authenticated("authorized qc ?&中")])
        let result = try await session.signIn(quickConnectSecret: "authorized qc ?&中")
        XCTAssertEqual(result.token, "token")
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 6)
        XCTAssertEqual(records.last?.body, ["Secret":"authorized qc ?&中"])
        XCTAssertEqual(records.filter { $0.path.contains("/QuickConnect/Connect") }.count, 3)
    }

    func testQuickConnectDisabledAndMalformedIssuanceSurfaceError() async throws {
        let fixture = try Fixture()
        for path in ["disabled", "missing"] {
            let session = try await fixture.start(path)
            do {
                for try await _ in session.quickConnectEvents { XCTFail("cannot issue code") }
                XCTFail("must fail")
            } catch let error as JellyfinError {
                if path == "disabled" { guard case .quickConnectDisabled = error.kind else { return XCTFail("\(error)") } }
            }
        }
    }

    func testSharedPollingFailureBudgetAndTimeout() async throws {
        let fixture = try Fixture()
        let core = try XCTUnwrap(RustServerLogin(configuration: .default))
        var events: [QuickConnectEvent] = []
        for try await event in core.quickConnectEvents(baseURL: fixture.url("reset"), pollInterval: 0.01, maxPolls: 4, failureTolerance: 1) { events.append(event) }
        XCTAssertEqual(events, [.polling("123456"), .authenticated("authorized reset ?&中")])
        do {
            for try await _ in core.quickConnectEvents(baseURL: fixture.url("timeout"), pollInterval: 0.01, maxPolls: 2) {}
            XCTFail("must time out")
        } catch let error as JellyfinError { guard case .quickConnectTimeout = error.kind else { return XCTFail("\(error)") } }
        do {
            for try await _ in core.quickConnectEvents(baseURL: fixture.url("exhaust"), pollInterval: 0.01, failureTolerance: 1) {}
            XCTFail("must exhaust")
        } catch let error as JellyfinError { guard case .http(status:503) = error.kind else { return XCTFail("\(error)") } }
        let records = try await fixture.records()
        XCTAssertEqual(records.filter { $0.path.hasPrefix("/exhaust/QuickConnect/Connect") }.count, 2)
    }

    func testCancellationStopsInflightLoginAndProbe() async throws {
        let fixture = try Fixture()
        let session = try await fixture.start("jellyfin")
        let task = Task { try await session.signIn(username: "slow", password: "p") }
        try await Task.sleep(for: .milliseconds(40))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(JellyfinError.isCancellation(error)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        let probe = Task { try await fixture.start("slowprobe") }
        try await Task.sleep(for: .milliseconds(40))
        probe.cancel()
        do { _ = try await probe.value; XCTFail("cancelled probe") } catch { XCTAssertTrue(JellyfinError.isCancellation(error)) }
    }

    func testCancellingPairingDoesNotCancelConcurrentLogin() async throws {
        let fixture = try Fixture()
        let session = try await fixture.start("timeout")
        let task = Task {
            for try await _ in session.quickConnectEvents {}
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        try await task.value
        let count = try await fixture.records().count
        let result = try await session.signIn(username: "fixture", password: "p")
        XCTAssertEqual(result.token, "token")
        try await Task.sleep(for: .milliseconds(100))
        let records = try await fixture.records()
        XCTAssertEqual(records.count, count+1, "cancelled pairing cannot keep polling")
    }

    func testInjectedURLProtocolKeepsNativeLoginTransport() async throws {
        try await TestSupport.withMock { request in
            if request.url!.path.hasSuffix("/System/Info/Public") {
                return MockURLProtocol.ok("{\"Id\":\"native\",\"ProductName\":\"Jellyfin Server\"}", for: request.url!)
            }
            return MockURLProtocol.ok("{\"AccessToken\":\"native-token\",\"User\":{\"Id\":\"native-user\"}}", for: request.url!)
        } with: {
            let session = try await MediaServerLogin.start(urlString: "http://fixture.invalid", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertFalse(try XCTUnwrap(session as? JellyfinLoginSession).usesCoreTransport)
            let result = try await session.signIn(username: "u", password: "p")
            XCTAssertEqual(result.token, "native-token")
        }
    }
}
#endif
