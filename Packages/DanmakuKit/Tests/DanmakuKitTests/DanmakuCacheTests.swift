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

    // MARK: 正文内存缓存（P1-15）

    /// 命中内存后即使把文件删掉也仍能返回 —— 证明第二次读没有碰磁盘。
    /// 改前（纯磁盘读）这里必然返回 nil。
    func testCommentsServedFromMemoryAfterFileRemoved() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let comments = [DanmakuComment(cid: 1, p: "0.5,1,16777215,u", m: "hello")]
        await cache.setComments(comments, for: 555)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("comments-555.json"))

        let got = await cache.comments(for: 555)
        XCTAssertEqual(got?.first?.m, "hello")
    }

    /// 命中内存也必须校验 TTL —— 否则长会话里会一直返回过期弹幕。
    func testExpiredCommentsAreEvictedFromMemory() async throws {
        let (cache, dir) = await makeCache(ttl: 0.001)
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "x")], for: 7)
        let count = await cache.commentsMemoryCount
        XCTAssertEqual(count, 1, "写入后应常驻内存")

        try await Task.sleep(for: .milliseconds(50))
        let expired = await cache.comments(for: 7)
        XCTAssertNil(expired)

        let afterCount = await cache.commentsMemoryCount
        XCTAssertEqual(afterCount, 0, "过期条目必须从内存里驱逐，不能只返回 nil")
    }

    /// 容量有界：连写 3 集后最旧那集不再驻留内存（但其文件仍在）。
    func testCommentMemoryCacheIsBounded() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = DanmakuCache(directory: dir, commentsTTL: 3600, commentsMemoryCapacity: 2)
        defer { try? FileManager.default.removeItem(at: dir) }

        for id in Int64(1)...3 {
            await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "ep\(id)")], for: id)
        }
        let count = await cache.commentsMemoryCount
        XCTAssertEqual(count, 2, "容量 2 时必须淘汰到 2 集")

        // 最旧的第 1 集已被逐出内存 —— 删掉它的文件后读不到了。
        try FileManager.default.removeItem(at: dir.appendingPathComponent("comments-1.json"))
        let evicted = await cache.comments(for: 1)
        XCTAssertNil(evicted, "第 1 集应已被淘汰出内存")

        // 最近的第 3 集仍在内存 —— 删文件后仍能读到。
        try FileManager.default.removeItem(at: dir.appendingPathComponent("comments-3.json"))
        let resident = await cache.comments(for: 3)
        XCTAssertEqual(resident?.first?.m, "ep3")

        // 淘汰只丢内存、不删文件：第 2 集的文件必须还在。
        let keptFile = dir.appendingPathComponent("comments-2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path),
                      "内存淘汰不能顺手删盘上文件")
    }

    /// 解码失败不进内存：文件修好后应能读到，说明失败态没被缓存。
    func testCorruptedCommentsAreNotCached() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("comments-42.json")
        try Data("not-json".utf8).write(to: url)
        let broken = await cache.comments(for: 42)
        XCTAssertNil(broken)

        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "fixed")], for: 42)
        let recovered = await cache.comments(for: 42)
        XCTAssertEqual(recovered?.first?.m, "fixed")
    }

    /// **读盘后必须回填内存** —— 这是 P1-15 的主要收益（冷读 13.2 ms → 热读）。
    /// 删掉 `rememberCommentsInMemory` 那一行时本用例必须红。
    ///
    /// 用**第二个实例**读：它的内存层是空的，所以一定走磁盘路径 —— 才能真正验证
    /// 「读盘之后回填」，而不是靠第一个实例的写穿掩盖过去。
    func testDiskReadBackfillsMemoryCache() async throws {
        let (writer, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        await writer.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "disk")], for: 77)

        let reader = DanmakuCache(directory: dir, commentsTTL: 3600)
        let before = await reader.commentsMemoryCount
        XCTAssertEqual(before, 0, "新实例内存层应为空")

        _ = await reader.comments(for: 77)
        let after = await reader.commentsMemoryCount
        XCTAssertEqual(after, 1, "读盘后必须回填内存")

        // 回填有效：文件删掉后仍能读到。
        try FileManager.default.removeItem(at: dir.appendingPathComponent("comments-77.json"))
        let warm = await reader.comments(for: 77)
        XCTAssertEqual(warm?.first?.m, "disk", "回填后应走内存、不再依赖磁盘")
    }

    /// LRU 必须是**最近使用**而不是先进先出：读过的条目要把使用顺序提前。
    /// 把内存命中时的 `touchCommentsInMemory` 删掉（退化成 FIFO）本用例必须红。
    func testMemoryCacheEvictsLeastRecentlyUsed() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = DanmakuCache(directory: dir, commentsTTL: 3600, commentsMemoryCapacity: 2)
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "ep1")], for: 1)
        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "ep2")], for: 2)
        // 读第 1 集 → 它变成「最近使用」，第 2 集退成最旧。
        _ = await cache.comments(for: 1)
        // 写第 3 集 → 应淘汰第 2 集（最久未使用），而不是第 1 集。
        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "ep3")], for: 3)

        for id in Int64(1)...2 {
            try FileManager.default.removeItem(at: dir.appendingPathComponent("comments-\(id).json"))
        }
        let ep1 = await cache.comments(for: 1)
        let ep2 = await cache.comments(for: 2)
        XCTAssertEqual(ep1?.first?.m, "ep1", "读过的第 1 集应仍驻留（LRU 不是 FIFO）")
        XCTAssertNil(ep2, "最久未使用的第 2 集应被淘汰")
    }

    /// 解码失败**不能进内存**（负缓存）。只断言「读不到」是不够的 ——
    /// 后面再 `setComments` 会把内存覆盖掉，看不出失败态被缓存过。
    func testCorruptedCommentsDoNotEnterMemory() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not-json".utf8).write(to: dir.appendingPathComponent("comments-42.json"))
        let broken = await cache.comments(for: 42)
        XCTAssertNil(broken)
        let count = await cache.commentsMemoryCount
        XCTAssertEqual(count, 0, "解码失败不该被当成有效条目缓存")
    }

    /// **内存快照过期不能拿去删文件**：盘上那份可能已被另一个实例刷新过。
    ///
    /// 修前实测：A（TTL 0.05）写 7 → 等待过期 → B（TTL 3600）刷新写 7 →
    /// A 读一次就把 B 刚写的新文件删了，之后全新实例 C 也读不到。
    func testStaleMemoryDoesNotDeleteFileWrittenElsewhere() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-cache-\(UUID().uuidString)", isDirectory: true)
        // ## ⚠️ TTL 与 sleep 的余量要给足（CI 实测假红过）
        //
        // 这里有两段时间都需要余量，方向还相反：
        //
        // ① **等内存条目过期**：`stale` 自己的 TTL 必须**小于** sleep 时长，
        //    否则 `comments(for:)` 直接命中内存、根本走不到磁盘路径。
        //    要求：`sleep >= staleTTL × 数倍`。
        // ② **stale 读盘上那份新数据时不能判它过期**：`diskComments` 用的是
        //    **`self.commentsTTL`**（即 `stale` 的 TTL）去判**盘上文件的
        //    `fetchedAt`** —— 而那份文件是 `other` 刚写的（`now - fetchedAt ≈ 0`）。
        //    要求：`staleTTL >= 两次操作之间的抖动 × 数倍`。
        //
        // 合起来：`staleTTL` 要**足够大**以吸收 CI 抖动，又要**足够小**以让 sleep 等得过期。
        //
        // 原值是 0.05 s TTL + 120 ms sleep：②只有一个 50 ms 的余量，CI 的慢 runner
        // 上不够 —— 实测 `main` 的 PR #46 那次假红（三处断言全红，本机同一条 0.136 s 通过）。
        // 现在 0.5 s TTL + 800 ms sleep：①有 300 ms 余量、②有 500 ms 余量。
        let stale = DanmakuCache(directory: dir, commentsTTL: 0.5)
        defer { try? FileManager.default.removeItem(at: dir) }

        await stale.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "old")], for: 7)
        try await Task.sleep(for: .milliseconds(800))

        // 另一实例在同一目录写入新数据（生产里是预览 / 重建 AppModel）。
        let other = DanmakuCache(directory: dir, commentsTTL: 3600)
        await other.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "fresh")], for: 7)

        // stale 的内存里是过期旧条目；它读一次**不能**把新文件删掉。
        let viaStale = await stale.comments(for: 7)
        XCTAssertEqual(viaStale?.first?.m, "fresh", "读到盘上那份新数据，而不是 nil")

        let url = dir.appendingPathComponent("comments-7.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "内存快照过期不得删除盘上文件")
        let freshReader = DanmakuCache(directory: dir, commentsTTL: 3600)
        let onDisk = await freshReader.comments(for: 7)
        XCTAssertEqual(onDisk?.first?.m, "fresh")
    }

    /// `purge()` 要一并清空正文内存层（否则清缓存后还读得到旧数据）。
    func testPurgeClearsCommentCache() async throws {
        let (cache, dir) = await makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "x")], for: 9)
        await cache.purge()

        let count = await cache.commentsMemoryCount
        XCTAssertEqual(count, 0)
        let afterPurge = await cache.comments(for: 9)
        XCTAssertNil(afterPurge)
    }

    /// 容量 0 = 关闭内存层，行为退回纯磁盘（给极端低内存场景留的开关）。
    func testZeroCapacityDisablesMemoryCache() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-danmaku-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = DanmakuCache(directory: dir, commentsTTL: 3600, commentsMemoryCapacity: 0)
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setComments([DanmakuComment(p: "0.5,1,16777215,u", m: "disk")], for: 11)
        let count = await cache.commentsMemoryCount
        XCTAssertEqual(count, 0)

        let fromDisk = await cache.comments(for: 11)
        XCTAssertEqual(fromDisk?.first?.m, "disk", "容量 0 时仍要能读盘")
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
