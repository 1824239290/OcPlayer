import CoreModel
import Foundation
import XCTest
@testable import JellyfinKit

#if os(macOS)
final class RustEndpointIntegrationTests: XCTestCase {
    private struct Stats: Decodable {
        let aReads: Int
        let bReads: Int
        let aProbes: Int
        let bProbes: Int
        let bMutations: Int
        let lastAuthorization: String?
        let lastUserAgent: String?
        let lastPath: String?
        let bProbePeerPorts: [Int]
    }
    private final class NotificationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    func testJellyfinCoreRequestsFollowDynamicEndpoints() async throws { try await check(kind: .jellyfin) }
    func testEmbyCoreRequestsFollowDynamicEndpoints() async throws { try await check(kind: .emby) }

    func testCoreProbeRetainsConnectionPoolIdentityValidationTimeoutAndCancellation() async throws {
        guard ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1",
              ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] != nil else {
            throw XCTSkip("Enable Core with OCP_CORE_LIBRARY_PATH for probe transport integration")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "native_endpoints", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let ports = try JSONDecoder().decode([Int].self, from: output.fileHandleForReading.availableData)
        let base = URL(string: "http://127.0.0.1:\(ports[1])/emby")!
        let probe = ServerProbe(timeout: 2, sessionConfiguration: .ephemeral)
        XCTAssertTrue(probe.usesCoreTransport)
        let before = ServerProbe.sessionCreationCountForTesting
        for _ in 0..<5 {
            let result = await probe.probe(url: base, expectedServerID: "srv-1")
            XCTAssertEqual(result?.serverID, "srv-1")
            XCTAssertEqual(result?.url, base)
        }
        let snapshot = try await stats(base: base)
        XCTAssertEqual(snapshot.bProbePeerPorts.count, 5)
        XCTAssertEqual(Set(snapshot.bProbePeerPorts).count, 1, "separate Core calls retain the same TCP connection")
        XCTAssertEqual(ServerProbe.sessionCreationCountForTesting, before, "production probes cannot fall through to URLSession")
        func variant(_ name: String) -> URL { URL(string: "http://127.0.0.1:\(ports[1])/\(name)")! }
        for name in ["empty", "html", "foreign"] {
            let result = await probe.probe(url: variant(name), expectedServerID: "srv-1")
            XCTAssertNil(result, "\(name) must not be selected as this server")
        }
        let missing = await probe.probe(url: variant("missing"), expectedServerID: "srv-1")
        XCTAssertEqual(missing?.serverName, "fixture", "missing ID alone does not make a server unreachable")
        let short = ServerProbe(timeout: 0.05, sessionConfiguration: .ephemeral)
        let start = Date()
        let timedOut = await short.probe(url: variant("slow"))
        XCTAssertNil(timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
        let cancelled = Task { await probe.probe(url: variant("slow")) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let cancelStart = Date()
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 0.3)
    }

    private func check(kind: ServerKind) async throws {
        guard let library = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for native endpoint integration")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "native_endpoints", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let ports = try JSONDecoder().decode([Int].self, from: output.fileHandleForReading.availableData)
        let a = URL(string: "http://127.0.0.1:\(ports[0])/emby")!
        let b = URL(string: "http://127.0.0.1:\(ports[1])/emby")!
        let defaultsName = "RustEndpointIntegration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
        var profile = ServerProfile(id: "srv-1:u1", serverName: "fixture", baseURL: a, userID: "u1",
                                    kind: kind, addresses: [ServerAddress(url: b)], serverID: "srv-1")
        store.activate(profile, token: "fixture-token")
        let fallback: any MediaServer
        if kind == .jellyfin { fallback = try XCTUnwrap(JellyfinServer.resume(profile: profile, from: store)) }
        else { fallback = try XCTUnwrap(EmbyServer.resume(profile: profile, from: store)) }
        let core = try XCTUnwrap(RustCoreMediaServer(wrapping: fallback, libraryPath: library))
        let directory = store.endpointDirectory(for: profile)
        if ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1" { XCTAssertTrue(directory.usesCorePolicy) }
        let oldAgent = UserDefaults.standard.object(forKey: ClientIdentity.customUserAgentKey)
        UserDefaults.standard.set("OcPlayer-endpoint-fixture-1", forKey: ClientIdentity.customUserAgentKey)
        defer {
            if let oldAgent { UserDefaults.standard.set(oldAgent, forKey: ClientIdentity.customUserAgentKey) }
            else { UserDefaults.standard.removeObject(forKey: ClientIdentity.customUserAgentKey) }
        }
        let libraries = try await core.userViews()
        XCTAssertEqual(libraries.map(\.id), ["lib-1"])
        XCTAssertEqual(core.profile.baseURL, b)
        let first = try await stats(base: b)
        XCTAssertEqual(first.aReads, 3, "Rust owns retry on the failed endpoint")
        XCTAssertEqual(first.bReads, 1, "the facade retries the read through Rust at the selected alternate")
        XCTAssertEqual(first.lastAuthorization, fallback.authorizationHeader, "retain native device/client identity")
        XCTAssertEqual(first.lastUserAgent, "OcPlayer-endpoint-fixture-1")
        XCTAssertEqual(first.lastPath, kind == .emby ? "/emby/Users/u1/Views" : "/emby/UserViews")

        profile.pinnedURL = b
        directory.sync(profile: profile)
        XCTAssertEqual(try core.imageURL(itemID: "item", type: .primary, maxWidth: nil, tag: nil).port, ports[1])
        UserDefaults.standard.set("OcPlayer-endpoint-fixture-2", forKey: ClientIdentity.customUserAgentKey)
        _ = try await core.userViews()
        let pinned = try await stats(base: b)
        XCTAssertEqual(pinned.lastUserAgent, "OcPlayer-endpoint-fixture-2", "preference changes apply without rebuilding the facade")
        do { _ = try await core.markPlayed(itemID: "item"); XCTFail("mutation failure must propagate") }
        catch let error as RustCoreMediaServerError { XCTAssertEqual(error.code, 2100) }
        let mutation = try await stats(base: b)
        XCTAssertEqual(mutation.bMutations, 1, "a possibly accepted POST is never replayed")

        let notifications = NotificationBox()
        let observer = NotificationCenter.default.addObserver(forName: MediaServerAuthentication.authenticationRequired, object: nil, queue: nil) {
            if let id = $0.object as? String { notifications.add(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await control(base: b, mode: "401")
        do { _ = try await core.userViews(); XCTFail("401 must propagate") }
        catch let error as RustCoreMediaServerError { XCTAssertEqual(error.code, 2001); XCTAssertFalse(error.retryable) }
        XCTAssertEqual(notifications.all, [profile.id])

        let beforeStatus = try await stats(base: b)
        try await control(base: b, mode: "503")
        do { _ = try await core.userViews(); XCTFail("503 must propagate") }
        catch let error as RustCoreMediaServerError { XCTAssertEqual(error.code, 2103); XCTAssertTrue(error.retryable) }
        let afterStatus = try await stats(base: b)
        XCTAssertEqual(afterStatus.bReads - beforeStatus.bReads, 3)
        XCTAssertEqual(afterStatus.aProbes, beforeStatus.aProbes)
        XCTAssertEqual(afterStatus.bProbes, beforeStatus.bProbes, "HTTP server errors do not trigger address probing")
        XCTAssertEqual(notifications.all, [profile.id], "503 cannot ask the user to log in again")
    }

    private func stats(base: URL) async throws -> Stats {
        let url = URL(string: "http://127.0.0.1:\(base.port!)/stats")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Stats.self, from: data)
    }
    private func control(base: URL, mode: String) async throws {
        let url = URL(string: "http://127.0.0.1:\(base.port!)/control?mode=\(mode)")!
        _ = try await URLSession.shared.data(from: url)
    }
}
#endif
