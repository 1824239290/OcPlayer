import DiagnosticsKit
import Foundation
import OcPlayerCore
import XCTest
@testable import DanmakuKit

final class RustIntroProviderTests: XCTestCase {
    private func policy() throws -> RustDanmakuPolicy {
        guard let policy = RustDanmakuPolicy.active else { throw XCTSkip("Enable Core for provider comparisons") }
        return policy
    }

    func testAniSkipDecoderUnicodeDuplicatesMalformedAndUnknownTypes() throws {
        let policy = try policy()
        let samples = [
            "{}", "{\"found\":false}", "{\"found\":true}", "{\"found\":true,\"results\":null}",
            "{\"found\":false,\"found\":true}",
            "{\"found\":true,\"unknown\":\"\\ud800\"}",
            "{\"found\":true,\"unknown\":\"\\q\"}",
            "{\"found\":true,\"unknown\":\"a\nb\"}",
            "{\"found\":true,\"unknown\":\"\\u12\"}",
            "{\"found\":false,\"results\":[{}]}",
            "{\"found\":true,\"results\":[{\"skipType\":\"future\",\"interval\":{\"startTime\":0,\"endTime\":90}}]}",
            "{\"found\":true,\"results\":[{\"skipType\":\"op\",\"skipType\":\"ed\",\"interval\":{\"startTime\":0,\"endTime\":90}}]}",
            "{\"found\":true,\"results\":[{\"skipType\":\"op\",\"interval\":{\"startTime\":0.10000000000000001,\"endTime\":90.12345678901234}}]}",
        ]
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .utf32LittleEndian, .utf32BigEndian]
        for sample in samples {
            for encoding in encodings {
                let bytes = try XCTUnwrap(sample.data(using: encoding))
                let native = Result { try AniSkipClient.decodeNative(bytes) }
                let shared: Result<[AniSkipInterval]?, Error> = Result {
                    try policy.provider("decodeAniSkip", arguments: ["responseBase64": bytes.base64EncodedString()])
                }
                switch (native, shared) {
                case (.success(let a), .success(let b)): XCTAssertEqual(a, b, sample)
                case (.failure, .failure): break
                default: XCTFail("Different decode outcome: \(sample), encoding \(encoding)")
                }
            }
        }
        let corrupt = Data([123, 34, 102, 111, 117, 110, 100, 34, 58, 116, 114, 117, 101, 44, 34, 120, 34, 58, 34, 255, 34, 125])
        let native = try AniSkipClient.decodeNative(corrupt)
        let shared: [AniSkipInterval]? = try policy.provider("decodeAniSkip", arguments: ["responseBase64": corrupt.base64EncodedString()])
        XCTAssertEqual(native, shared)
    }

    func testHintClampAndTimestampSelectionAgainstNative() throws {
        let policy = try policy()
        for index in 0..<600 {
            let start = Double((index * 37) % 1900 - 100)
            let end = Double((index * 89) % 2000)
            let intervals = [AniSkipInterval(type: .opening, startSeconds: start, endSeconds: end),
                             AniSkipInterval(type: .opening, startSeconds: 0, endSeconds: 90)]
            let shared: DanmakuIntroHint? = try policy.providerPayload("aniskipHint", value: intervals)
            XCTAssertEqual(shared, DanmakuIntroHint(nativeAniskipIntervals: intervals))
            let interval = ExternalSkipInterval(startSeconds: index % 3 == 0 ? nil : start, endSeconds: end)
            let clamp: ExternalSkipInterval? = try policy.providerPayload("clamp", value: interval)
            XCTAssertEqual(clamp, interval.clampedNative())
            let episodes: [AnimeSkipClient.Response.Episode] = [
                .init(season: nil, number: "+01", timestamps: [
                    .init(at: end, type: nil), .init(at: start, type: .init(name: index % 2 == 0 ? "Intro" : "New Intro"))]),
                .init(season: "2", number: "1", timestamps: [
                    .init(at: start, type: .init(name: "Mixed Intro")), .init(at: end, type: .init(name: "Canon"))])]
            let season = index % 2 == 0 ? 1 : 2
            let selected: ExternalSkipInterval? = try policy.providerPayload("animeInterval", value: episodes,
                arguments: ["seasonNumber": season, "episodeNumber": 1])
            XCTAssertEqual(selected, AnimeSkipClient.introIntervalNative(from: episodes, seasonNumber: season, episodeNumber: 1))
        }
        let episodes: [AnimeSkipClient.Response.Episode] = [.init(season: "1", number: "1", timestamps: [
            .init(at: 0, type: .init(name: "Intro")), .init(at: -0.0, type: .init(name: "Canon")), .init(at: 90, type: nil)])]
        let selected: ExternalSkipInterval? = try policy.providerPayload("animeInterval", value: episodes, arguments: ["episodeNumber": 1])
        XCTAssertEqual(selected?.endSeconds, 0)
    }

    func testIntroDBStrictIntegersFirstSegmentAndUnicode() throws {
        let policy = try policy()
        for raw in ["{}", "{\"intro\":[]}", "{\"intro\":[{}, {\"start_ms\":0,\"end_ms\":90000}]}",
            "{\"intro\":[\"\\ud800\"]}", "\"\\ud800\"",
            "{\"intro\":[{\"start_ms\":-10.0,\"end_ms\":9e4}]}",
            "{\"intro\":[{\"start_ms\":0,\"end_ms\":90000.1}]}",
            "{\"intro\":[{\"start_ms\":0,\"end_ms\":90000}, {\"end_ms\":\"bad\"}]}",
            "{\"intro\":[{\"start_ms\":0,\"end_ms\":9223372036854775807}]}"] {
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf32BigEndian] {
                let bytes = try XCTUnwrap(raw.data(using: encoding))
                let native = Result { try TheIntroDBClient.decodeNative(bytes) }
                let core: Result<ExternalSkipInterval?, Error> = Result {
                    try policy.provider("decodeTheIntroDB", arguments: ["responseBase64": bytes.base64EncodedString()])
                }
                switch (native, core) {
                case (.success(let a), .success(let b)): XCTAssertEqual(a, b, raw)
                case (.failure, .failure): break
                default: XCTFail("Different IntroDB outcome: \(raw)")
                }
            }
        }
    }

    #if os(macOS)
    private final class Fixture {
        let process = Process()
        let base: URL
        init() throws {
            guard OcpCoreFeature.isEnabled, ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] != nil else {
                throw XCTSkip("Enable Core with its library path for HTTP fixtures")
            }
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", Bundle.module.url(forResource: "intro_provider_server", withExtension: "py", subdirectory: "Fixtures")!.path]
            process.standardOutput = pipe
            try process.run()
            let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        deinit { if process.isRunning { process.terminate() } }
        struct Record: Decodable { let path, method, body, agent, clientID, accept, contentType: String; let port: Int }
        func records() async throws -> [Record] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            return try JSONDecoder().decode([Record].self, from: data)
        }
    }

    func testActivationAndURLProtocolGateForEveryProvider() throws {
        let f = try Fixture()
        XCTAssertTrue(AniSkipClient(baseURL: f.base).usesCoreTransport)
        XCTAssertTrue(AnimeSkipClient(clientID: "key", baseURL: f.base).usesCoreTransport)
        XCTAssertTrue(TheIntroDBClient(baseURL: f.base).usesCoreTransport)
        XCTAssertTrue(AniListClient(session: DanmakuNetworking.makeSession(), baseURL: f.base).usesCoreTransport)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        XCTAssertFalse(AniSkipClient(session: session).usesCoreTransport)
        XCTAssertFalse(AnimeSkipClient(clientID: "key", session: session).usesCoreTransport)
        XCTAssertFalse(TheIntroDBClient(session: session).usesCoreTransport)
        XCTAssertFalse(AniListClient(session: session).usesCoreTransport)
    }

    func testPublicProviderRequestsAndAniListFallbackThroughRealHTTP() async throws {
        let f = try Fixture()
        let ani = AniSkipClient(baseURL: f.base, retryPolicy: RetryPolicy(attempts: 1))
        let intervals = try await ani.skipTimes(malID: 42, episodeNumber: 1, episodeLengthSeconds: nil)
        XCTAssertEqual(intervals?.first?.endSeconds, 728)
        _ = try await ani.skipTimes(malID: 42, episodeNumber: 1, episodeLengthSeconds: -1)
        let anime = try await AnimeSkipClient(clientID: "fixture-key", baseURL: f.base)
            .introInterval(anilistID: Int.max, seasonNumber: 2, episodeNumber: 1)
        XCTAssertEqual(anime, ExternalSkipInterval(startSeconds: 30, endSeconds: 100))
        let db = try await TheIntroDBClient(baseURL: f.base).introInterval(tmdbID: 42, seasonNumber: nil, episodeNumber: 1)
        XCTAssertEqual(db, ExternalSkipInterval(startSeconds: 0, endSeconds: 90))
        let list = AniListClient(session: DanmakuNetworking.makeSession(), baseURL: f.base)
        let ids = await list.resolveIDs(anilistID: 42, searchTitles: [])
        XCTAssertEqual(ids, AniSkipResolvedIDs(malID: 100000, anilistID: 42))
        let only = await list.resolveIDs(anilistID: 404, searchTitles: [])
        XCTAssertEqual(only, AniSkipResolvedIDs(malID: nil, anilistID: 404))
        let fallback = await list.resolveIDs(anilistID: nil, searchTitles: ["主标题", "作品名稱"])
        XCTAssertEqual(fallback, AniSkipResolvedIDs(malID: 78, anilistID: 56))
        let records = try await f.records()
        XCTAssertEqual(records.count, 8)
        XCTAssertEqual(records[0].port, records[1].port)
        XCTAssertEqual(records[4].port, records[7].port)
        XCTAssertTrue(records.allSatisfy { $0.accept == "application/json" && $0.agent.contains("OcPlayer") })
        XCTAssertTrue(records[0].path.contains("types=op&types=ed&types=mixed-op&types=mixed-ed&episodeLength=0"))
        let body = try JSONSerialization.jsonObject(with: Data(records[2].body.utf8)) as! [String: Any]
        XCTAssertEqual((body["variables"] as? [String: String])?["id"], String(Int.max))
        XCTAssertEqual(records[2].clientID, "fixture-key")
    }

    func testStatusAndDecodeFailuresPreserveTypesWithoutHTTPReplay() async throws {
        let f = try Fixture()
        let ani = AniSkipClient(baseURL: f.base, retryPolicy: RetryPolicy(attempts: 3, base: 0, jitter: 0...0))
        let missing = try await ani.skipTimes(malID: 404, episodeNumber: 1, episodeLengthSeconds: nil)
        XCTAssertNil(missing)
        do { _ = try await ani.skipTimes(malID: 503, episodeNumber: 1, episodeLengthSeconds: nil); XCTFail("Expected HTTP failure") }
        catch AniSkipError.httpStatus(let code) { XCTAssertEqual(code, 503) }
        do { _ = try await TheIntroDBClient(baseURL: f.base).introInterval(tmdbID: 404, seasonNumber: nil, episodeNumber: 1); XCTFail("Expected HTTP failure") }
        catch AnimeSkipClient.AnimeSkipError.http(let code) { XCTAssertEqual(code, 404) }
        do { _ = try await AnimeSkipClient(clientID: "key", baseURL: f.base).introInterval(anilistID: 503, seasonNumber: nil, episodeNumber: 1); XCTFail("Expected HTTP failure") }
        catch AnimeSkipClient.AnimeSkipError.http(let code) { XCTAssertEqual(code, 503) }
        do { _ = try await AniSkipClient(baseURL: f.base.appendingPathComponent("malformed"), retryPolicy: RetryPolicy(attempts: 3, base: 0, jitter: 0...0))
            .skipTimes(malID: 42, episodeNumber: 1, episodeLengthSeconds: nil); XCTFail("Expected decoding failure") }
        catch AniSkipError.decodingFailed { }
        let records = try await f.records()
        XCTAssertEqual(records.count, 5)
    }

    func testTransportTimeoutRetriesAndCancellationStopsOneAttempt() async throws {
        let f = try Fixture()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.05
        config.timeoutIntervalForResource = 0.05
        let timed = AniSkipClient(baseURL: f.base.appendingPathComponent("slow"), session: URLSession(configuration: config),
            retryPolicy: RetryPolicy(attempts: 3, base: 0, jitter: 0...0))
        do { _ = try await timed.skipTimes(malID: 42, episodeNumber: 1, episodeLengthSeconds: nil); XCTFail("Expected timeout") }
        catch AniSkipError.network(let error) { XCTAssertEqual(error.code, .timedOut) }
        let records = try await f.records()
        XCTAssertEqual(records.count, 3)
        let client = AniSkipClient(baseURL: f.base.appendingPathComponent("slow"), retryPolicy: RetryPolicy(attempts: 3, base: 0, jitter: 0...0))
        let task = Task { try await client.skipTimes(malID: 42, episodeNumber: 1, episodeLengthSeconds: nil) }
        for _ in 0..<100 {
            if (try await f.records()).count >= 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let final = try await f.records()
        XCTAssertEqual(final.count, 4)
    }
    #endif
}
