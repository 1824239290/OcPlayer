import XCTest
@testable import DanmakuKit

final class DanmakuCacheTests: XCTestCase {

    private func makeCache(ttl: TimeInterval = 3600) async -> (DanmakuCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = DanmakuCache(directory: dir, commentsTTL: ttl)
        return (cache, dir)
    }

    func testEpisodeIDMappingPersists() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let absent = await cache.episodeID(for: "item-1")
        XCTAssertNil(absent)
        await cache.setEpisodeID(42, for: "item-1")
        let stored = await cache.episodeID(for: "item-1")
        XCTAssertEqual(stored, 42)

        // 新实例读回同一目录，验证落盘。
        let reopened = DanmakuCache(directory: dir, commentsTTL: 3600)
        let reopenedValue = await reopened.episodeID(for: "item-1")
        XCTAssertEqual(reopenedValue, 42)
    }

    func testEpisodeMatchPersistsShiftAndTitles() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let match = DanmakuEpisodeMatch(
            episodeID: 42,
            shiftSeconds: -2,
            animeTitle: "作品",
            episodeTitle: "第 1 话"
        )
        await cache.setEpisodeMatch(match, for: "item-1")

        let reopened = DanmakuCache(directory: dir)
        let stored = await reopened.episodeMatch(for: "item-1")
        XCTAssertEqual(stored, match)
    }

    func testRemovingEpisodeMatchPreservesOtherMappings() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setEpisodeID(42, for: "item-1")
        await cache.setEpisodeID(99, for: "item-2")
        await cache.removeEpisodeMatch(for: "item-1")

        let reopened = DanmakuCache(directory: dir)
        let removed = await reopened.episodeID(for: "item-1")
        let preserved = await reopened.episodeID(for: "item-2")
        XCTAssertNil(removed)
        XCTAssertEqual(preserved, 99)
    }

    func testOlderRevisionCannotOverwriteNewerMatch() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setEpisodeMatch(
            DanmakuEpisodeMatch(episodeID: 2),
            for: "item",
            revision: 2
        )
        await cache.setEpisodeMatch(
            DanmakuEpisodeMatch(episodeID: 1),
            for: "item",
            revision: 1
        )

        let stored = await cache.episodeMatch(for: "item")
        XCTAssertEqual(stored?.episodeID, 2)
    }

    func testNewerRemovalRejectsLateOlderWrite() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.removeEpisodeMatch(for: "item", revision: 3)
        await cache.setEpisodeMatch(
            DanmakuEpisodeMatch(episodeID: 2),
            for: "item",
            revision: 2
        )

        let stored = await cache.episodeMatch(for: "item")
        XCTAssertNil(stored)
    }

    func testClaimedRevisionRejectsLateOlderMutation() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setEpisodeMatch(DanmakuEpisodeMatch(episodeID: 1), for: "item")
        await cache.claimEpisodeMatchRevision(for: "item", revision: 3)
        await cache.setEpisodeMatch(
            DanmakuEpisodeMatch(episodeID: 2),
            for: "item",
            revision: 2
        )
        await cache.removeEpisodeMatch(for: "item", revision: 2)

        let stored = await cache.episodeMatch(for: "item")
        XCTAssertEqual(stored?.episodeID, 1)
    }

    func testLegacyEpisodeIDMappingMigrates() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"legacy":99}"#.utf8).write(
            to: dir.appendingPathComponent("mapping.json")
        )

        let match = await cache.episodeMatch(for: "legacy")
        XCTAssertEqual(match, DanmakuEpisodeMatch(episodeID: 99))
    }

    func testCommentsStoredAndRetrieved() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let comments = [
            DanmakuComment(cid: 1, p: "0.5,1,16777215,u", m: "first"),
            DanmakuComment(cid: 2, p: "1.0,5,16711680,u", m: "second")
        ]
        let absent = await cache.comments(for: 100)
        XCTAssertNil(absent)
        await cache.setComments(comments, for: 100)
        let got = await cache.comments(for: 100)
        let unwrapped = try XCTUnwrap(got)
        XCTAssertEqual(unwrapped.count, 2)
        XCTAssertEqual(unwrapped.first?.m, "first")
    }

    func testCommentsTTLExpiry() async throws {
        // TTL 用极短时间验证过期路径。
        let (cache, dir) = await makeCache(ttl: 0.001)
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "x")], for: 7)
        try await Task.sleep(for: .milliseconds(50))
        let expired = await cache.comments(for: 7)
        XCTAssertNil(expired)
    }

    func testCorruptedMappingDoesNotGetOverwritten() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mappingURL = dir.appendingPathComponent("mapping.json")
        try Data("not-json".utf8).write(to: mappingURL)

        await cache.setEpisodeID(99, for: "new-item")
        let bytes = try Data(contentsOf: mappingURL)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "not-json")
        let value = await cache.episodeID(for: "new-item")
        XCTAssertNil(value)
    }
}
