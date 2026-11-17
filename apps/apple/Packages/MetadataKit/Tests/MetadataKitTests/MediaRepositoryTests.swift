import CoreModel
import Foundation
import JellyfinKit
import XCTest

@testable import MetadataKit

final class MediaRepositoryTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory?.cleanUp()
    }

    private func makeStore() async throws -> MetadataStore {
        let store = try MetadataCache.open(at: directory.url)
        return store
    }

    private func makeRepository(
        server: StubMediaServer,
        store: MetadataStore?
    ) -> MediaRepository {
        MediaRepository(
            server: server, store: store, tenant: TenantID(profile: server.profile),
            configuration: .init(itemLimit: 64, detailLimit: 8, episodeListLimit: 8, pageLimit: 8))
    }

    // MARK: - 首页

    func testCachedHomeReadsDiskWithoutNetwork() async throws {
        let store = try await makeStore()
        let tenant = TenantID(profile: makeProfile())
        try await store.saveLibraries(
            [MediaLibrary(id: "lib-1", name: "剧集", collectionType: .tvshows)], tenant: tenant)
        try await store.saveRail([makeItem(id: "r1")], rail: "resume", tenant: tenant)
        let stub = StubMediaServer()
        let repository = makeRepository(server: stub, store: store)

        let cachedValue = await repository.cachedHome()
        let cached = try XCTUnwrap(cachedValue)

        XCTAssertEqual(cached.value.libraries.map(\.id), ["lib-1"])
        XCTAssertEqual(cached.value.resume.map(\.id), ["r1"])
        XCTAssertEqual(cached.source, .disk)
        XCTAssertEqual(stub.callCount("userViews"), 0)
        XCTAssertEqual(stub.callCount("resumeItems"), 0)
    }

    func testPartialRailFailureKeepsPreviousContentAndReportsFailure() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        let repository = makeRepository(server: stub, store: store)
        stub.userViewsResult = .success([MediaLibrary(id: "lib", name: "库", collectionType: .movies)])
        stub.resumeResult = .success([makeItem(id: "r1")])
        stub.nextUpResult = .success([makeItem(id: "r1"), makeItem(id: "e1", kind: .episode)])
        _ = await repository.refreshHome()

        stub.resumeResult = .failure(JellyfinError(.noNetwork))
        stub.latestResult = .success([makeItem(id: "l1")])
        let refreshed = await repository.refreshHome()

        XCTAssertEqual(refreshed.snapshot.value.resume.map(\.id), ["r1"], "失败分区保留上一份")
        XCTAssertEqual(refreshed.snapshot.value.nextUp.map(\.id), ["e1"], "同 id 仍从 nextUp 剔除")
        XCTAssertEqual(refreshed.snapshot.value.latest.map(\.id), ["l1"], "成功分区照常更新")
        XCTAssertTrue(refreshed.failures["resume"]?.isConnectivity == true)
        XCTAssertNil(refreshed.failures["latest"])
        let persisted = try await store.rail("resume", tenant: TenantID(profile: stub.profile))
        XCTAssertEqual(persisted?.items.map(\.id), ["r1"], "失败不得清掉磁盘 rail")
    }

    func testEmptyRailResponseClearsStaleRail() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        let repository = makeRepository(server: stub, store: store)
        stub.userViewsResult = .success([MediaLibrary(id: "lib", name: "库", collectionType: .movies)])
        stub.resumeResult = .success([makeItem(id: "old")])
        _ = await repository.refreshHome()

        stub.resumeResult = .success([])
        _ = await repository.refreshHome()

        let reopened = makeRepository(server: stub, store: store)
        let cachedValue = await reopened.cachedHome()
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertTrue(cached.value.resume.isEmpty)
        XCTAssertEqual(cached.value.libraries.map(\.id), ["lib"])
    }

    // MARK: - 详情

    func testConcurrentDetailRefreshIsCoalesced() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        stub.itemResult = .success(makeItem(id: "s1", kind: .series))
        stub.seasonsResult = .success([
            makeItem(id: "se0", kind: .season, seriesID: "s1", seasonNumber: 0),
            makeItem(id: "se1", kind: .season, seriesID: "s1", seasonNumber: 1),
        ])
        stub.episodesResult = .success([
            makeItem(id: "e1", kind: .episode, seriesID: "s1", seasonNumber: 1, episodeNumber: 1)
        ])
        let repository = makeRepository(server: stub, store: store)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await repository.refreshDetail(itemID: "s1", kindHint: .series)
                }
            }
        }

        XCTAssertEqual(stub.callCount("item"), 1)
        XCTAssertEqual(stub.callCount("seasons"), 1)
        XCTAssertEqual(stub.callCount("episodes"), 1, "默认季分集也只发一轮")
        let detailValue = await repository.cachedDetail(itemID: "s1")
        let detail = try XCTUnwrap(detailValue)
        XCTAssertEqual(detail.value.episodesSeasonID, "se1", "特别篇 0 不被选作默认季")
        XCTAssertEqual(detail.value.episodes.map(\.id), ["e1"])
    }

    func testDetailRestoresFromDiskInNewRepository() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        stub.itemResult = .success(makeItem(id: "s1", kind: .series))
        stub.seasonsResult = .success([makeItem(id: "se1", kind: .season, seriesID: "s1", seasonNumber: 1)])
        stub.episodesResult = .success([
            makeItem(id: "e1", kind: .episode, seriesID: "s1", seasonNumber: 1, episodeNumber: 1)
        ])
        let first = makeRepository(server: stub, store: store)
        _ = try await first.refreshDetail(itemID: "s1", kindHint: .series)

        let second = makeRepository(server: stub, store: store)
        let cachedValue = await second.cachedDetail(itemID: "s1")
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertEqual(cached.source, .disk)
        XCTAssertEqual(cached.value.item.id, "s1")
        XCTAssertEqual(cached.value.seasons.map(\.id), ["se1"])
        XCTAssertEqual(cached.value.episodes.map(\.id), ["e1"])
        XCTAssertEqual(stub.callCount("item"), 1, "读磁盘不再打网络")
    }

    // MARK: - 分页

    func testPagesPersistAndMergeAcrossInstances() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        stub.itemsPageRows = (0..<4).map { makeItem(id: "m\($0)") }
        let descriptor = MediaPageDescriptor(
            parentID: "lib", kinds: [.movie], recursive: true,
            sort: MediaItemsSort(field: .name, ascending: true), watchState: .all, searchTerm: nil)
        let first = makeRepository(server: stub, store: store)

        _ = try await first.refreshPage(descriptor, startIndex: 0, limit: 2)
        let all = try await first.refreshPage(descriptor, startIndex: 2, limit: 2)
        XCTAssertEqual(all.value.items.map(\.id), ["m0", "m1", "m2", "m3"])
        XCTAssertEqual(all.value.nextStartIndex, 4)

        let second = makeRepository(server: stub, store: store)
        let cachedValue = await second.cachedPage(descriptor, limit: 2)
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertEqual(cached.source, .disk)
        XCTAssertEqual(cached.value.items.map(\.id), ["m0", "m1", "m2", "m3"])
        XCTAssertEqual(cached.value.totalCount, 4)
        XCTAssertEqual(stub.callCount("itemsPage"), 2)
    }

    func testSearchTermsHaveSeparatePageCaches() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        stub.itemsPageRows = [makeItem(id: "browse")]
        stub.itemsPageRowsBySearch = ["猫": [makeItem(id: "cat")]]
        let repository = makeRepository(server: stub, store: store)
        let browsing = MediaPageDescriptor(
            parentID: "lib", kinds: [.series], recursive: true,
            sort: nil, watchState: nil, searchTerm: nil)
        let searching = MediaPageDescriptor(
            parentID: "lib", kinds: [.series], recursive: true,
            sort: nil, watchState: nil, searchTerm: "猫")

        _ = try await repository.refreshPage(browsing, startIndex: 0, limit: 20)
        _ = try await repository.refreshPage(searching, startIndex: 0, limit: 20)

        let browseCacheValue = await repository.cachedPage(browsing, limit: 20)
        let browseCache = try XCTUnwrap(browseCacheValue)
        let searchCacheValue = await repository.cachedPage(searching, limit: 20)
        let searchCache = try XCTUnwrap(searchCacheValue)
        XCTAssertEqual(browseCache.value.items.map(\.id), ["browse"])
        XCTAssertEqual(searchCache.value.items.map(\.id), ["cat"])
    }

    // MARK: - 进度写回

    func testPlaybackProgressUpdatesHomeDetailPagesAndStore() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        let item = makeItem(id: "m1", name: "电影")
        stub.userViewsResult = .success([MediaLibrary(id: "lib", name: "电影", collectionType: .movies)])
        stub.latestResult = .success([item])
        stub.itemResult = .success(item)
        stub.itemsPageRows = [item]
        let repository = makeRepository(server: stub, store: store)
        let descriptor = MediaPageDescriptor(parentID: "lib", kinds: [.movie])
        _ = await repository.refreshHome()
        _ = try await repository.refreshDetail(itemID: "m1", kindHint: .movie)
        _ = try await repository.refreshPage(descriptor, startIndex: 0, limit: 20)

        await repository.recordPlaybackProgress(
            itemID: "m1", positionSeconds: 30, durationSeconds: 60, played: false)

        let homeValue = await repository.cachedHome()
        let home = try XCTUnwrap(homeValue)
        let homeItem = try XCTUnwrap(home.value.latest.first { $0.id == "m1" })
        XCTAssertEqual(homeItem.playState?.positionSeconds, 30)
        XCTAssertEqual(homeItem.playState?.percentage ?? 0, 0.5, accuracy: 0.001)

        let detailValue = await repository.cachedDetail(itemID: "m1")
        let detail = try XCTUnwrap(detailValue)
        XCTAssertEqual(detail.value.item.playState?.positionSeconds, 30)

        let pageValue = await repository.cachedPage(descriptor, limit: 20)
        let page = try XCTUnwrap(pageValue)
        XCTAssertEqual(page.value.items.first?.playState?.positionSeconds, 30)

        let cached = try await store.item("m1", tenant: TenantID(profile: stub.profile))
        XCTAssertEqual(cached?.item.playState?.positionSeconds, 30)
        XCTAssertNotNil(cached?.progressFetchedAt)
    }

    func testMarkPlayedUsesServerStateAndWritesStore() async throws {
        let store = try await makeStore()
        let stub = StubMediaServer()
        stub.markPlayedResult = .success(.init(played: true, percentage: 1, positionSeconds: 120))
        let repository = makeRepository(server: stub, store: store)
        try await store.saveItems([makeItem(id: "m1")], tenant: TenantID(profile: stub.profile))

        let state = try await repository.markPlayed(itemID: "m1")

        XCTAssertTrue(state.played)
        XCTAssertEqual(stub.callCount("markPlayed"), 1)
        let cached = try await store.item("m1", tenant: TenantID(profile: stub.profile))
        XCTAssertEqual(cached?.item.playState, state)
    }

    func testShutdownRejectsNewPlayStateRequests() async throws {
        let stub = StubMediaServer()
        let repository = makeRepository(server: stub, store: nil)
        await repository.shutdown()
        for played in [true, false] {
            do {
                if played { _ = try await repository.markPlayed(itemID: "m1") }
                else { _ = try await repository.markUnplayed(itemID: "m1") }
                XCTFail("已停用的仓储不能继续发出已看请求")
            } catch is CancellationError {} catch { XCTFail("错误类型不符：\(error)") }
        }
        XCTAssertEqual(stub.callCount("markPlayed"), 0)
        XCTAssertEqual(stub.callCount("markUnplayed"), 0)
    }

    func testLatePlayStateRepliesCannotPersistAfterShutdownOrCancellation() async throws {
        let store = try await makeStore()
        for shutdown in [true, false] {
            for played in [true, false] {
                let stub = StubMediaServer()
                let tenant = TenantID(profile: stub.profile)
                let original = MediaItem.PlayState(played: !played, percentage: 0.2, positionSeconds: 20)
                var item = makeItem(id: "m1")
                item.playState = original
                try await store.saveItems([item], tenant: tenant)
                let repository = makeRepository(server: stub, store: store)
                let gate = PlayStateReplyGate()
                let reply = MediaItem.PlayState(played: played, percentage: played ? 1 : 0, positionSeconds: 0)
                let hook: @Sendable () async throws -> MediaItem.PlayState = {
                    await gate.suspend()
                    return reply
                }
                stub.markPlayedHook = hook
                stub.markUnplayedHook = hook
                let task = Task {
                    if played { return try await repository.markPlayed(itemID: "m1") }
                    return try await repository.markUnplayed(itemID: "m1")
                }
                await gate.waitUntilStarted()
                if shutdown { await repository.shutdown() } else { task.cancel() }
                await gate.release()
                do { _ = try await task.value; XCTFail("迟到响应应被作废") }
                catch is CancellationError {} catch { XCTFail("错误类型不符：\(error)") }
                let cached = try await store.item("m1", tenant: tenant)
                XCTAssertEqual(cached?.item.playState, original)
            }
        }
    }

    // MARK: - 无库降级

    func testMemoryOnlyRepositoryKeepsProtocolWithoutStore() async throws {
        let stub = StubMediaServer()
        stub.userViewsResult = .success([MediaLibrary(id: "lib", name: "库", collectionType: .movies)])
        stub.latestResult = .success([makeItem(id: "l1")])
        let repository = MediaRepository(server: stub, store: nil)

        let refreshed = await repository.refreshHome()
        XCTAssertEqual(refreshed.snapshot.value.latest.map(\.id), ["l1"])
        let cachedValue = await repository.cachedHome()
        let cached = try XCTUnwrap(cachedValue)
        XCTAssertEqual(cached.source, .memory)
        XCTAssertEqual(cached.value.libraries.map(\.id), ["lib"])
    }
}

private actor PlayStateReplyGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
