import XCTest
@testable import MoviePilotKit

#if os(macOS)
final class RustMoviePilotIntegrationTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for native integration tests")
        }
        return path
    }

    @MainActor
    private static func makeClient(_ server: NativeServer, library: String, token: String = "fresh") throws -> MoviePilotAPIClient {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(UUID().uuidString),
                                    credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
        store.updateCredentials(serverURLString: server.baseURL, username: "fixture", password: "fixture")
        store.accessToken = token
        return MoviePilotAPIClient(store: store, sessionConfiguration: .ephemeral, rustCoreLibraryPath: library)
    }

    func testRawPayloadUserFieldsAndMalformedList() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        let user = try await client.currentUser()
        XCTAssertEqual(user.isSuperuser, true)
        let media = try await client.searchMedia(title: "native")
        XCTAssertEqual(media.first?.tmdbId, 1)
        XCTAssertEqual(media.first?.raw["enabled"], .bool(false))
        XCTAssertEqual(media.first?.raw["unknown_field"]?["zero"], .number(0))
        do { _ = try await client.searchMedia(title: "malformed"); XCTFail("malformed data must fail") }
        catch { XCTAssertTrue(error is MoviePilotError) }
    }

    func testRetainedCoreReusesConnectionAndAccountCookieAcrossCommands() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        _ = try await client.currentUser()
        _ = try await client.searchMedia(title: "pooled")
        _ = try await client.currentUser()
        let requests = try await server.requests()
        XCTAssertEqual(Set(requests.compactMap(\.port)).count, 1)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.first?.cookie, "")
        XCTAssertEqual(requests[1].cookie, "MoviePilot=fixture")
    }

    func testConcurrentStreamsRouteEachPartialToItsOwnRequest() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        let first = expectation(description: "first stream partial")
        let second = expectation(description: "second stream partial")
        let a = Task {
            try await client.searchTorrentsByTitleStream(keyword: "concurrent-a") { items, progress in
                XCTAssertTrue(progress.text?.hasPrefix("concurrent-a:") == true)
                XCTAssertTrue(items.allSatisfy { $0.enclosure?.hasPrefix("concurrent-a:") == true })
                if progress.text == "concurrent-a:partial" { first.fulfill() }
            }
        }
        let b = Task {
            try await client.searchTorrentsByTitleStream(keyword: "concurrent-b") { items, progress in
                XCTAssertTrue(progress.text?.hasPrefix("concurrent-b:") == true)
                XCTAssertTrue(items.allSatisfy { $0.enclosure?.hasPrefix("concurrent-b:") == true })
                if progress.text == "concurrent-b:partial" { second.fulfill() }
            }
        }
        await fulfillment(of: [first, second], timeout: 0.5)
        let valuesA = try await a.value
        let valuesB = try await b.value
        XCTAssertEqual(valuesA.compactMap(\.enclosure), ["concurrent-a:new", "concurrent-a:last"])
        XCTAssertEqual(valuesB.compactMap(\.enclosure), ["concurrent-b:new", "concurrent-b:last"])
    }

    func testCancellingOneConcurrentStreamKeepsTheOtherAlive() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        let partial = expectation(description: "stream started before cancellation")
        let a = Task {
            try await client.searchTorrentsByTitleStream(keyword: "concurrent-a") { _, progress in
                if progress.text == "concurrent-a:partial" { partial.fulfill() }
            }
        }
        let b = Task { try await client.searchTorrentsByTitleStream(keyword: "concurrent-b") }
        await fulfillment(of: [partial], timeout: 0.5)
        a.cancel()
        do { _ = try await a.value; XCTFail("cancelled stream must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let values = try await b.value
        XCTAssertEqual(values.compactMap(\.enclosure), ["concurrent-b:new", "concurrent-b:last"])
    }

    func testFailedCreationIsSentExactlyOnceWithoutSwiftReplay() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        do {
            try await client.addDownload(media: MPMediaInfo(raw: ["title": .string("test")]),
                                         torrent: MPTorrent(raw: ["seeders": .number(0)]))
            XCTFail("503 must fail")
        } catch { XCTAssertTrue(error is MoviePilotError) }
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.method == "POST" }.count, 1)
        let body = try XCTUnwrap(requests.first?.body)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(body.utf8))
        XCTAssertEqual(payload["torrent_in"]?["seeders"], .number(0))
    }

    func testSSEPublishesBeforeCompletionAndHonorsReplace() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        let progress = expectation(description: "partial while stream is live")
        let task = Task {
            try await client.searchTorrentsByTitleStream(keyword: "native") { items, state in
                if state.text == "partial" {
                    XCTAssertEqual(items.first?.enclosure, "old")
                    progress.fulfill()
                }
            }
        }
        await fulfillment(of: [progress], timeout: 0.45)
        let results = try await task.value
        XCTAssertEqual(results.compactMap(\.enclosure), ["new", "last"])
        XCTAssertEqual(results.compactMap(\.seeders), [0, 1])
    }

    func testSignOutRejectsInFlightNativeResult() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        let request = Task { try await client.searchMedia(title: "slow") }
        for _ in 0..<100 {
            if try await !server.requests().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await client.signOut()
        do { _ = try await request.value; XCTFail("retired session must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExpiredTokenReloginsAndEncodedDeleteRemainsOneSegment() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library(), token: "expired")
        let user = try await client.currentUser()
        XCTAssertEqual(user.name, "native")
        try await client.deleteSubscribeByMedia(mediaId: "tmdb:1/2?query#fragment")
        let requests = try await server.requests()
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("access-token") }.count, 1)
        XCTAssertEqual(requests.last?.path, "/api/v1/subscribe/media/tmdb%3A1%2F2%3Fquery%23fragment")
    }

    func testCancellationAbortsNativeRequestBeforeServerFinishes() async throws {
        _ = try library()
        let server = try NativeServer()
        defer { server.stop() }
        let client = try await Self.makeClient(server, library: library())
        let request = Task { try await client.searchMedia(title: "cancel") }
        var started = false
        for _ in 0..<100 {
            if try await !server.requests().isEmpty { started = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(started)
        let start = ContinuousClock.now
        request.cancel()
        do { _ = try await request.value; XCTFail("cancelled native request must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }
}

final class NativeServer: @unchecked Sendable {
    struct Request: Decodable { let method: String; let path: String; let body: String?; let port: Int?; let cookie: String?; let authorization: String?; let contentType: String?; let bodyBase64: String? }
    let process = Process()
    let baseURL: String

    init() throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = Bundle.module.url(forResource: "native_server", withExtension: "py", subdirectory: "Fixtures")!
        process.arguments = ["-u", script.path]
        process.standardOutput = output
        try process.run()
        let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(port) != nil else { process.terminate(); throw URLError(.cannotConnectToHost) }
        baseURL = "http://127.0.0.1:\(port)"
    }
    func stop() { if process.isRunning { process.terminate() } }
    func requests() async throws -> [Request] {
        let url = URL(string: baseURL + "/stats")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Request].self, from: data)
    }
}
#endif
