import CoreModel
import Foundation
import OcPlayerCore
import XCTest
@testable import JellyfinKit

@MainActor
final class PlaybackPreparationHTTPTests: XCTestCase {
    func testJellyfinCompletePreparationOverRealHTTP() async throws { try await check(kind: .jellyfin) }
    func testEmbyCompletePreparationOverRealHTTP() async throws { try await check(kind: .emby) }
    func testJellyfinEpisodeEndpointSortingAndContinuationWindow() async throws { try await check(kind: .jellyfin, ordering: true) }
    func testEmbyEpisodeEndpointSortingAndContinuationWindow() async throws { try await check(kind: .emby, ordering: true) }
    private func check(kind: ServerKind, ordering: Bool = false) async throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", try XCTUnwrap(Bundle.module.url(forResource: "playback_preparation_server", withExtension: "py", subdirectory: "Fixtures")).path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/emby"))
        let suite = "PreparationHTTP-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
        let profile = ServerProfile(id: "fixture:u1", serverName: "fixture", baseURL: base, userID: "u1", kind: kind, serverID: "fixture")
        store.activate(profile, token: "fixture-token")
        let native: any MediaServer
        if kind == .jellyfin { native = try XCTUnwrap(JellyfinServer.resume(profile: profile, from: store)) }
        else { native = try XCTUnwrap(EmbyServer.resume(profile: profile, from: store)) }
        let server = RustCoreMediaServer(wrapping: native) ?? native
        if ordering {
            let all = try await server.episodes(seriesID: "order", seasonID: "season-one")
            XCTAssertEqual(all.map(\.id), ["special", "first", "second", "maximum", "unknown"])
            let window = try await server.episodes(seriesID: "order", startingAt: "current", limit: 2)
            XCTAssertEqual(window.map(\.id), ["current", "interstitial"])
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
            struct Query: Decodable { let path: String; let query: [String: [String]] }
            let queries = try JSONDecoder().decode([Query].self, from: data).filter { $0.path.hasSuffix("/Shows/order/Episodes") }
            XCTAssertEqual(queries.count, 2)
            XCTAssertEqual(queries.first?.query["seasonId"], ["season-one"])
            XCTAssertNil(queries.first?.query["limit"])
            XCTAssertEqual(queries.last?.query["startItemId"], ["current"])
            XCTAssertEqual(queries.last?.query["limit"], ["2"])
            XCTAssertTrue(queries.allSatisfy { $0.query["enableUserData"] == ["true"] && ($0.query["enableImageTypes"] ?? []).flatMap { $0.split(separator: ",").map(String.init) } == ["Primary", "Thumb", "Logo"] && $0.query["parentId"] == nil }, "Episode queries: \(queries.map(\.query))")
            return
        }
        var result: PreparedPlayback?
        let outcome = try await PlaybackPreparationWorkflow.prepare(item: .init(id: "series", name: "剧集入口", kind: .series), resumeSeconds: 99,
            server: server, home: { ([], []) }, onResolved: { _ in }, onFallback: { _, error in XCTFail("Unexpected fallback: \(error)") }, onReady: { result = $0 })
        if case .presented = outcome {} else {
            let (diagnostic, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
            let paths = (try JSONSerialization.jsonObject(with: diagnostic) as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            XCTFail("Preparation did not present: \(outcome); paths=\(paths)")
        }
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(prepared.item.id, "episode"); XCTAssertEqual(prepared.item.overview, "原始完整简介")
        XCTAssertEqual(prepared.title, "完整剧名 S1E2"); XCTAssertEqual(prepared.resumeSeconds, 1.25)
        XCTAssertEqual(prepared.context.mediaSourceID, "direct"); XCTAssertEqual(prepared.context.playSessionID, "native-session")
        XCTAssertEqual(prepared.context.mediaSourceSize, .max); XCTAssertEqual(prepared.context.mediaSourcePath, "/原盘/片.mkv")
        XCTAssertEqual(prepared.context.durationSeconds, 7200.25); XCTAssertEqual(prepared.context.videoRangeType, "HDR10")
        XCTAssertEqual(prepared.alternates.map(\.id), ["stream"]); XCTAssertEqual(prepared.alternates.first?.context.mediaSourceID, "stream")
        let components = try XCTUnwrap(URLComponents(string: prepared.uri))
        let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(components.path, "/emby/Videos/episode/stream"); XCTAssertEqual(query["mediasourceid"], "direct"); XCTAssertEqual(query["playsessionid"], "native-session")
        XCTAssertNil(query["api_key"])
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
        struct Record: Decodable { let method: String; let path: String; let authorization: String? }
        let records = try JSONDecoder().decode([Record].self, from: data)
        let metadata = records.filter { $0.path.hasSuffix("/Episodes") || $0.path.hasSuffix("/PlaybackInfo") }
        XCTAssertEqual(metadata.map(\.method), ["GET", "POST"])
        XCTAssertTrue(metadata.allSatisfy { $0.authorization?.contains("fixture-token") == true })
    }
}
