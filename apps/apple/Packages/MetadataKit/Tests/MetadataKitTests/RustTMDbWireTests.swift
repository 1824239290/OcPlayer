import Foundation
import XCTest
@testable import MetadataKit

#if os(macOS)
final class RustTMDbWireTests: XCTestCase {
    private struct Credential: TMDbCredentialProviding { func apiKey() -> String? { "fixture" } }
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for TMDB wire fidelity")
        }
        return path
    }
    private final class Server {
        let process = Process()
        let base: URL
        init() throws {
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", try XCTUnwrap(Bundle.module.url(forResource: "tmdb_wire_server", withExtension: "py", subdirectory: "Fixtures")).path]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        deinit {
            // Process exit notifications are delivered asynchronously. Waiting here
            // can deadlock the cooperative executor running the XCTest method.
            if process.isRunning { process.terminate() }
        }
    }
    private func client(_ base: URL, library: String) -> TMDbClient {
        TMDbClient(session: .shared, credentials: Credential(),
                   limiter: TMDbRateLimiter(maxConcurrent: 4, minimumInterval: 0),
                   endpointProvider: { .init(apiBaseURL: base, imageBaseURL: base) },
                   rustCoreLibraryPath: library)
    }
    private func raw(_ base: URL, _ path: String) async throws -> Data {
        try await URLSession.shared.data(from: base.appendingPathComponent(path)).0
    }

    func testCompleteSharedWireModelsMatchNativeJSONObjectDecoding() async throws {
        let library = try library(), server = try Server()
        for scenario in ["exact", "numeric", "mixed", "prefix", "preferred", "overflow", "utf8bom",
                         "utf16le", "utf16be", "utf16lebom", "utf16bebom", "utf32le", "utf32be", "utf32bebom"] {
            let base = server.base.appendingPathComponent(scenario), shared = client(base, library: library)
            XCTAssertTrue(shared.usesCoreTransport)
            let entity = try await shared.movie(id: .max, language: "en-US")
            let nativeEntity = try TMDbDecoding.entity(await raw(base, "movie/\(Int.max)"), mediaType: .movie)
            XCTAssertEqual(entity, nativeEntity, "Entity \(scenario)")
            let season = try await shared.season(tvID: .max, seasonNumber: .max, language: "en-US")
            let nativeSeason = try TMDbDecoding.season(await raw(base, "tv/\(Int.max)/season/\(Int.max)"), seasonNumber: .max, fallbackNumber: .max)
            XCTAssertEqual(season, nativeSeason, "Season \(scenario)")
            let search = try await shared.search(query: "作品", mediaType: .movie, year: .max, language: "en-US")
            let nativeSearch = try TMDbDecoding.searchResults(await raw(base, "search/movie"), mediaType: .movie)
            XCTAssertEqual(search, nativeSearch, "Search \(scenario)")
        }
    }

    func testMalformedEncodingAndObjectErrorsNeverBecomeSuccessfulEmptyModels() async throws {
        let library = try library(), server = try Server()
        for scenario in ["invalid", "array", "utf32lebom"] {
            let base = server.base.appendingPathComponent(scenario), shared = client(base, library: library)
            let data = try await raw(base, "movie/1")
            XCTAssertThrowsError(try TMDbDecoding.entity(data, mediaType: .movie))
            do { _ = try await shared.movie(id: 1, language: "en-US"); XCTFail("Expected decoding error \(scenario)") }
            catch TMDbError.decoding {} catch { XCTFail("Wrong error \(error)") }
        }
    }

    func testSignedRequestRangesAndEpisodeSearchYearSuppression() async throws {
        let library = try library(), server = try Server()
        let shared = client(server.base.appendingPathComponent("exact"), library: library)
        _ = try await shared.movie(id: -1, language: "en-US")
        _ = try await shared.season(tvID: .min, seasonNumber: -3, language: "en-US")
        _ = try await shared.search(query: "作品", mediaType: .tv, year: .min, language: "en-US")
        _ = try await shared.search(query: "作品", mediaType: .episode, year: .max, language: "en-US")
        let (data, _) = try await URLSession.shared.data(from: server.base.appendingPathComponent("stats"))
        struct Record: Decodable { let path: String; let query: [String: [String]] }
        let records = try JSONDecoder().decode([Record].self, from: data)
        XCTAssertEqual(records.map(\.path), ["/exact/movie/-1", "/exact/tv/\(Int.min)/season/-3", "/exact/search/tv", "/exact/search/tv"])
        XCTAssertEqual(records[2].query["first_air_date_year"], [String(Int.min)])
        XCTAssertNil(records[3].query["first_air_date_year"])
    }
}
#endif
