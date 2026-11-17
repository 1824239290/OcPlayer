import Foundation
import XCTest
@testable import OcPlayerCore

@MainActor
final class OcpDanmakuLoaderTests: XCTestCase {
    private final class Server {
        let process = Process()
        let base: String
        init() throws {
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            guard let fixture = Bundle.module.url(forResource: "standalone_danmaku_server", withExtension: "py", subdirectory: "Fixtures") else {
                throw OcpCoreError(message: "Fixture resource is missing")
            }
            process.arguments = ["-u", fixture.path]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            var line = Data()
            while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 { break }
                line.append(byte)
            }
            guard let port = Int(String(decoding: line, as: UTF8.self)) else {
                process.terminate()
                throw OcpCoreError(message: "Fixture server failed to start")
            }
            base = "http://127.0.0.1:\(port)"
        }
        deinit { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    }
    private func client() throws -> OcpCoreClient {
        guard let core = try? OcpCoreClient() else { throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for standalone loading") }
        return core
    }
    private func gateway(_ server: Server, scenario: String = "first") -> [String: Any] {
        ["base_url": server.base + "/" + scenario, "api_key": "fixture", "user_agent": "OcPlayer/binding"]
    }
    private func request() -> [String: Any] { ["fileName": "Clean - 02.mkv", "fileHash": String(repeating: "a", count: 32)] }
    private func count(_ server: Server) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: server.base + "/stats")!)
        return (try JSONSerialization.jsonObject(with: data) as! [Any]).count
    }
    func testPublicLoaderSelectsOneCandidateAndPreservesExactIDsAndIntro() async throws {
        let core = try client(); let server = try Server()
        let result = try await OcpDanmakuLoader(core: core).load(gateway: gateway(server), matchRequest: request(), retryAttempts: 1)
        XCTAssertEqual(result.episodes.count, 1)
        XCTAssertEqual(result.episodes.first?.candidate.episodeID, Int64.max)
        XCTAssertEqual(result.match.matches.first?.episodeID, Int64.max)
        XCTAssertEqual(result.episodes.first?.candidate.animeID, 5)
        XCTAssertEqual(result.episodes.first?.candidate.shift, -5)
        XCTAssertEqual(result.episodes.first?.count, 3)
        XCTAssertEqual(result.episodes.first?.rawCommentCount, 6)
        XCTAssertEqual(result.episodes.first?.comments.map(\.time), [10, 11, 132])
        XCTAssertNotNil(result.episodes.first?.json)
        XCTAssertEqual(result.outcome?.kind, "loaded")
        XCTAssertEqual(result.outcome?.introHint?.endSeconds, 131)
        XCTAssertEqual(result.outcome?.introHint?.source, "danmaku")
        let requests = try await count(server)
        XCTAssertEqual(requests, 2)
    }
    func testPublicLoaderReusesNativeCacheAndManualSelectionForcesIntroResolution() async throws {
        let core = try client(); let server = try Server()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-loader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for method in ["danmakuCache.open", "introLearning.open"] {
            XCTAssertTrue(try core.call(method, arguments: ["directory": directory.path]).ok)
        }
        let loader = OcpDanmakuLoader(core: core)
        let initial = try await loader.load(gateway: gateway(server), matchRequest: request(), cacheKey: "media", revision: UInt64.max, retryAttempts: 1)
        let reused = try await loader.load(gateway: gateway(server), matchRequest: request(),
            configuration: ["context": ["allowsCachedMatchReuse": true]], cacheKey: "media", revision: UInt64.max, retryAttempts: 1)
        XCTAssertEqual(initial.episodes, reused.episodes)
        let before = try await count(server)
        XCTAssertEqual(before, 2)
        let manual = try await loader.load(gateway: gateway(server), matchRequest: [:],
            configuration: ["mode": "manual", "matchValue": ["episodeID": Int64.max, "animeID": 5, "shiftSeconds": 7]],
            cacheKey: "manual", retryAttempts: 1)
        XCTAssertEqual(manual.episodes.first?.candidate.shift, 7)
        XCTAssertEqual(manual.outcome?.introHint?.endSeconds, 131)
        let after = try await count(server)
        XCTAssertEqual(after, before)
    }
    func testPublicLoaderCancellationStopsLiveFetchAndClosesFlow() async throws {
        let core = try client(); let server = try Server(); let loader = OcpDanmakuLoader(core: core)
        let task = Task { try await loader.load(gateway: gateway(server, scenario: "slow"), matchRequest: request(), requestID: "loader-cancel", retryAttempts: 1) }
        let deadline = ContinuousClock.now + .seconds(3)
        while try await count(server) < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error.localizedDescription.contains("cancel"), "\(error)") }
        struct Payload: Decodable { let payloadJSON: String }
        struct Stats: Decodable { let active: Int }
        let response = try core.call("danmakuFlow.stats")
        let payload = try response.data.decode(Payload.self)
        XCTAssertEqual(try JSONDecoder().decode(Stats.self, from: Data(payload.payloadJSON.utf8)).active, 0)
    }
}
