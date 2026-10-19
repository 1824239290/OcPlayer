import CoreModel
import Foundation
import JellyfinKit
import Testing

@testable import MetadataKit

/// 离线读：内容 + 新鲜度，且「没缓存」必须与「缓存是空的」区分开。
struct MetadataHydratorTests {

    private func makeFixture() async throws -> (MetadataHydrator, MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let store = try MetadataCache.open(at: dir.url)
        let tenant = TenantID(rawValue: "srv:user")
        return (MetadataHydrator(store: store, tenant: tenant), store, tenant, dir)
    }

    // MARK: - 首页（P2-23：单次读事务）

    /// **`homeSnapshotParts` 一次取回四份数据，与四个独立读结果逐字段一致。**
    ///
    /// 改前 `home()` 是四个独立 `await`，每次一个 `database.read`；读事务本身
    /// ≈29–37 µs（实测）。合并后真实数据 A/B：**751.0 → 602.0 µs（省 19.8%）**。
    ///
    /// 这条钉的是**内容不能因合并而错**：漏读、串读（把 nextUp 读成 latest）、
    /// 或某条 rail 解码失败拖垮整次读，都会在这里暴露。
    @Test func homeSnapshotPartsMatchesIndividualReads() async throws {
        let (_, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        try await store.saveLibraries([
            MediaLibrary(id: "lib-1", name: "电影", collectionType: .movies),
            MediaLibrary(id: "lib-2", name: "剧集", collectionType: .tvshows),
        ], tenant: tenant)
        try await store.saveRail([makeItem(id: "r1", name: "续播")], rail: "resume", tenant: tenant)
        try await store.saveRail([makeItem(id: "n1", name: "下一集")], rail: "nextUp", tenant: tenant)
        // latest 刻意不写 —— 验证「部分缺失不影响其它三项」。

        let parts = await store.homeSnapshotParts(tenant: tenant)

        let expectedLibraries = try await store.libraries(tenant: tenant).map(\.library)
        #expect(parts.libraries.map(\.library) == expectedLibraries, "库列表必须与独立读一致")
        #expect(parts.rails["resume"]?.items.map(\.id) == ["r1"])
        #expect(parts.rails["nextUp"]?.items.map(\.id) == ["n1"])
        #expect(parts.rails["latest"] == nil, "没写的 rail 必须是 nil，不能被别的 rail 顶替")
    }

    /// 空库时四份全空，不崩、不串。
    @Test func homeSnapshotPartsOnEmptyCacheIsAllEmpty() async throws {
        let (_, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        let parts = await store.homeSnapshotParts(tenant: tenant)
        #expect(parts.libraries.isEmpty)
        #expect(parts.rails.isEmpty)
    }

    /// 合并之后 `home()` 的对外语义**完全不变**：三条 rail 必须各归各位。
    ///
    /// 这条防的是「合并 SQL 时把 rail 名接错」（例如 `nextUp` 查成 `latest`）——
    /// 那种错不会崩，只会让首页安静地显示错内容。
    @Test func homeAfterMergeKeepsRailsDistinct() async throws {
        let (hydrator, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        try await store.saveRail([makeItem(id: "resume-1", name: "续播")], rail: "resume", tenant: tenant)
        try await store.saveRail([makeItem(id: "next-1", name: "下一集")], rail: "nextUp", tenant: tenant)
        try await store.saveRail([makeItem(id: "latest-1", name: "最近")], rail: "latest", tenant: tenant)

        let snapshot = try #require(await hydrator.home())
        #expect(snapshot.resume.map(\.id) == ["resume-1"])
        #expect(snapshot.nextUp.map(\.id) == ["next-1"])
        #expect(snapshot.latest.map(\.id) == ["latest-1"])
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
}
