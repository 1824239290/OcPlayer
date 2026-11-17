import Foundation
import OcPlayerCore
import XCTest
@testable import DanmakuKit

final class RustDanmakuFlowTests: XCTestCase {
    private func policy() throws -> RustDanmakuPolicy {
        guard let value = RustDanmakuPolicy.active else { throw XCTSkip("Enable Core for load-flow comparisons") }
        return value
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testProductionRenderMatchesNativeNumericUnicodeAndStableOrdering() throws {
        let policy = try policy()
        let times = ["0", "-0", "+1", "3.5", "1e2", "0x1.8p1", " 1", "1 ", "NaN", "Infinity", "-1", "1e999", "1_0", ""]
        let modes = ["1", "4", "5", "2", "01", "+1", " 1", "-0", ""]
        let colors = ["0", "16777215", "16777216", "-1", "+1", "01", " 1", "9223372036854775807", ""]
        let texts = ["Text", "\u{200b}", "\u{85}", " \u{301}", "\u{feff}", " ", "作品名稱", "👨‍👩‍👧", ""]
        let match = DanmakuEpisodeMatch(episodeID: Int64.max)
        for index in 0..<1200 {
            let comments = (0..<7).map { offset in
                let i = index + offset
                return DanmakuComment(cid: nil, p: "\(times[i % times.count]),\(modes[(i / 3) % modes.count]),\(colors[(i / 7) % colors.count]),\u{301}ignored",
                    m: texts[(i / 5) % texts.count])
            }
            for format in [DanmakuPayloadFormat.overlay, .kernelTrack, .both] {
                let shared = try policy.render(comments, format: format, detectingIntro: false, match: match)
                XCTAssertEqual(shared.commentCount, comments.count)
                XCTAssertNil(shared.detectedIntroHint)
                XCTAssertEqual(shared.entries, format == .kernelTrack ? nil : DanmakuJSONConverter.entries(from: comments), "entries \(index)")
                let native = format == .overlay ? nil : DanmakuJSONConverter.erikaJSON(from: comments)
                XCTAssertEqual(shared.json == nil, native == nil, "json presence \(index)")
                if let lhs = shared.json, let rhs = native {
                    XCTAssertEqual(DanmakuJSONParser.parse(lhs), DanmakuJSONParser.parse(rhs), "json \(index)")
                }
            }
        }
        let ordered = [DanmakuComment(cid: nil, p: "3,1,1", m: "third"), DanmakuComment(cid: nil, p: "1,4,2", m: "first"),
            DanmakuComment(cid: nil, p: "1,5,3", m: "equal")]
        let result = try policy.render(ordered, format: .both, detectingIntro: false, match: match)
        XCTAssertEqual(result.entries?.map(\.text), ["first", "equal", "third"])
        XCTAssertEqual(DanmakuJSONParser.parse(result.json!)?.map(\.text), ["third", "first", "equal"])
    }

    @MainActor
    private final class Host: DanmakuPlaybackHosting {
        var injected = 0
        var cleared = 0
        var names: [String] = []
        var entries: [DanmakuJSONParser.Entry] = []
        var onReady: (() async -> Void)?
        var danmakuPayloadFormat: DanmakuPayloadFormat { .overlay }
        func waitUntilReady(uuid: UUID, timeout: Duration) async -> Bool { await onReady?(); return true }
        func replaceDanmaku(uuid: UUID, entries: [DanmakuJSONParser.Entry], json: String?, name: String, offset: Duration) throws -> Bool {
            injected += 1; self.entries = entries; names.append(name); return true
        }
        func clearDanmaku(uuid: UUID) throws -> Bool { cleared += 1; return true }
    }
    @MainActor
    func testManualAndCachedAutomaticMatchNativeControlFlow() async throws {
        _ = try policy()
        let first = try directory(); let second = try directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let shared = DanmakuLoadOrchestrator(service: DanmakuService(cache: DanmakuCache(directory: first)))
        let native = DanmakuLoadOrchestrator(service: DanmakuService(cache: DanmakuCache(directory: second)))
        let comment = DanmakuComment(cid: nil, p: "1,1,16777215", m: "hello")
        let match = DanmakuEpisodeMatch(episodeID: 1, shiftSeconds: 4, animeTitle: " Show ", episodeTitle: " 01 ")
        let configuration = DandanplayConfiguration(baseURL: URL(string: "https://unused.local")!, apiKey: "fixture", userAgent: "fixture")
        let host = Host(); let originalHost = Host(); let uuid = UUID()
        for service in [shared.service, native.service] { await service.persistComments([comment], for: 1) }
        let outcome = await shared.runManual(match: match, uuid: uuid, cacheKey: "key", configuration: configuration, playback: host, revision: 1)
        let original = await native.runManualNative(match: match, uuid: uuid, cacheKey: "key", configuration: configuration, playback: originalHost, revision: 1)
        XCTAssertEqual(outcome, original)
        XCTAssertEqual(host.names, originalHost.names)
        XCTAssertEqual(host.entries, originalHost.entries)
        let context = DanmakuMatchContext(uuid: uuid, cacheKey: "key", allowsCachedMatchReuse: true, fileName: "unused")
        let cached = await shared.runAutomatic(matchContext: context, configuration: configuration, playback: host, revision: 2)
        let originalCached = await native.runAutomaticNative(matchContext: context, configuration: configuration, playback: originalHost, revision: 2)
        XCTAssertEqual(cached, originalCached)
        XCTAssertEqual(host.injected, 2)
    }
    @MainActor
    func testRevisionChangeDuringReadyCannotInjectIntoSamePlaybackUUID() async throws {
        _ = try policy()
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = DanmakuService(cache: DanmakuCache(directory: dir))
        await service.persistComments([DanmakuComment(cid: nil, p: "1,1,1", m: "hello")], for: 1)
        let orchestrator = DanmakuLoadOrchestrator(service: service)
        let host = Host()
        host.onReady = { await service.claimMatchRevision(cacheKey: "key", revision: 2) }
        let result = await orchestrator.runManual(match: DanmakuEpisodeMatch(episodeID: 1), uuid: UUID(), cacheKey: "key",
            configuration: DandanplayConfiguration(baseURL: URL(string: "https://unused.local")!, apiKey: "fixture", userAgent: "fixture"), playback: host, revision: 1)
        XCTAssertEqual(result, .failed(message: "播放已切换"))
        XCTAssertEqual(host.injected, 0)
    }
    private actor AliasGate: DanmakuTitleAliasProviding {
        var waiting = false
        var continuation: CheckedContinuation<[String], Never>?
        func aliases(for title: String) async -> [String] {
            waiting = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: []); continuation = nil }
    }
    @MainActor
    func testCancelAfterInjectionDoesNotResolveIDsOrPersistIntro() async throws {
        let policy = try policy()
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let service = DanmakuService(cache: DanmakuCache(directory: dir))
        await service.persistComments([DanmakuComment(cid: nil, p: "1,1,1", m: "hello")], for: 84190003)
        let aliases = AliasGate()
        let orchestrator = DanmakuLoadOrchestrator(service: service, titleAliases: aliases)
        let host = Host(); let uuid = UUID()
        let context = DanmakuMatchContext(uuid: uuid, cacheKey: "key", allowsCachedMatchReuse: false, fileName: "Show", episodeNumber: 3, malID: 42)
        let task = Task { await orchestrator.runManual(match: DanmakuEpisodeMatch(episodeID: 84190003, animeTitle: "Show"),
            uuid: uuid, cacheKey: "key", configuration: DandanplayConfiguration(baseURL: URL(string: "https://unused.local")!, apiKey: "fixture", userAgent: "fixture"),
            playback: host, revision: 1, matchContext: context) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !aliases.waiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await aliases.waiting
        XCTAssertTrue(waiting)
        XCTAssertEqual(host.injected, 1)
        task.cancel(); await aliases.release()
        let cancelledResult = await task.value
        XCTAssertEqual(cancelledResult, .failed(message: "已取消"))
        let hint = await service.cachedIntroHint(for: 84190003)
        XCTAssertNil(hint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("aniskip-ids.json").path))
        let response = try policy.core.call("danmakuFlow.stats")
        struct Payload: Decodable { let payloadJSON: String }
        let stats = try JSONSerialization.jsonObject(with: Data(response.data.decode(Payload.self).payloadJSON.utf8)) as! [String: Any]
        XCTAssertEqual((stats["active"] as! NSNumber).intValue, 0)
    }
}
