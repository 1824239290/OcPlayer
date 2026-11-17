import Foundation
import XCTest
@testable import MetadataKit

#if os(macOS)
final class RustTMDbIntegrationTests: XCTestCase {
    private struct Credential: TMDbCredentialProviding {
        let key: String?
        func apiKey() -> String? { key }
    }
    private final class Endpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TMDbEndpoints
        init(_ url: URL) { value = .init(apiBaseURL: url, imageBaseURL: url) }
        func get() -> TMDbEndpoints { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ url: URL) { lock.lock(); defer { lock.unlock() }; value = .init(apiBaseURL: url, imageBaseURL: url) }
    }

    func testNativeMetadataFallbackEndpointAuthSeasonAndErrorParity() async throws {
        guard let library = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for Rust TMDB integration")
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "native_tmdb", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = pipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(string: "http://127.0.0.1:\(port)")!
        let endpoint = Endpoint(root.appendingPathComponent("mirror/3"))
        func client(_ key: String? = "fixture") -> TMDbClient {
            TMDbClient(session: .shared, credentials: Credential(key: key),
                       limiter: TMDbRateLimiter(maxConcurrent: 2, minimumInterval: 0),
                       endpointProvider: { endpoint.get() }, rustCoreLibraryPath: library)
        }
        let native = client()
        if ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1" {
            let automatic = TMDbClient(session: .shared, credentials: Credential(key: "fixture"),
                                       endpointProvider: { endpoint.get() })
            XCTAssertTrue(automatic.usesCoreTransport, "production session must load Core without explicit library injection")
        }
        let entity = try await native.movie(id: 1, language: "zh-CN")
        XCTAssertEqual(entity.title, "中文标题")
        XCTAssertEqual(entity.overview, "English overview")
        XCTAssertEqual(entity.posterPath, "/poster.jpg")
        XCTAssertEqual(entity.genres, ["Drama"])
        XCTAssertEqual(entity.cast.first?.profilePath, "/actor.jpg")
        XCTAssertEqual(entity.imdbID, "tt123")
        XCTAssertEqual(entity.collectionID, 10)
        XCTAssertEqual(entity.contentRating, "PG")
        let complete = try await native.movie(id: 2, language: "zh-CN")
        XCTAssertEqual(complete.title, "Complete")
        let partial = try await native.movie(id: 3, language: "zh-CN")
        XCTAssertEqual(partial.title, "主语言")
        XCTAssertNil(partial.overview)
        let season = try await native.season(tvID: 7, seasonNumber: 0, language: "zh-CN")
        XCTAssertEqual(season.seasonNumber, 0)
        XCTAssertEqual(season.episodes.count, 1)
        XCTAssertEqual(season.episodes.first?.runtime, 25)
        let search = try await native.search(query: "Anime & title", mediaType: .tv, year: 2023, language: "zh-CN")
        XCTAssertEqual(search.first?.year, 2023)
        XCTAssertEqual(search.count, 1)
        endpoint.set(root.appendingPathComponent("new/3"))
        let collection = try await client("eyJ.fixture").collection(id: 10, language: "zh-CN")
        XCTAssertEqual(collection.title, "Collection")
        let collections = try await native.search(query: "Collection", mediaType: .collection, year: 2023, language: "zh-CN")
        XCTAssertEqual(collections.first?.id, 10)
        for (id, expected) in [(401, TMDbError.unauthorized), (404, .notFound), (429, .rateLimited(retryAfter: nil)), (500, .http(status: 500))] {
            do { _ = try await native.movie(id: id, language: "en-US"); XCTFail("Expected error") }
            catch let error as TMDbError { XCTAssertEqual(error, expected) }
        }
        do { _ = try await client(nil).movie(id: 1, language: "en-US"); XCTFail("Expected unconfigured") }
        catch let error as TMDbError { XCTAssertEqual(error, .notConfigured) }
        let (data, _) = try await URLSession.shared.data(from: root.appendingPathComponent("counts"))
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertEqual(counts["/mirror/3/movie/1"], 2)
        XCTAssertEqual(counts["/mirror/3/movie/2"], 1, "complete primary must not load a fallback")
        XCTAssertEqual(counts["/mirror/3/tv/7/season/0"], 1, "whole season is one request")
        XCTAssertEqual(counts["/new/3/movie/401"], 1, "failure must not replay through Swift")
        XCTAssertEqual(counts["/new/3/movie/429"], 3)
        XCTAssertEqual(counts["/new/3/movie/500"], 1, "native TMDB HTTP errors are final; only rate limits and transport errors retry")
    }
}
#endif
