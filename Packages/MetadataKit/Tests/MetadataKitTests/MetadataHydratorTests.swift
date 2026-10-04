import CoreModel
import Foundation
import JellyfinKit
import Testing

// `MediaFileInfo` 的逐字段 init 是包内可见（见 MetadataSnapshotTests 的同款说明）。
@testable import JellyfinKit
@testable import MetadataKit

/// 离线读：内容 + 新鲜度，且「没缓存」必须与「缓存是空的」区分开。
struct MetadataHydratorTests {

    private func makeFixture() async throws -> (MetadataHydrator, MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(rawValue: "srv:user")
        return (MetadataHydrator(store: store, tenant: tenant), store, tenant, dir)
    }

    // MARK: - 首页

    /// `nil` = 从没缓存过（调用方保持原加载态）；这与「缓存过、但为空」是两回事。
    @Test func emptyCacheReturnsNil() async throws {
        let (hydrator, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        #expect(await hydrator.home() == nil)
    }

    @Test func homeSnapshotCarriesRailsAndLibraries() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        try await store.saveLibraries([
            MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows),
        ], tenant: tenant)
        try await store.saveRail([makeItem(id: "r1", name: "续播")], rail: "resume", tenant: tenant)
        try await store.saveRail([makeItem(id: "n1", name: "下一集")], rail: "nextUp", tenant: tenant)
        try await store.saveRail([makeItem(id: "l1", name: "最近")], rail: "latest", tenant: tenant)

        let home = try #require(await hydrator.home())
        #expect(home.libraries.map(\.id) == ["lib-1"])
        #expect(home.resume.map(\.id) == ["r1"])
        #expect(home.nextUp.map(\.id) == ["n1"])
        #expect(home.latest.map(\.id) == ["l1"])
        #expect(home.fetchedAt != nil)
    }

    /// 整体新鲜度取**最早**的那条 rail：只要有一条旧，整页就不该说「刚更新过」。
    @Test func homeFreshnessUsesOldestRail() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.saveRail([makeItem(id: "old")], rail: "resume", tenant: tenant, now: old)
        try await store.saveRail([makeItem(id: "new")], rail: "latest", tenant: tenant, now: new)

        let home = try #require(await hydrator.home())
        #expect(home.fetchedAt == old)
    }

    /// 只有一条 rail 有内容时也值得先用上（不是「必须齐全」）。
    @Test func homeSnapshotWithOnlyOneRailIsUsable() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        try await store.saveRail([makeItem(id: "only")], rail: "latest", tenant: tenant)
        let home = try #require(await hydrator.home())
        #expect(home.latest.map(\.id) == ["only"])
        #expect(home.resume.isEmpty)
    }

    // MARK: - 详情

    /// 详情 + 季 + 集：离线进剧集详情页要能看到上次那一季的集。
    @Test func detailSnapshotIncludesSeasonsAndEpisodes() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        try await store.saveItems([
            makeItem(id: "series-1", name: "某番", kind: .series),
            makeItem(id: "season-1", name: "第 1 季", kind: .season, seriesID: "series-1", seasonNumber: 1),
            makeItem(id: "season-0", name: "SP", kind: .season, seriesID: "series-1", seasonNumber: 0),
            makeItem(id: "ep-2", name: "第二集", kind: .episode, seriesID: "series-1",
                     seasonNumber: 1, episodeNumber: 2),
            makeItem(id: "ep-1", name: "第一集", kind: .episode, seriesID: "series-1",
                     seasonNumber: 1, episodeNumber: 1),
        ], tenant: tenant)

        let detail = try #require(await hydrator.detail(itemID: "series-1"))
        #expect(detail.item.name == "某番")
        // 季按季号排序（0 在前）。
        #expect(detail.seasons.map(\.id) == ["season-0", "season-1"])
        // 集按集号排序（不是插入顺序）。
        #expect(detail.episodes.map(\.id) == ["ep-1", "ep-2"])
    }

    @Test func detailReturnsNilForUnknownItem() async throws {
        let (hydrator, _, _, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        #expect(await hydrator.detail(itemID: "nope") == nil)
    }

    /// 电影没有季/集，也不该报错——详情页只显示条目本身。
    @Test func movieDetailHasNoSeasonsOrEpisodes() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        try await store.saveItems([makeItem(id: "m1", name: "电影")], tenant: tenant)
        let detail = try #require(await hydrator.detail(itemID: "m1"))
        #expect(detail.item.kind == .movie)
        #expect(detail.seasons.isEmpty)
        #expect(detail.episodes.isEmpty)
    }

    /// 切季时按季取集。
    @Test func episodesBySeason() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        try await store.saveItems([
            makeItem(id: "s1", kind: .season, seriesID: "series-1", seasonNumber: 1),
            makeItem(id: "s2", kind: .season, seriesID: "series-1", seasonNumber: 2),
            makeItem(id: "s1e1", kind: .episode, seriesID: "series-1", seasonNumber: 1, episodeNumber: 1),
            makeItem(id: "s2e1", kind: .episode, seriesID: "series-1", seasonNumber: 2, episodeNumber: 1),
        ], tenant: tenant)

        let season2 = await hydrator.episodes(seriesID: "series-1", seasonID: "s2")
        // 取集是按 seasonID 过滤的：第 2 季只该拿到第 2 季的集。
        #expect(season2.map(\.id).contains("s2e1"))
    }

    // MARK: - 媒体信息

    @Test func mediaFileInfoFromCache() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let info = MediaFileInfo(
            video: .init(codec: "h264", width: 1920, height: 1080, bitrate: 5_000_000,
                         frameRate: 24, bitDepth: 8, colorPrimaries: nil, colorTransfer: nil,
                         colorSpace: nil, colorRange: nil, videoRangeType: "SDR",
                         profile: "High", isInterlaced: false),
            audioTracks: [], subtitleTracks: [], container: "mp4",
            sizeBytes: 1_000, durationSeconds: 100, fileName: "a.mp4", sourceCount: 1)
        try await store.saveMediaFileInfo(info, itemID: "m1", tenant: tenant)
        let cached = try #require(await hydrator.mediaFileInfo(itemID: "m1"))
        #expect(cached.info.video?.codec == "h264")
        #expect(await hydrator.mediaFileInfo(itemID: "nope") == nil)
    }

    // MARK: - 库页

    @Test func pageFromCache() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let key = PageKey(parentID: "lib-1", kinds: [.movie], sort: nil, watchState: nil,
                          searchTerm: nil, startIndex: 0, limit: 60)
        try await store.savePage(
            MediaItemsPage(items: [makeItem(id: "p1")], startIndex: 0, totalRecordCount: 42),
            key: key, tenant: tenant)

        let page = try #require(await hydrator.page(key))
        #expect(page.items.map(\.id) == ["p1"])
        #expect(page.totalRecordCount == 42)

        let missing = PageKey(parentID: "lib-2", kinds: nil, sort: nil, watchState: nil,
                              searchTerm: nil, startIndex: 0, limit: 60)
        #expect(await hydrator.page(missing) == nil)
    }
}
