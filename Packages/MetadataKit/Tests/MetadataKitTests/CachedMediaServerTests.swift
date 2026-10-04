import CoreModel
import Foundation
import JellyfinKit
import Testing

@testable import JellyfinKit
@testable import MetadataKit

/// 写穿装饰器：**返回值与错误必须与内层完全一致**（它是纯副作用层）。
struct CachedMediaServerTests {

    private func makeFixture() async throws
        -> (CachedMediaServer, StubMediaServer, MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let store = MetadataStore(database: pool)
        let stub = StubMediaServer()
        let tenant = TenantID(profile: stub.profile)
        return (CachedMediaServer(wrapping: stub, store: store, tenant: tenant), stub, store, tenant, dir)
    }

    // MARK: - 写穿

    @Test func homeRailsArePersisted() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .success([makeItem(id: "r1", name: "续播")])
        stub.nextUpResult = .success([makeItem(id: "n1", name: "下一集", kind: .episode)])
        stub.latestResult = .success([makeItem(id: "l1", name: "最近")])
        stub.userViewsResult = .success([
            MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows),
        ])

        _ = try await server.resumeItems()
        _ = try await server.nextUp()
        _ = try await server.latestItems(limit: 24)
        _ = try await server.userViews()

        // rail 快照
        #expect(try await store.rail("resume", tenant: tenant)?.items.map(\.id) == ["r1"])
        #expect(try await store.rail("nextUp", tenant: tenant)?.items.map(\.id) == ["n1"])
        #expect(try await store.rail("latest", tenant: tenant)?.items.map(\.id) == ["l1"])
        // 条目也写进了 item 表（详情页靠它离线可用）
        #expect(try await store.item("r1", tenant: tenant)?.item.name == "续播")
        // 库列表
        #expect(try await store.libraries(tenant: tenant).map(\.library.id) == ["lib-1"])
    }

    @Test func itemAndChildrenArePersisted() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.itemResult = .success(makeItem(id: "series-1", name: "某番", kind: .series, tmdbID: "241535"))
        stub.seasonsResult = .success([makeItem(id: "season-1", name: "第 1 季", kind: .season, seasonNumber: 1)])
        stub.episodesResult = .success([
            makeItem(id: "ep-1", name: "第一集", kind: .episode, seasonNumber: 1, episodeNumber: 1),
        ])

        _ = try await server.item("series-1")
        _ = try await server.seasons(seriesID: "series-1")
        _ = try await server.episodes(seriesID: "series-1", seasonID: "season-1")

        #expect(try await store.item("series-1", tenant: tenant)?.item.tmdbID == "241535")
        #expect(try await store.item("season-1", tenant: tenant)?.item.kind == .season)
        let episode = try await store.item("ep-1", tenant: tenant)
        #expect(episode?.item.episodeNumber == 1)
        #expect(episode?.item.seasonNumber == 1)
    }

    @Test func itemsPagePersistsItemsAndPageSnapshot() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [makeItem(id: "p1", name: "条目一"), makeItem(id: "p2", name: "条目二")],
            startIndex: 0, totalRecordCount: 137))

        let page = try await server.itemsPage(
            parentID: "lib-1", kinds: [.movie], recursive: true,
            startIndex: 0, limit: 60, sort: MediaItemsSort(field: .name, ascending: true),
            watchState: .all, searchTerm: nil)
        #expect(page.totalRecordCount == 137)

        let key = PageKey(parentID: "lib-1", kinds: [.movie],
                          sort: MediaItemsSort(field: .name, ascending: true),
                          watchState: .all, searchTerm: nil, startIndex: 0, limit: 60)
        let cached = try #require(try await store.page(key, tenant: tenant))
        #expect(cached.items.map(\.id) == ["p1", "p2"])
        #expect(cached.totalRecordCount == 137)
        // 页里的条目也要进 item 表：否则离线进详情页是空的。
        #expect(try await store.item("p1", tenant: tenant)?.item.name == "条目一")
    }

    @Test func mediaFileInfoIsPersisted() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let info = MediaFileInfo(
            video: .init(codec: "hevc", width: 1920, height: 1080, bitrate: 8_000_000,
                         frameRate: 24, bitDepth: 8, colorPrimaries: nil, colorTransfer: nil,
                         colorSpace: nil, colorRange: nil, videoRangeType: "SDR",
                         profile: "Main", isInterlaced: false),
            audioTracks: [], subtitleTracks: [], container: "mp4",
            sizeBytes: 1_000_000, durationSeconds: 1440, fileName: "e1.mp4", sourceCount: 1)
        stub.mediaFileInfoResult = .success(info)

        _ = try await server.mediaFileInfo(itemID: "e1")
        #expect(try await store.mediaFileInfo(itemID: "e1", tenant: tenant)?.info == info)
    }

    /// `nil` 结果不写盘（「没有媒体源」不该被当成一条缓存记录）。
    @Test func nilMediaFileInfoIsNotPersisted() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.mediaFileInfoResult = .success(nil)
        let result = try await server.mediaFileInfo(itemID: "e1")
        #expect(result == nil)
        #expect(try await store.mediaFileInfo(itemID: "e1", tenant: tenant) == nil)
    }

    /// 标记已看：服务端返回的 playState 是权威值，直接写回缓存。
    @Test func markPlayedWritesAuthoritativePlayState() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.itemResult = .success(makeItem(id: "m1", name: "电影",
                                            playState: .init(played: false, percentage: 0, positionSeconds: 0)))
        _ = try await server.item("m1")
        stub.markPlayedResult = .success(.init(played: true, percentage: 1, positionSeconds: 7200))

        let state = try await server.markPlayed(itemID: "m1")
        #expect(state.played)

        let cached = try #require(try await store.item("m1", tenant: tenant))
        #expect(cached.item.playState?.played == true)
        #expect(cached.item.playState?.positionSeconds == 7200)
        // 进度时间戳刷新了，元数据时间戳没动（进度变了不代表简介过期）。
        #expect(cached.progressFetchedAt != nil)
    }

    // MARK: - 返回值 / 错误严格透传

    /// 错误必须原样抛（不吞、不换成缓存）——这是「UI 层才能决定要不要用旧数据」的前提。
    @Test func errorsPropagateUnchanged() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .failure(StubError.boom)
        stub.itemResult = .failure(StubError.boom)
        stub.userViewsResult = .failure(StubError.boom)

        await #expect(throws: StubError.boom) { _ = try await server.resumeItems() }
        await #expect(throws: StubError.boom) { _ = try await server.item("x") }
        await #expect(throws: StubError.boom) { _ = try await server.userViews() }
    }

    /// 失败时**不留半份缓存**：请求失败不该写盘。
    @Test func failedRequestWritesNothing() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .failure(StubError.boom)
        _ = try? await server.resumeItems()
        #expect(try await store.rail("resume", tenant: tenant) == nil)
        #expect(try await store.itemCount() == 0)
    }

    /// 返回值必须与内层**逐个字段一致**（装饰器不能悄悄改数据）。
    @Test func returnedValuesMatchInnerExactly() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let original = makeItem(id: "m1", name: "电影", kind: .movie, year: 2024,
                                playState: .init(played: false, percentage: 0.5, positionSeconds: 3600),
                                tmdbID: "603")
        stub.itemResult = .success(original)
        let returned = try await server.item("m1")
        #expect(returned == original)

        stub.resumeResult = .success([original])
        let rail = try await server.resumeItems()
        #expect(rail == [original])
    }

    /// 不缓存的几条（随机 / 推荐 / 章节 / 播放协商）**一次都不该写盘**，
    /// 且要真的转发到内层（别被装饰器吞掉）。
    @Test func passThroughMethodsForwardWithoutCaching() async throws {
        let (server, stub, store, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        _ = try await server.randomBackdropItems(limit: 8)
        _ = try await server.similar(itemID: "m1", limit: 12)
        _ = try await server.chapters(itemID: "m1")
        _ = try await server.mediaSegments(itemID: "m1")
        _ = try await server.externalSubtitles(itemID: "m1")
        // `playbackInfo` 在 stub 上刻意抛错（一次性 playSessionId 不该被缓存）；
        // 这里要确认的是「错误照样原样抛出来，且装饰器没写盘」，用 try? 取结果。
        let playback = try? await server.playbackInfo(itemID: "m1")
        #expect(playback == nil)

        #expect(stub.callCounts["randomBackdropItems"] == 1)
        #expect(stub.callCounts["similar"] == 1)
        #expect(stub.callCounts["chapters"] == 1)
        #expect(stub.callCounts["mediaSegments"] == 1)
        #expect(stub.callCounts["externalSubtitles"] == 1)
        #expect(stub.callCounts["playbackInfo"] == 1, "错误也要真的打到内层")
        #expect(try await store.itemCount() == 0, "这些方法都不该写盘")
    }

    /// 直通属性/方法不改变语义（图片 / 流地址由上层按当前地址现场拼）。
    @Test func passthroughPropertiesAndURLs() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        #expect(server.profile.id == stub.profile.id)
        #expect(server.authorizationHeader == stub.authorizationHeader)
        let image = try server.imageURL(itemID: "m1", type: .primary, maxWidth: 300, tag: "t")
        #expect(image.absoluteString.contains("/Items/m1/Images/Primary"))
        #expect(try server.streamURL(itemID: "m1", mediaSourceID: nil, playSessionID: nil)
            .contains("/Videos/m1/stream"))
    }

    /// 进度上报三条原样转发（装饰器不该插手播放链路）。
    @Test func playbackReportingForwards() async throws {
        let (server, stub, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let context = PlaybackSessionContext(
            itemID: "m1", playSessionID: "sess-1", mediaSourceID: nil,
            deliveryMethod: .directPlay)
        await server.reportPlaybackStart(context: context, positionSeconds: 0)
        await server.reportPlaybackProgress(context: context, positionSeconds: 10, isPaused: false)
        await server.reportPlaybackStopped(context: context, positionSeconds: 20)
        #expect(stub.callCounts["reportPlaybackStart"] == 1)
        #expect(stub.callCounts["reportPlaybackProgress"] == 1)
        #expect(stub.callCounts["reportPlaybackStopped"] == 1)
    }

    /// 租户来自档案：换地址（同一台服务器）时缓存仍然命中同一租户。
    @Test func tenantFollowsProfileNotAddress() async throws {
        let (server, stub, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        stub.resumeResult = .success([makeItem(id: "r1")])
        _ = try await server.resumeItems()
        // 换地址后的档案（同一 serverID:userID）派生出的租户必须相同。
        var moved = stub.profile
        moved.baseURL = URL(string: "http://100.127.128.96:8096")!
        #expect(TenantID(profile: moved) == tenant)
        #expect(try await store.rail("resume", tenant: TenantID(profile: moved)) != nil)
    }
}
