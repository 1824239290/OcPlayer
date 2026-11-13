import Foundation
import OcPlayerCore
import XCTest
@testable import DanmakuKit

final class IntroLearningFlowTests: XCTestCase {
    private struct Pair: Sendable {
        let directory: URL
        let cache: DanmakuCache
        let service: DanmakuService
        let store: IntroLearningStore
    }
    private func pair(core: Bool) throws -> Pair {
        if core && RustDanmakuPolicy.active == nil { throw XCTSkip("Enable Core for learning flow checks") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-learning-flow-\(UUID().uuidString)")
        let cache = DanmakuCache(directory: directory, useCore: core)
        let service = DanmakuService(cache: cache)
        let store = IntroLearningStore(directory: directory, useCore: core, sharedWith: service)
        if core { XCTAssertNotNil(service.sharedCore) }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Pair(directory: directory, cache: cache, service: service, store: store)
    }
    private func seek(_ pair: Pair, _ match: DanmakuEpisodeMatch, to: Double, from: Double = 0,
                      at: Double = 100) async throws -> IntroLearningOutcome {
        try await pair.store.applySeek(match: match, from: from, to: to, service: pair.service,
                                      at: Date(timeIntervalSinceReferenceDate: at))
    }
    private func events(_ pair: Pair, anime: Int64) throws -> [IntroSeekEvent] {
        let response = try XCTUnwrap(pair.service.sharedCore).call("introLearning.events", arguments: ["animeID": anime])
        XCTAssertTrue(response.ok)
        struct Payload: Decodable { let payloadJSON: String }
        return try JSONDecoder().decode([IntroSeekEvent].self,
            from: Data(response.data.decode(Payload.self).payloadJSON.utf8))
    }
    func testConfirmationRetainsIntervalAndOnlyUpdatesCurrentEpisode() async throws {
        let shared = try pair(core: true); let native = try pair(core: false)
        let current = DanmakuEpisodeMatch(episodeID: Int64.max, animeID: Int64.max)
        let sibling = DanmakuEpisodeMatch(episodeID: Int64.max - 1, animeID: Int64.max)
        let hint = DanmakuIntroHint(startSeconds: 12, endSeconds: 130, evidenceCount: 3)
        var outcomes: [IntroLearningOutcome] = []
        for p in [shared, native] {
            await p.cache.setEpisodeMatch(current, for: "current")
            await p.cache.setEpisodeMatch(sibling, for: "sibling")
            await p.service.persistIntroHint(hint, for: current.episodeID)
            await p.service.persistIntroHint(hint, for: sibling.episodeID)
            let result = try await seek(p, current, to: 140)
            outcomes.append(result)
            XCTAssertEqual(result.kind, .confirmed)
            XCTAssertEqual(result.hint?.startSeconds, 12)
            XCTAssertEqual(result.hint?.endSeconds, 130)
            XCTAssertEqual(result.hint?.evidenceCount, 4)
            XCTAssertFalse(result.applyToCurrent)
            let cached = await p.service.cachedIntroHint(for: current.episodeID)
            let unchanged = await p.service.cachedIntroHint(for: sibling.episodeID)
            let promoted = await p.store.promotedHint(forAnime: Int64.max)
            XCTAssertEqual(cached, result.hint)
            XCTAssertEqual(promoted, result.hint)
            XCTAssertEqual(unchanged, hint)
        }
        XCTAssertEqual(outcomes[0], outcomes[1])
        XCTAssertEqual(try events(shared, anime: Int64.max), [])
    }
    func testConsensusPropagatesOnlyEligibleSourcesAndHonorsExplicitAnimeIdentity() async throws {
        let shared = try pair(core: true); let native = try pair(core: false)
        let sources: [DanmakuIntroHintSource] = [.danmaku, .aniskip, .animeSkip, .theIntroDB, .learned]
        var outcomes: [[IntroLearningOutcome]] = []
        for p in [shared, native] {
            for i in 0..<7 {
                let match = DanmakuEpisodeMatch(episodeID: 50_001 + Int64(i))
                await p.cache.setEpisodeMatch(match, for: "ep-\(i)")
                if i > 0 && i <= 5 {
                    await p.service.persistIntroHint(DanmakuIntroHint(startSeconds: nil, endSeconds: 200, evidenceCount: 2,
                        source: sources[i - 1]), for: match.episodeID)
                }
            }
            await p.cache.setEpisodeMatch(DanmakuEpisodeMatch(episodeID: 50_002), for: "duplicate")
            await p.cache.setEpisodeMatch(DanmakuEpisodeMatch(episodeID: 90_001, animeID: 5), for: "explicit")
            await p.cache.setEpisodeMatch(DanmakuEpisodeMatch(episodeID: 50_008, animeID: 8), for: "other")
            let first = try await seek(p, DanmakuEpisodeMatch(episodeID: 50_001), to: 120)
            // The current AniSkip episode is protected, but native still offers
            // this consensus to the playback source-ranking boundary.
            let second = try await seek(p, DanmakuEpisodeMatch(episodeID: 50_003), to: 130)
            outcomes.append([first, second])
            XCTAssertEqual(first.kind, .recorded)
            XCTAssertEqual(second.kind, .promoted)
            XCTAssertEqual(second.hint?.endSeconds, 125)
            XCTAssertEqual(second.updatedEpisodeIDs, [50_001, 50_002, 50_007, 90_001])
            XCTAssertTrue(second.applyToCurrent)
            for i in 2...5 {
                let protected = await p.service.cachedIntroHint(for: 50_001 + Int64(i))
                XCTAssertEqual(protected?.source, sources[i - 1])
                XCTAssertEqual(protected?.endSeconds, 200)
            }
            let other = await p.service.cachedIntroHint(for: 50_008)
            XCTAssertNil(other)
            let third = try await seek(p, DanmakuEpisodeMatch(episodeID: 50_009), to: 138)
            XCTAssertEqual(third.kind, .recorded)
            let promoted = await p.store.promotedHint(forAnime: 5)
            XCTAssertEqual(promoted?.endSeconds, 125)
        }
        XCTAssertEqual(outcomes[0], outcomes[1])
    }
    func testSameEpisodeNeverPromotesAndKeepsNewestTwoHundredExactEvents() async throws {
        let shared = try pair(core: true); let native = try pair(core: false)
        let match = DanmakuEpisodeMatch(episodeID: 9_007_199_254_740_993, animeID: Int64.max)
        for p in [shared, native] {
            for i in 0..<205 {
                let result = try await seek(p, match, to: 140 + Double(i % 2), at: Double(i))
                XCTAssertEqual(result.kind, .recorded)
            }
            let promoted = await p.store.promotedHint(forAnime: Int64.max)
            XCTAssertNil(promoted)
        }
        let recorded = try events(shared, anime: Int64.max)
        XCTAssertEqual(recorded.count, 200)
        XCTAssertEqual(recorded.first, IntroSeekEvent(episodeID: match.episodeID, position: 141,
                                                   at: Date(timeIntervalSinceReferenceDate: 5)))
        let lhs = try Data(contentsOf: shared.directory.appendingPathComponent("learned-intros.json"))
        let rhs = try Data(contentsOf: native.directory.appendingPathComponent("learned-intros.json"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: lhs) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: rhs) as? NSDictionary)
    }
    func testEligibilityNonFiniteInputsAndMissingAnimeMatchNative() async throws {
        let shared = try pair(core: true); let native = try pair(core: false)
        let match = DanmakuEpisodeMatch(episodeID: 50_001)
        for (from, to) in [(0.0, 29.99), (0, 360.01), (95, 100), (100, 90),
                           (.nan, 130), (.infinity, 130), (0, .nan), (0, .infinity),
                           (-.infinity, 30), (0, 360), (94.999, 100)] {
            let lhs = try await seek(shared, match, to: to, from: from)
            let rhs = try await seek(native, match, to: to, from: from)
            XCTAssertEqual(lhs, rhs)
        }
        let noAnime = try await seek(shared, DanmakuEpisodeMatch(episodeID: 9999), to: 130)
        XCTAssertEqual(noAnime.kind, .ignored)
        XCTAssertNil(noAnime.animeID)
    }
    func testConcurrentConfirmationUsesTheServicesLiveCacheOnlyOnce() async throws {
        let shared = try pair(core: true)
        let match = DanmakuEpisodeMatch(episodeID: 50_001)
        await shared.service.persistIntroHint(DanmakuIntroHint(startSeconds: nil, endSeconds: 130, evidenceCount: 2), for: match.episodeID)
        let outcomes = try await withThrowingTaskGroup(of: IntroLearningOutcome.self) { group in
            for i in 0..<80 {
                group.addTask {
                    try await shared.store.applySeek(match: match, from: 0, to: 130, service: shared.service,
                        at: Date(timeIntervalSinceReferenceDate: Double(i)))
                }
            }
            var result: [IntroLearningOutcome] = []
            for try await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(outcomes.filter { $0.kind == .confirmed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0.kind == .recorded }.count, 79)
        XCTAssertEqual(try events(shared, anime: 5).count, 79)
        let cached = await shared.service.cachedIntroHint(for: match.episodeID)
        XCTAssertEqual(cached?.evidenceCount, 3)
        XCTAssertEqual(cached?.source, .learned)
    }
    private actor Gate {
        var opened = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
        func open() { opened = true; waiter?.resume(); waiter = nil }
    }
    func testCancellationBeforeEntryDoesNotRecordOrPromote() async throws {
        let shared = try pair(core: true); let gate = Gate()
        let task = Task {
            await gate.wait()
            return try await shared.store.applySeek(match: DanmakuEpisodeMatch(episodeID: 50_001),
                from: 0, to: 130, service: shared.service)
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try events(shared, anime: 5), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.directory.appendingPathComponent("learned-intros.json").path))
    }
}
