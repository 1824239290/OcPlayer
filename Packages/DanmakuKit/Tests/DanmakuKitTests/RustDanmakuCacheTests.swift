import Foundation
import XCTest
import OcPlayerCore
@testable import DanmakuKit

final class RustDanmakuCacheTests: XCTestCase {
    private func folder() throws -> URL {
        guard OcpCoreFeature.isEnabled else { throw XCTSkip("Enable Core for cache interoperability checks") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-cache-interop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func coreCache(_ directory: URL) async throws -> DanmakuCache {
        let cache = DanmakuCache(directory: directory, useCore: true)
        let active = await cache.usesCoreCache
        XCTAssertTrue(active, "A fallback cannot certify Core cache compatibility")
        guard active else { throw OcpCoreError(message: "Core cache did not activate") }
        return cache
    }

    func testNativeAndCoreFilesAreBidirectionallyCompatible() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodeID: Int64 = 9_007_199_254_740_993
        let match = DanmakuEpisodeMatch(episodeID: episodeID, shiftSeconds: 4_294_967_296,
            animeID: .max, animeTitle: "作品", episodeTitle: "第1话")
        let comments = [DanmakuComment(cid: .max, p: "12.5,4,16777215,用户", m: "完整正文")]
        let hint = DanmakuIntroHint(startSeconds: nil, endSeconds: 93.5, evidenceCount: 3, source: .learned)
        let native = DanmakuCache(directory: directory, useCore: false)
        await native.setEpisodeMatch(match, for: "native")
        await native.setComments(comments, for: episodeID)
        await native.setIntroHint(hint, for: episodeID)

        let core = try await coreCache(directory)
        let nativeMatch = await core.episodeMatch(for: "native")
        let nativeComments = await core.comments(for: episodeID)
        let nativeHint = await core.introHint(for: episodeID)
        XCTAssertEqual(nativeMatch, match)
        XCTAssertEqual(nativeComments, comments)
        XCTAssertEqual(nativeHint, hint)
        await core.setEpisodeMatch(match, for: "core")
        await core.setComments(comments, for: episodeID + 1)
        await core.setIntroHint(hint, for: episodeID + 1)

        let reopenedNative = DanmakuCache(directory: directory, useCore: false)
        let coreMatch = await reopenedNative.episodeMatch(for: "core")
        let coreComments = await reopenedNative.comments(for: episodeID + 1)
        let coreHint = await reopenedNative.introHint(for: episodeID + 1)
        XCTAssertEqual(coreMatch, match)
        XCTAssertEqual(coreComments, comments)
        XCTAssertEqual(coreHint, hint)
    }

    func testLegacyFilesAndCorruptMappingRecoverWithoutDataLoss() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mapping = directory.appendingPathComponent("mapping.json")
        let damaged = Data("{recoverable".utf8)
        try damaged.write(to: mapping)
        let core = try await coreCache(directory)
        await core.setEpisodeID(42, for: "new")
        XCTAssertEqual(try Data(contentsOf: mapping), damaged)
        try Data("{\"legacy\":9007199254740993}".utf8).write(to: mapping)
        let legacy = await core.episodeID(for: "legacy")
        XCTAssertEqual(legacy, 9_007_199_254_740_993)
        await core.setEpisodeID(42, for: "new")
        let native = DanmakuCache(directory: directory, useCore: false)
        let preserved = await native.episodeID(for: "legacy")
        let added = await native.episodeID(for: "new")
        XCTAssertEqual(preserved, legacy)
        XCTAssertEqual(added, 42)
        try Data("{\"42\":{\"endSeconds\":90,\"evidenceCount\":2,\"source\":null}}".utf8)
            .write(to: directory.appendingPathComponent("intro-hints.json"))
        let hint = await core.introHint(for: 42)
        XCTAssertEqual(hint?.source, .danmaku)
    }

    func testUInt64RevisionBarrierSurvivesTheSwiftABIProjection() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await coreCache(directory)
        await core.claimEpisodeMatchRevision(for: "media", revision: .max)
        await core.setEpisodeMatch(DanmakuEpisodeMatch(episodeID: 1), for: "media", revision: .max - 1)
        let rejected = await core.episodeMatch(for: "media")
        let claimed = await core.claimedRevision(for: "media")
        XCTAssertNil(rejected)
        XCTAssertEqual(claimed, UInt64.max)
        await core.setEpisodeMatch(DanmakuEpisodeMatch(episodeID: 2), for: "media", revision: .max)
        let accepted = await core.episodeID(for: "media")
        XCTAssertEqual(accepted, 2)
        await core.removeEpisodeMatch(for: "media")
        let cleared = await core.claimedRevision(for: "media")
        XCTAssertNil(cleared)
    }
}
