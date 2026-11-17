import CoreModel
import Foundation
import XCTest
@testable import MetadataKit

final class QueuedPlaybackProgressTests: XCTestCase {
    private func item(played: Bool = false) -> MediaItem {
        MediaItem(id: "queued", name: "Movie", kind: .movie,
                  playState: .init(played: played, percentage: played ? 1 : 0, positionSeconds: 0))
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testOlderSnapshotKeepsNewerExplicitStateInMemoryAndDisk() async throws {
        for disk in [false, true] {
            for played in [false, true] {
                let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
                let server = StubMediaServer(); let old = item(played: !played)
                server.itemResult = .success(old)
                let store = disk ? try MetadataCache.open(at: dir.url) : nil
                let repository = MediaRepository(server: server, store: store, now: { Date(timeIntervalSince1970: 20) })
                _ = try await repository.refreshItem(itemID: old.id)
                let marked = played ? try await repository.markPlayed(itemID: old.id)
                    : try await repository.markUnplayed(itemID: old.id)
                await repository.recordFinalPlaybackProgress(item: old, positionSeconds: 42,
                                                             durationSeconds: 100, recordedAt: date(10))
                let cached = await repository.cachedItem(itemID: old.id)
                XCTAssertEqual(cached?.value.playState, marked)
                if let store {
                    let row = try await store.item(old.id, tenant: TenantID(profile: server.profile))
                    XCTAssertEqual(row?.item.playState, marked)
                }
            }
        }
    }

    func testNewSessionUsesDiskConfirmationWithoutFreezingLaterRemoteState() async throws {
        for played in [false, true] {
            let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
            let store = try MetadataCache.open(at: dir.url)
            let server = StubMediaServer(); let tenant = TenantID(profile: server.profile)
            let old = item(played: !played)
            let marked = MediaItem.PlayState(played: played, percentage: played ? 1 : 0, positionSeconds: 0)
            try await store.saveItems([old], tenant: tenant)
            try await store.updatePlayState(marked, forItemID: old.id, tenant: tenant, now: date(20))
            let repository = MediaRepository(server: server, store: store)
            await repository.recordFinalPlaybackProgress(item: old, positionSeconds: 42,
                                                         durationSeconds: 100, recordedAt: date(10))
            let cached = await repository.cachedItem(itemID: old.id)
            XCTAssertEqual(cached?.value.playState, marked)
            var remote = item(); remote.playState?.positionSeconds = 12
            server.itemResult = .success(remote)
            let refreshed = try await repository.refreshItem(itemID: old.id)
            XCTAssertEqual(refreshed.playState, remote.playState,
                           "An ignored old write must preserve the disk confirmation boundary")
        }
    }

    func testOlderSnapshotKeepsNewerFinalPositionInMemoryAndDisk() async throws {
        for disk in [false, true] {
            let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
            let server = StubMediaServer()
            let store = disk ? try MetadataCache.open(at: dir.url) : nil
            let repository = MediaRepository(server: server, store: store, now: { Date(timeIntervalSince1970: 20) })
            await repository.recordFinalPlaybackProgress(item: item(), positionSeconds: 60, durationSeconds: 100)
            await repository.recordFinalPlaybackProgress(item: item(), positionSeconds: 42,
                                                         durationSeconds: 100, recordedAt: date(10))
            let cached = await repository.cachedItem(itemID: item().id)
            XCTAssertEqual(cached?.value.playState?.positionSeconds, 60)
            if let store {
                let row = try await store.item(item().id, tenant: TenantID(profile: server.profile))
                XCTAssertEqual(row?.item.playState?.positionSeconds, 60)
            }
        }
    }

    func testNewSessionKeepsTheNewerPendingDiskPositionUntilConfirmed() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let store = try MetadataCache.open(at: dir.url)
        let server = StubMediaServer(); let tenant = TenantID(profile: server.profile)
        try await store.recordPlaybackProgress(item: item(), positionSeconds: 60,
                                              durationSeconds: 100, tenant: tenant, now: date(20))
        let repository = MediaRepository(server: server, store: store)
        await repository.recordFinalPlaybackProgress(item: item(), positionSeconds: 42,
                                                     durationSeconds: 100, recordedAt: date(10))
        var remote = item(); remote.playState?.positionSeconds = 42
        server.itemResult = .success(remote)
        let stale = try await repository.refreshItem(itemID: remote.id)
        XCTAssertEqual(stale.playState?.positionSeconds, 60)
        remote.playState?.positionSeconds = 60; server.itemResult = .success(remote)
        _ = try await repository.refreshItem(itemID: remote.id)
        remote.playState?.positionSeconds = 12; server.itemResult = .success(remote)
        let newer = try await repository.refreshItem(itemID: remote.id)
        XCTAssertEqual(newer.playState?.positionSeconds, 12)
    }

    func testNewerCapturedSnapshotCanReplaceAnExplicitState() async throws {
        let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
        let server = StubMediaServer(); server.itemResult = .success(item(played: true))
        let store = try MetadataCache.open(at: dir.url)
        let repository = MediaRepository(server: server, store: store, now: { Date(timeIntervalSince1970: 20) })
        _ = try await repository.refreshItem(itemID: item().id)
        _ = try await repository.markUnplayed(itemID: item().id)
        await repository.recordFinalPlaybackProgress(item: item(played: true), positionSeconds: 42,
                                                     durationSeconds: 100, recordedAt: date(30))
        let cached = await repository.cachedItem(itemID: item().id)
        XCTAssertEqual(cached?.value.playState?.played, false)
        XCTAssertEqual(cached?.value.playState?.positionSeconds, 42)
    }
}
