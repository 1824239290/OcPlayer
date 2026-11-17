import CoreModel
import Foundation
import XCTest
@testable import MetadataKit

final class RustRepositoryProgressTests: XCTestCase {
    private func library() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for retained repository progress")
        }
        return path
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double = 10
        func set(_ seconds: Double) { lock.lock(); self.seconds = seconds; lock.unlock() }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSinceReferenceDate: seconds) }
    }
    private func item(_ position: Double = 0, played: Bool = false) -> MediaItem {
        .init(id: "movie", name: "作品", kind: .movie, year: Int.max,
            playState: .init(played: played, percentage: played ? 1 : 0.1,
                positionSeconds: position, unplayedCount: Int.max))
    }
    private struct Stats: Decodable {
        struct Record: Decodable {
            var item: MediaItem
            var recordedAt: Date
            var confirmedAt: Date?
            var completed: Bool
            var revision: UInt64
        }
        var shutdown: Bool
        var records: [Record]
    }
    func testAllPublicProjectionsConfirmAndReplaceProgressLikeIndependentNative() async throws {
        let path = try library()
        var projections: [[MediaItem]] = []
        var times: [[Date]] = []
        for shared in [false, true] {
            let clock = Clock(), server = StubMediaServer()
            let repo = MediaRepository(server: server, store: nil, now: clock.now,
                rustCoreLibraryPath: shared ? path : nil, useSharedCore: shared)
            let active = await repo.usesCoreRepository; XCTAssertEqual(active, shared)
            await repo.recordFinalPlaybackProgress(item: item(), positionSeconds: 42, durationSeconds: 100)
            clock.set(20)
            let stale = item(1)
            server.itemResult = .success(stale); server.resumeResult = .success([stale])
            server.latestResult = .success([stale]); server.episodesResult = .success([stale])
            server.itemsPageRows = [stale]
            _ = await repo.refreshHome()
            _ = try await repo.refreshDetail(itemID: "movie")
            _ = try await repo.refreshPage(.init(parentID: "lib"), startIndex: 0, limit: 100)
            _ = try await repo.refreshEpisodes(seriesID: "series", seasonID: "season")
            let marked = MediaItem.PlayState(played: false, percentage: 0.12,
                positionSeconds: 12, unplayedCount: Int.max)
            clock.set(30)
            await repo.applyPlayState(marked, forItemID: "movie", persistToStore: true)
            let home = try unwrapValue( await repo.cachedHome())
            let detail = try unwrapValue( await repo.cachedDetail(itemID: "movie"))
            let page = try unwrapValue( await repo.cachedPage(.init(parentID: "lib"), limit: 100))
            let episodes = try unwrapValue( await repo.cachedEpisodes(seriesID: "series", seasonID: "season"))
            let values = home.value.resume + home.value.latest + [detail.value.item] + page.value.items + episodes.value
            XCTAssertEqual(values.count, 5)
            XCTAssertTrue(values.allSatisfy { $0.playState == marked && $0.year == Int.max })
            projections.append(values)
            times.append([home.fetchedAt, detail.fetchedAt, page.fetchedAt, episodes.fetchedAt])
            clock.set(31); server.itemResult = .success(item(4))
            let replacement = try await repo.refreshItem(itemID: "movie")
            XCTAssertEqual(replacement.playState?.positionSeconds, 4)
            await repo.invalidateMemory(discardLocalProgress: true)
            clock.set(40)
            await repo.recordFinalPlaybackProgress(item: item(), positionSeconds: 99, durationSeconds: 100)
            clock.set(41); server.resumeResult = .success([item(0, played: true)])
            let complete = await repo.refreshHome()
            XCTAssertTrue(complete.snapshot.value.resume.isEmpty)
            await repo.shutdown()
            await repo.recordFinalPlaybackProgress(item: item(), positionSeconds: 60, durationSeconds: 100)
            let after = await repo.cachedItem(itemID: "movie"); XCTAssertNil(after)
            if let rust = await repo.rust {
                let stats: Stats = try rust.decode("progress.stats", [:])
                XCTAssertTrue(stats.shutdown)
                XCTAssertEqual(stats.records.first?.item.playState?.positionSeconds, 60)
            }
        }
        XCTAssertEqual(projections[0], projections[1]); XCTAssertEqual(times[0], times[1])
    }
    func testRemoteConfirmationMatchesNativeAtSignedDateAndOneSecondBoundaries() throws {
        let path = try library()
        for recorded in [-2_000_000_000.0, 10.125] {
            for position in [0.0, 42.0, 99.0] {
                for remotePosition in [position - 1, position - 0.5, position, position + 1] {
                    for played in [false, true] {
                        for offset in [-0.125, 0, 0.125] {
                            let rust = try XCTUnwrap(RustMediaRepository.make(configuration: .init(), libraryPath: path))
                            var local = item(position)
                            local.playState = .playbackProgress(positionSeconds: position,
                                durationSeconds: 100, played: false, previous: local.playState)
                            let started = Date(timeIntervalSinceReferenceDate: recorded + offset)
                            let at = Date(timeIntervalSinceReferenceDate: recorded)
                            let now = Date(timeIntervalSinceReferenceDate: recorded + 3)
                            var progress = LocalPlaybackProgress(item: local, recordedAt: at,
                                completed: LocalPlaybackProgress.isComplete(position: position, duration: 100))
                            let _: RustMediaRepository.Began = try rust.progress("beginFinal", RustMediaRepository.Final(
                                item: local, positionSeconds: position, durationSeconds: 100, recordedAt: at))
                            let remote = item(remotePosition, played: played)
                            progress.observe(remote, requestStartedAt: started, now: now)
                            let _: [MediaItem] = try rust.progress("incoming", RustMediaRepository.Incoming(
                                incoming: [remote], merged: [remote], requestStartedAt: started, now: now))
                            let stats: Stats = try rust.decode("progress.stats", [:])
                            let record = try XCTUnwrap(stats.records.first)
                            XCTAssertEqual(record.confirmedAt, progress.confirmedAt)
                            XCTAssertEqual(record.completed, progress.completed)
                            XCTAssertEqual(record.item.playState, progress.item.playState)
                            XCTAssertEqual(record.item.playState?.unplayedCount, Int.max)
                        }
                    }
                }
            }
        }
    }
    func testForeignDiskConfirmationAndOwnedPostShutdownFinalWriteMatchNative() async throws {
        let path = try library()
        for shared in [false, true] {
            for confirmed in [false, true] {
                let dir = try TemporaryDirectory(); defer { dir.cleanUp() }
                let store = try MetadataCache.open(at: dir.url, coreLibraryPath: shared ? path : nil, useSharedCore: shared)
                let server = StubMediaServer(), tenant = TenantID(profile: server.profile)
                let date: @Sendable (Double) -> Date = { Date(timeIntervalSinceReferenceDate: $0) }
                try await store.recordPlaybackProgress(item: item(), positionSeconds: 60,
                    durationSeconds: 100, tenant: tenant, now: date(20))
                if confirmed {
                    try await store.updatePlayState(item(0, played: true).playState!,
                        forItemID: "movie", tenant: tenant, now: date(20))
                }
                let repo = MediaRepository(server: server, store: store, now: { date(30) },
                    rustCoreLibraryPath: shared ? path : nil, useSharedCore: shared)
                let active = await repo.usesCoreRepository; XCTAssertEqual(active, shared)
                await repo.recordFinalPlaybackProgress(item: item(), positionSeconds: 42,
                    durationSeconds: 100, recordedAt: date(10))
                server.itemResult = .success(item(4))
                let refreshed = try await repo.refreshItem(itemID: "movie")
                XCTAssertEqual(refreshed.playState?.positionSeconds, confirmed ? 4 : 60)
                await repo.shutdown()
                await repo.recordFinalPlaybackProgress(item: item(), positionSeconds: 70,
                    durationSeconds: 100, recordedAt: date(40))
                let cached = try await store.item("movie", tenant: tenant)
                XCTAssertEqual(cached?.item.playState?.positionSeconds, 70)
            }
        }
    }
}

private extension RustRepositoryProgressTests {
    func unwrapValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
