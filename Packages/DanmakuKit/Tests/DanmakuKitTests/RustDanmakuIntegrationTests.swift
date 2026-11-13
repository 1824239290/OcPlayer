import Foundation
import XCTest
import DiagnosticsKit
import OcPlayerCore
@testable import DanmakuKit

#if os(macOS)
final class RustDanmakuIntegrationTests: XCTestCase {
    private final class Fixture {
        let process = Process()
        let base: URL
        init() throws {
            guard OcpCoreFeature.isEnabled,
                  ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] != nil else {
                throw XCTSkip("Enable Core with OCP_CORE_LIBRARY_PATH for native gateway fixtures")
            }
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", Bundle.module.url(forResource: "danmaku_server", withExtension: "py", subdirectory: "Fixtures")!.path]
            process.standardOutput = pipe
            try process.run()
            let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        deinit { if process.isRunning { process.terminate() } }
        func client(policy: RetryPolicy = RetryPolicy(attempts: 1)) -> DanmakuGatewayClient {
            DanmakuGatewayClient(configuration: DandanplayConfiguration(baseURL: base, apiKey: "key", userAgent: "OcPlay/fixture"), retryPolicy: policy)
        }
        struct Record: Decodable { let path, method, body, key, agent: String; let port: Int }
        func records() async throws -> [Record] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try JSONDecoder().decode([Record].self, from: data)
        }
    }

    func testProductionActivationAndInjectedTransportGate() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.client().usesCoreTransport)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let injected = DanmakuGatewayClient(configuration: .init(baseURL: URL(string: "https://example.com")!, apiKey: "k", userAgent: "OcPlay/test"), session: URLSession(configuration: configuration))
        XCTAssertFalse(injected.usesCoreTransport)
        XCTAssertTrue(DanmakuGatewayClient(configuration: .init(baseURL: URL(string: "https://example.com")!, apiKey: "k", userAgent: "OcPlay/test")).usesCoreTransport)
    }

    func testAllWireResponsesKeepCommentsModesCacheAndPool() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        // Invoke the exchange boundary to use a local HTTP fixture. Public methods
        // keep their existing HTTPS-origin validation (covered by GatewayClientTests).
        let matched: GatewayResult<MatchResponse> = try await client.send(url: fixture.base.appendingPathComponent("v1/match"), method: "POST", body: Data("{\"fileHash\":\"abc\"}".utf8))
        XCTAssertEqual(matched.payload.matches.first?.episodeId, 42000001)
        XCTAssertEqual(matched.payload.matches.first?.shift, -2)
        let anime: GatewayResult<SearchAnimeResponse> = try await client.send(url: URL(string: fixture.base.absoluteString + "/v1/search/anime?keyword=%E4%B8%AD%20%26")!, method: "GET", body: nil)
        XCTAssertEqual(anime.payload.animes.first?.animeTitle, "中 &")
        let episodes: GatewayResult<SearchEpisodesResponse> = try await client.send(url: URL(string: fixture.base.absoluteString + "/v1/search/episodes?tmdbId=42&tmdbIdType=1&episode=S1")!, method: "GET", body: nil)
        XCTAssertEqual(episodes.payload.animes.first?.episodes.first?.episodeId, 42000001)
        let comments: GatewayResult<CommentResponse> = try await client.send(url: URL(string: fixture.base.absoluteString + "/v1/comments/42000001?withRelated=true&chConvert=0")!, method: "GET", body: nil)
        XCTAssertEqual(comments.payload.comments?.map(\.cid), [1,2,3])
        XCTAssertEqual(comments.payload.comments?.map(\.p), ["1,1,16777215,0","2,5,255,0","3,4,123,0"])
        XCTAssertEqual(comments.cacheStatus, "HIT")
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map(\.port)).count, 1)
        XCTAssertTrue(records.allSatisfy { $0.key == "key" && $0.agent == "OcPlay/fixture" })
    }

    func testTypedErrorsAndSoleRetryOwner() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        for (scenario, expected) in [("status401", DandanplayError.unauthorized), ("status403", .forbidden), ("status429", .rateLimited(retryAfter: 0.01)), ("status503", .httpStatus(503)), ("business", .businessError(code:4321, message:"missing"))] {
            do {
                let _: GatewayResult<SearchAnimeResponse> = try await client.send(url: URL(string: fixture.base.absoluteString + "/v1/search/anime?scenario=\(scenario)")!, method: "GET", body: nil)
                XCTFail("Must reject \(scenario)")
            } catch let error as DandanplayError { XCTAssertEqual(error, expected) }
        }
        let retrying = fixture.client(policy: RetryPolicy(attempts: 3, base: 0, jitter: 0...0))
        do {
            let _: GatewayResult<SearchAnimeResponse> = try await retrying.send(url: URL(string: fixture.base.absoluteString + "/v1/search/anime?scenario=status503")!, method: "GET", body: nil)
            XCTFail("Must fail")
        } catch let error as DandanplayError { XCTAssertEqual(error, .httpStatus(503)) }
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 8, "five one-attempt failures plus three native retries")
    }

    func testCancellationDoesNotReplay() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        let url = URL(string: fixture.base.absoluteString + "/v1/search/anime?scenario=slow")!
        let task = Task { () -> GatewayResult<SearchAnimeResponse> in
            try await client.send(url: url, method: "GET", body: nil)
        }
        for _ in 0..<100 {
            if !(try await fixture.records()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 1)
    }
}
#endif
