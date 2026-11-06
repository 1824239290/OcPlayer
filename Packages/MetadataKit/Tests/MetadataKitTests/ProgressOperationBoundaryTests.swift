import Foundation
import CoreModel
import JellyfinKit
import XCTest
@testable import MetadataKit

final class ProgressOperationBoundaryTests: XCTestCase {
    private func movie(played: Bool = false) -> MediaItem {
        MediaItem(id: "item", name: "movie", kind: .movie,
                  playState: .init(played: played, percentage: played ? 1 : 0, positionSeconds: 0))
    }
    func testMarkPlayedWithoutOlderInflightResponsePreservesState() async throws {
        let server = StubMediaServer()
        server.itemResult = .success(movie())
        let repository = MediaRepository(server: server, store: nil)
        _ = try await repository.refreshItem(itemID: "item")
        _ = try await repository.markPlayed(itemID: "item")
        let cached = await repository.cachedItem(itemID: "item")
        XCTAssertEqual(cached?.value.playState?.played, true)
    }
    func testInflightResponseCannotUndoExplicitPlayedMark() async throws {
        for disk in [false, true] {
            let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
            let server = StubMediaServer()
            server.itemResult = .success(movie())
            let store = disk ? try MetadataCache.open(at: dir.url) : nil
            let repository = MediaRepository(server: server, store: store)
            _ = try await repository.refreshItem(itemID: "item")
            await repository.recordFinalPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100)
            let gate = BoundaryItemReplyGate(); let oldReply = movie()
            server.itemHook = { await gate.suspend(); return oldReply }
            let request = Task { try await repository.refreshItem(itemID: "item") }
            var started = false
            for _ in 0..<400 {
                if await gate.hasStarted() { started = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard started else { request.cancel(); XCTFail("Controlled response did not start"); return }
            _ = try await repository.markPlayed(itemID: "item")
            let beforeReply = await repository.cachedItem(itemID: "item")
            XCTAssertEqual(beforeReply?.value.playState?.played, true, "Explicit mark must first succeed")
            await gate.release()
            _ = try await request.value
            let cached = await repository.cachedItem(itemID: "item")
            XCTAssertEqual(cached?.value.playState?.played, true, "An earlier unplayed response must not undo the successful user action; disk=\(disk)")
            if let store {
                let persisted = try await store.item("item", tenant: TenantID(profile: server.profile))
                XCTAssertEqual(persisted?.item.playState?.played, true, "Disk must preserve explicit played action")
            }
        }
    }
}

private actor BoundaryItemReplyGate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { started }
    func release() { continuation?.resume(); continuation = nil }
}

extension ProgressOperationBoundaryTests {
    func testInflightReplyCannotUndoUnplayedAndNewerReplyCanTakeOver() async throws {
        try await exerciseBoundary(oldPlayed: true, markPlayed: false, evictBeforeMark: false)
    }

    func testDirectAuthoritativeStateUsesTheSameBoundary() async throws {
        try await exerciseBoundary(oldPlayed: false, markPlayed: nil, evictBeforeMark: false)
    }

    func testMarkBoundarySurvivesEvictionWhileOlderRequestIsInflight() async throws {
        try await exerciseBoundary(oldPlayed: false, markPlayed: true, evictBeforeMark: true)
    }

    private func exerciseBoundary(oldPlayed: Bool, markPlayed: Bool?, evictBeforeMark: Bool) async throws {
        for disk in [false, true] {
            let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
            let server = StubMediaServer()
            let oldReply = movie(played: oldPlayed)
            server.itemResult = .success(oldReply)
            let store = disk ? try MetadataCache.open(at: dir.url) : nil
            let repository = MediaRepository(server: server, store: store)
            _ = try await repository.refreshItem(itemID: "item")
            await repository.recordFinalPlaybackProgress(item: oldReply, positionSeconds: 42, durationSeconds: 100)
            let gate = BoundaryItemReplyGate()
            server.itemHook = { await gate.suspend(); return oldReply }
            let request = Task { try await repository.refreshItem(itemID: "item") }
            var started = false
            for _ in 0..<400 {
                if await gate.hasStarted() { started = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard started else { request.cancel(); XCTFail("Controlled response did not start"); return }
            if evictBeforeMark, let store { _ = try await store.evictItems(keepingAtMost: 0) }
            let expected: MediaItem.PlayState
            if let markPlayed {
                expected = markPlayed ? try await repository.markPlayed(itemID: "item")
                    : try await repository.markUnplayed(itemID: "item")
            } else {
                expected = .init(played: true, percentage: 1, positionSeconds: 0)
                await repository.applyPlayState(expected, forItemID: "item", persistToStore: true)
            }
            if let store { _ = try await store.evictItems(keepingAtMost: 0) }
            await gate.release()
            let response = try await request.value
            XCTAssertEqual(response.playState, expected, "Old reply must preserve explicit operation")
            let cached = await repository.cachedItem(itemID: "item")
            XCTAssertEqual(cached?.value.playState, expected)
            if let store {
                let row = try await store.item("item", tenant: TenantID(profile: server.profile))
                XCTAssertEqual(row?.item.playState, expected)
            }
            // A subsequent request is allowed to reflect a newer change made elsewhere.
            server.itemHook = nil
            server.itemResult = .success(oldReply)
            let newer = try await repository.refreshItem(itemID: "item")
            XCTAssertEqual(newer.playState, oldReply.playState, "Explicit state must not be frozen forever")
        }
    }

    func testExplicitFenceIsTenantScopedAndSurvivesMetadataEviction() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let a = TenantID(profile: StubMediaServer(profileID: "a").profile)
        let b = TenantID(profile: StubMediaServer(profileID: "b").profile)
        let watched = movie(played: true)
        try await store.updatePlayState(watched.playState!, forItemID: "item", tenant: a,
                                        now: Date(timeIntervalSince1970: 20), fallbackItem: watched)
        _ = try await store.evictItems(keepingAtMost: 0)
        let aRows = try await store.saveItems([movie()], tenant: a, now: Date(timeIntervalSince1970: 30),
                                             requestStartedAt: Date(timeIntervalSince1970: 10))
        let bRows = try await store.saveItems([movie()], tenant: b, now: Date(timeIntervalSince1970: 30),
                                             requestStartedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(aRows.first?.playState?.played, true)
        XCTAssertEqual(bRows.first?.playState?.played, false)
    }

    func testExplicitCacheClearDiscardsDiskAndMemoryProtection() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let server = StubMediaServer(); server.itemResult = .success(movie())
        let store = try MetadataCache.open(at: dir.url)
        let repository = MediaRepository(server: server, store: store)
        await repository.recordFinalPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100)
        try await store.clear(tenant: TenantID(profile: server.profile))
        await repository.invalidateMemory(discardLocalProgress: true)
        let refreshed = try await repository.refreshItem(itemID: "item")
        XCTAssertEqual(refreshed.playState?.positionSeconds, 0)
    }
}

extension ProgressOperationBoundaryTests {
    func testOlderFinalWriteCannotUndoNewerExplicitMark() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(profile: StubMediaServer().profile)
        let watched = movie(played: true)
        try await store.recordPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100,
                                              tenant: tenant, now: Date(timeIntervalSince1970: 10))
        try await store.updatePlayState(watched.playState!, forItemID: "item", tenant: tenant, now: Date(timeIntervalSince1970: 30))
        let delayed = try await store.recordPlaybackProgress(item: movie(), positionSeconds: 12, durationSeconds: 100,
                                                            tenant: tenant, now: Date(timeIntervalSince1970: 20))
        let row = try await store.item("item", tenant: tenant)
        XCTAssertEqual(delayed, watched.playState)
        XCTAssertEqual(row?.item.playState, watched.playState)
        let newer = try await store.recordPlaybackProgress(item: movie(), positionSeconds: 12, durationSeconds: 100,
                                                           tenant: tenant, now: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(newer.positionSeconds, 12)
    }

    func testOlderExplicitWriteCannotUndoNewerFinalPosition() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(profile: StubMediaServer().profile)
        try await store.recordPlaybackProgress(item: movie(), positionSeconds: 42, durationSeconds: 100,
                                              tenant: tenant, now: Date(timeIntervalSince1970: 30))
        try await store.updatePlayState(movie().playState!, forItemID: "item", tenant: tenant, now: Date(timeIntervalSince1970: 20))
        let reply = try await store.saveItems([movie()], tenant: tenant, now: Date(timeIntervalSince1970: 40),
                                              requestStartedAt: Date(timeIntervalSince1970: 35))
        XCTAssertEqual(reply.first?.playState?.positionSeconds, 42)
    }
}
