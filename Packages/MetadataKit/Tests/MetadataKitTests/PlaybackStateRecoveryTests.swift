import CoreModel
import Foundation
import JellyfinKit
import XCTest
@testable import MetadataKit

final class PlaybackStateRecoveryTests: XCTestCase {
    private func movie() -> MediaItem {
        MediaItem(id: "movie", name: "Movie", kind: .movie,
                  playState: .init(played: false, percentage: 0, positionSeconds: 0))
    }

    func testFinalWritePreservesPlayedWhenCanonicalItemExists() async throws {
        try await exerciseStore(evict: false)
    }

    func testFinalWritePreservesIndependentPlayedAfterCanonicalEviction() async throws {
        try await exerciseStore(evict: true)
    }

    func testFinalWritePreservesIndependentUnplayedAfterCanonicalEviction() async throws {
        try await exerciseStore(evict: true, initialPlayed: true, markedPlayed: false)
    }

    func testFinalWritePreservesUnplayedWhenCanonicalItemExists() async throws {
        try await exerciseStore(evict: false, initialPlayed: true, markedPlayed: false)
    }

    private func exerciseStore(evict: Bool, initialPlayed: Bool = false, markedPlayed: Bool = true) async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(profile: StubMediaServer().profile)
        var oldPlaybackItem = movie()
        oldPlaybackItem.playState?.played = initialPlayed
        try await store.saveItems([oldPlaybackItem], tenant: tenant)
        let watched = MediaItem.PlayState(played: markedPlayed, percentage: markedPlayed ? 1 : 0, positionSeconds: 0)
        try await store.updatePlayState(watched, forItemID: oldPlaybackItem.id, tenant: tenant)
        if evict { _ = try await store.evictItems(keepingAtMost: 0) }
        let final = try await store.recordPlaybackProgress(item: oldPlaybackItem,
                                                          positionSeconds: 42, durationSeconds: 100, tenant: tenant)
        let row = try await store.item(oldPlaybackItem.id, tenant: tenant)
        XCTAssertEqual(final.played, markedPlayed, "Final position must preserve authoritative watched state")
        XCTAssertEqual(row?.item.playState?.played, markedPlayed)
    }

    func testRepositoryFinalWritePreservesPlayedAfterDiskEviction() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let server = StubMediaServer(); let oldPlaybackItem = movie()
        server.itemResult = .success(oldPlaybackItem)
        let store = try MetadataCache.open(at: dir.url)
        let repo = MediaRepository(server: server, store: store)
        _ = try await repo.refreshItem(itemID: oldPlaybackItem.id)
        _ = try await repo.markPlayed(itemID: oldPlaybackItem.id)
        _ = try await store.evictItems(keepingAtMost: 0)
        await repo.recordFinalPlaybackProgress(item: oldPlaybackItem, positionSeconds: 42, durationSeconds: 100)
        let memory = await repo.cachedItem(itemID: oldPlaybackItem.id)
        XCTAssertEqual(memory?.value.playState?.played, true, "Disk return must not undo current memory watched state")
    }

    func testMemoryFinalWritePreservesPlayedAfterLRUEviction() async throws {
        let server = StubMediaServer(); let oldPlaybackItem = movie()
        server.itemResult = .success(oldPlaybackItem)
        let repo = MediaRepository(server: server, store: nil, configuration: .init(itemLimit: 1))
        _ = try await repo.refreshItem(itemID: oldPlaybackItem.id)
        _ = try await repo.markPlayed(itemID: oldPlaybackItem.id)
        server.itemResult = .success(MediaItem(id: "other", name: "Other", kind: .movie))
        _ = try await repo.refreshItem(itemID: "other")
        await repo.recordFinalPlaybackProgress(item: oldPlaybackItem, positionSeconds: 42, durationSeconds: 100)
        let memory = await repo.cachedItem(itemID: oldPlaybackItem.id)
        XCTAssertEqual(memory?.value.playState?.played, true, "Independent memory progress must survive LRU eviction")
    }

    func testSuccessfulEpisodeReplyKeepsMarkedStateInEveryMemoryProjection() async throws {
        try await exerciseDetail(failEpisodes: false)
    }

    func testFailedEpisodeReplyKeepsMarkedStateInEveryMemoryProjection() async throws {
        try await exerciseDetail(failEpisodes: true)
    }

    func testFailedEpisodeReplyKeepsUnplayedStateInEveryMemoryProjection() async throws {
        try await exerciseDetail(failEpisodes: true, initialPlayed: true, markedPlayed: false)
    }

    func testSuccessfulEpisodeReplyKeepsUnplayedStateInEveryMemoryProjection() async throws {
        try await exerciseDetail(failEpisodes: false, initialPlayed: true, markedPlayed: false)
    }

    func testMemoryFinalWritePreservesUnplayedAfterLRUEviction() async throws {
        let server = StubMediaServer()
        var oldPlaybackItem = movie(); oldPlaybackItem.playState?.played = true
        server.itemResult = .success(oldPlaybackItem)
        let repo = MediaRepository(server: server, store: nil, configuration: .init(itemLimit: 1))
        _ = try await repo.refreshItem(itemID: oldPlaybackItem.id)
        _ = try await repo.markUnplayed(itemID: oldPlaybackItem.id)
        server.itemResult = .success(MediaItem(id: "other", name: "Other", kind: .movie))
        _ = try await repo.refreshItem(itemID: "other")
        await repo.recordFinalPlaybackProgress(item: oldPlaybackItem, positionSeconds: 12, durationSeconds: 100)
        let memory = await repo.cachedItem(itemID: oldPlaybackItem.id)
        XCTAssertEqual(memory?.value.playState?.played, false)
        XCTAssertEqual(memory?.value.playState?.positionSeconds, 12)
    }

    func testIndependentStateFallbackRemainsTenantScoped() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let a = TenantID(profile: StubMediaServer(profileID: "a").profile)
        let b = TenantID(profile: StubMediaServer(profileID: "b").profile)
        try await store.updatePlayState(.init(played: true, percentage: 1, positionSeconds: 0),
                                        forItemID: movie().id, tenant: a)
        _ = try await store.evictItems(keepingAtMost: 0)
        let result = try await store.recordPlaybackProgress(item: movie(), positionSeconds: 12,
                                                           durationSeconds: 100, tenant: b)
        XCTAssertEqual(result.played, false, "Same ID in another tenant must not inherit watched state")
    }

    func testFallbackKeepsSnapshotMetadataAndLatestProgressFields() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(profile: StubMediaServer().profile)
        var snapshot = movie(); snapshot.overview = "full session metadata"
        snapshot.playState = .init(played: true, percentage: 1, positionSeconds: 80, unplayedCount: 99)
        try await store.saveItems([snapshot], tenant: tenant)
        try await store.updatePlayState(.init(played: false, percentage: 0, positionSeconds: 0, unplayedCount: 5),
                                        forItemID: snapshot.id, tenant: tenant)
        _ = try await store.evictItems(keepingAtMost: 0)
        let state = try await store.recordPlaybackProgress(item: snapshot, positionSeconds: 12,
                                                          durationSeconds: 100, tenant: tenant)
        let cached = try await store.item(snapshot.id, tenant: tenant)
        XCTAssertEqual(state.played, false)
        XCTAssertEqual(state.positionSeconds, 12)
        XCTAssertEqual(state.percentage, 0.12, accuracy: 0.0001)
        XCTAssertEqual(state.unplayedCount, 5)
        XCTAssertEqual(cached?.item.overview, snapshot.overview, "Compacted guard must not replace full metadata")
    }

    func testExplicitClearRemovesStateFallbackBeforeLaterPlayback() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(profile: StubMediaServer().profile)
        try await store.updatePlayState(.init(played: true, percentage: 1, positionSeconds: 0),
                                        forItemID: movie().id, tenant: tenant)
        try await store.clear(tenant: tenant)
        let result = try await store.recordPlaybackProgress(item: movie(), positionSeconds: 12,
                                                           durationSeconds: 100, tenant: tenant)
        XCTAssertEqual(result.played, false)
    }

    private func exerciseDetail(failEpisodes: Bool, initialPlayed: Bool = false, markedPlayed: Bool = true) async throws {
        for disk in [false, true] {
            let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
            let server = StubMediaServer()
            let series = MediaItem(id: "series", name: "Series", kind: .series)
            var season = MediaItem(id: "season", name: "Season", kind: .season)
            season.seriesID = series.id; season.seasonNumber = 1
            var episode = MediaItem(id: "episode", name: "Episode", kind: .episode,
                                    playState: .init(played: initialPlayed, percentage: initialPlayed ? 1 : 0, positionSeconds: 0))
            episode.seriesID = series.id; episode.seasonID = season.id
            server.itemResult = .success(series); server.seasonsResult = .success([season])
            server.episodesResult = .success([episode])
            let store = disk ? try MetadataCache.open(at: dir.url) : nil
            let repo = MediaRepository(server: server, store: store)
            _ = try await repo.refreshDetail(itemID: series.id, kindHint: .series)
            let gate = PlaybackStateReplyGate(); let oldEpisode = episode
            server.episodesHook = {
                await gate.suspend()
                if failEpisodes { throw JellyfinError(.noNetwork) }
                return [oldEpisode]
            }
            let request = Task { try await repo.refreshDetail(itemID: series.id, kindHint: .series) }
            var started = false
            for _ in 0..<400 {
                if await gate.hasStarted() { started = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard started else { request.cancel(); throw NSError(domain: "Reply gate did not start", code: 1) }
            if markedPlayed { _ = try await repo.markPlayed(itemID: episode.id) }
            else { _ = try await repo.markUnplayed(itemID: episode.id) }
            await gate.release()
            let detail = try await request.value
            let cached = await repo.cachedItem(itemID: episode.id)
            XCTAssertEqual(detail.snapshot.value.episodes.first?.playState?.played, markedPlayed)
            XCTAssertEqual(cached?.value.playState?.played, markedPlayed, "Fallback must not reinstall old episode into canonical memory; disk=\(disk)")
            if let store {
                let row = try await store.item(episode.id, tenant: TenantID(profile: server.profile))
                XCTAssertEqual(row?.item.playState?.played, markedPlayed)
            }
        }
    }
}

private actor PlaybackStateReplyGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func hasStarted() -> Bool { started }
    func release() { continuation?.resume(); continuation = nil }
}
