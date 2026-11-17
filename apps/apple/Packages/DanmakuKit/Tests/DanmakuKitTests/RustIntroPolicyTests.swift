import Foundation
import XCTest
@testable import DanmakuKit

final class RustIntroPolicyTests: XCTestCase {
    private func requireCore() throws -> RustDanmakuPolicy {
        guard let core = RustDanmakuPolicy.active else { throw XCTSkip("Enable Core for intro differential checks") }
        return core
    }
    private struct Fields: Decodable { let time: Double?; let uid: String? }
    private struct RNG {
        var state: UInt64 = 0xDADDAB00
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 16) % UInt64(bound))
        }
    }

    func testTimestampAndCommentFieldsMatchNativeUnicodeAndNumberRules() throws {
        let rust = try requireCore()
        let numbers = ["0", "1", "12", "59", "60", "123", "１２", "١٢", "一", "Ⅳ", "²", "1\u{301}", "1️⃣"]
        for a in numbers {
            for b in numbers {
                for separator in [":", ".", "：", "．"] {
                    let text = "前缀" + a + separator + b
                    let actual: Double? = rust.intro("timestamp", arguments: ["text": text])
                    XCTAssertEqual(actual, DanmakuIntroDetector.parseTimestamp(text), text)
                }
            }
        }
        for text in ["1:23:45", "1:23:4", "123:45 1:23", "1:\u{301}23", "1:2\u{301}3", "a\u{200D}1:23", "1234", "0:30\u{200D}"] {
            let actual: Double? = rust.intro("timestamp", arguments: ["text": text])
            XCTAssertEqual(actual, DanmakuIntroDetector.parseTimestamp(text), text)
        }
        for time in ["", "-1", "-0", "0.5", "1e2", "0x1p2", "0x10", "0X1.8P+1", "0x1.000000000000081p0", "0x1p-99999", "NaN", "inf", " 1", "1 ", "１", "1\u{301}"] {
            for suffix in [",1,2,uid", ",,1,,2,, uid ", ",1,2,\u{A0}uid\u{200B}", ",\u{301}1,2,3,4", ",1,2,\nuid\n", ",1,2,4\u{301}"] {
                let p = time + suffix
                let actual: Fields = rust.intro("commentFields", arguments: ["p": p])
                let native = DanmakuIntroDetector.parseTimeAndUID(p)
                XCTAssertEqual(actual.time, native.0, p)
                XCTAssertEqual(actual.uid, native.1, p)
            }
        }
    }

    func testDetectorMatchesIndependentNativeAcrossSignalsAndNoise() throws {
        let rust = try requireCore()
        let words = ["跳伞2:10", "空降02：12", "空降成功", "感谢指挥部", "正片开始", "空投2.10", "空降2:15跳伞2:12", "跳伞\u{301}2:11", "空降3:11", "OP好听", "跳至一:30", "空降1:23:45"]
        var rng = RNG()
        for _ in 0..<700 {
            let comments = (0..<rng.next(35)).map { _ in
                DanmakuComment(cid: .max, p: "\(Double(rng.next(3800))/10),1,255,u\(rng.next(4))", m: words[rng.next(words.count)])
            }
            let actual: DanmakuIntroHint? = rust.introPayload("detect", value: comments)
            XCTAssertEqual(actual, DanmakuIntroDetector.detectNative(in: comments))
            XCTAssertEqual(DanmakuIntroDetector.detect(in: comments), actual)
        }
    }

    func testLearningConsensusMatchesNativeDistinctEpisodesMedianAndTies() throws {
        _ = try requireCore()
        var rng = RNG()
        for _ in 0..<600 {
            let events = (0..<rng.next(30)).map { _ in
                IntroSeekEvent(episodeID: Int64(rng.next(5)) + 9_007_199_254_740_993,
                    position: Double(rng.next(90)) * 5 + 0.5,
                    at: Date(timeIntervalSinceReferenceDate: 100))
            }
            for minimum in [-1, 1, 2, 3, 6] {
                let actual = IntroLearningStore.crossEpisodeConsensus(of: events, minimumEpisodes: minimum)
                let native = IntroLearningStore.crossEpisodeConsensusNative(of: events, minimumEpisodes: minimum)
                XCTAssertEqual(actual?.end, native?.end)
                XCTAssertEqual(actual?.episodeCount, native?.episodeCount)
            }
        }
    }

    func testDetectorRepresentativeLargeCommentBatch() throws {
        let rust = try requireCore()
        let comments = (0..<10_000).map { index in
            DanmakuComment(cid: Int64(index), p: "\(Double(index % 1500) / 10),1,255,u\(index % 4)",
                m: index % 100 == 0 ? "空降2:1\(index % 3)" : "这集的作画和配乐都很好，期待接下来的剧情。")
        }
        let clock = ContinuousClock()
        let nativeStart = clock.now
        let native = DanmakuIntroDetector.detectNative(in: comments)
        let nativeElapsed = nativeStart.duration(to: clock.now)
        let coreStart = clock.now
        let core: DanmakuIntroHint? = rust.introPayload("detect", value: comments)
        let coreElapsed = coreStart.duration(to: clock.now)
        XCTAssertEqual(core, native)
        print("Intro 10000-comment batch: native=\(nativeElapsed) Core-with-JSON-ABI=\(coreElapsed)")
    }

    @MainActor
    func testSourceSelectionAndSiblingAggregationMatchNative() throws {
        _ = try requireCore()
        var rng = RNG()
        let sources: [DanmakuIntroHintSource] = [.danmaku, .theIntroDB, .learned, .animeSkip, .aniskip]
        for _ in 0..<600 {
            let intervals = (0..<rng.next(15)).map { _ in
                DanmakuLoadOrchestrator.SkipSourceInterval(source: sources[rng.next(sources.count)],
                    start: rng.next(2) == 0 ? nil : Double(rng.next(30)), end: Double(rng.next(30)) * 5)
            }
            let actual = DanmakuLoadOrchestrator.selectBestInterval(intervals)
            let native = DanmakuLoadOrchestrator.selectBestIntervalNative(intervals)
            XCTAssertEqual(actual?.start, native?.start)
            XCTAssertEqual(actual?.end, native?.end)
            XCTAssertEqual(actual?.source, native?.source)
            XCTAssertEqual(actual?.votes, native?.votes)
            let hints = intervals.map { DanmakuIntroHint(startSeconds: $0.start, endSeconds: $0.end, evidenceCount: 2) }
            XCTAssertEqual(DanmakuLoadOrchestrator.siblingHint(hints), DanmakuLoadOrchestrator.siblingHintNative(hints))
        }
    }

    func testSeekBoundaryAndConfirmedSourceRules() throws {
        _ = try requireCore()
        for to in [29.9, 30, 90, 360, 360.1] {
            for from in [0, to - 5, to - 5.001, to + 5] {
                XCTAssertEqual(IntroLearningPolicy.eligibleSeek(from: from, to: to), (30...360).contains(to) && from < to - 5)
            }
        }
        XCTAssertFalse(IntroLearningPolicy.eligibleSeek(from: .nan, to: 100))
        XCTAssertFalse(IntroLearningPolicy.eligibleSeek(from: 0, to: .infinity))
        for source in [DanmakuIntroHintSource.danmaku, .learned, .aniskip, .animeSkip, .theIntroDB] {
            let hint = DanmakuIntroHint(startSeconds: 10, endSeconds: 100, evidenceCount: 3, source: source)
            for to in [89.9, 90, 100, 110, 110.1] {
                let actual = IntroLearningPolicy.confirmedHint(forLanding: to, current: hint)
                let expected: DanmakuIntroHint? = source == .danmaku && abs(to - 100) <= 10
                    ? DanmakuIntroHint(startSeconds: 10, endSeconds: 100, evidenceCount: 4, source: .learned) : nil
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testLearningFilesBidirectionalPersistenceDatesIDsAndEventBounds() async throws {
        _ = try requireCore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-learn-interop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let animeID: Int64 = .max
        let native = IntroLearningStore(directory: directory, useCore: false)
        await native.record(animeID: animeID, event: IntroSeekEvent(episodeID: .max, position: 140, at: Date(timeIntervalSinceReferenceDate: 100)))
        let core = IntroLearningStore(directory: directory, useCore: true)
        let active = await core.usesCoreLearning
        XCTAssertTrue(active)
        await core.record(animeID: animeID, event: IntroSeekEvent(episodeID: .max - 1, position: 141, at: Date(timeIntervalSinceReferenceDate: 101)))
        let consensus = await core.consensusHint(forAnime: animeID)
        XCTAssertEqual(consensus?.endSeconds, 140.5)
        let hint = try XCTUnwrap(consensus)
        await core.promote(animeID: animeID, hint: hint)
        let reopened = IntroLearningStore(directory: directory, useCore: false)
        let saved = await reopened.promotedHint(forAnime: animeID)
        XCTAssertEqual(saved, hint)
        for index in 0..<205 {
            await core.record(animeID: animeID, event: IntroSeekEvent(episodeID: Int64(index), position: 142, at: Date(timeIntervalSinceReferenceDate: Double(index))))
        }
        struct Entry: Decodable { let events: [IntroSeekEvent]; let promoted: DanmakuIntroHint? }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("learned-intros.json"))
        let entries = try JSONDecoder().decode([String: Entry].self, from: bytes)
        XCTAssertEqual(entries[String(animeID)]?.events.count, 200)
        XCTAssertEqual(entries[String(animeID)]?.events.first?.episodeID, 5)
        XCTAssertEqual(entries[String(animeID)]?.events.first?.at, Date(timeIntervalSinceReferenceDate: 5))
        XCTAssertEqual(entries[String(animeID)]?.promoted, hint)
    }
}
