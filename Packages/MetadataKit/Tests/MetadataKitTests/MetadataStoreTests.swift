import CoreModel
import Foundation
import JellyfinKit
import Testing

@testable import MetadataKit

/// 条目读写 / 进度语义 / 编解码宽容性。
struct MetadataStoreTests {

    private func makeStore() throws -> (MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        return (MetadataStore(database: pool), TenantID(rawValue: "srv:user"), dir)
    }

    // MARK: - round-trip

    @Test func itemRoundTripsAllFields() async throws {
        let (store, tenant, dir) = try makeStore()
        defer { dir.cleanUp() }

        let original = MediaItem(
            id: "ep-1",
            name: "第一集",
            originalTitle: "第1話",
            kind: .episode,
            overview: "简介正文",
            year: 2026,
            runtimeSeconds: 1440,
            genres: ["动画", "奇幻"],
            communityRating: 8.4,
            officialRating: "PG-13",
            seriesID: "series-1",
            seriesName: "某番",
            seasonID: "season-1",
            seasonName: "第 1 季",
            seasonNumber: 1,
            episodeNumber: 1,
            playState: .init(played: false, percentage: 0.375, positionSeconds: 540, unplayedCount: 12),
            cast: [.init(id: "p1", name: "演员", role: "主角", kind: "Actor")],
            childCount: 12,
            primaryImageTag: "tag-primary",
            thumbImageTag: "tag-thumb",
            backdropImageTag: "tag-backdrop",
            logoImageTag: "tag-logo",
            parentLogoItemID: "series-1",
            seriesThumbImageTag: "tag-series-thumb",
            parentThumbItemID: "series-1",
            parentThumbImageTag: "tag-parent-thumb",
            parentBackdropItemID: "series-1",
            parentBackdropImageTag: "tag-parent-backdrop",
            parentPrimaryImageItemID: "series-1",
            parentPrimaryImageTag: "tag-parent-primary",
            seriesPrimaryImageTag: "tag-series-primary",
            tmdbID: "241535",
            malID: "51009",
            anilistID: "163134")

        try await store.saveItems([original], tenant: tenant)
        let readBack = try #require(try await store.item("ep-1", tenant: tenant)?.item)
        // MediaItem 的 == 是全字段比较（hash 才是裁剪过的）。
        #expect(readBack == original)
    }

    /// 写完立刻读回来：投影列（族谱 / 已看）与 payload 必须一致。
    @Test func projectionColumnsMatchPayload() async throws {
        let (store, tenant, dir) = try makeStore()
        defer { dir.cleanUp() }
        let item = makeItem(id: "e1", kind: .episode, seriesID: "s1", seasonNumber: 2, episodeNumber: 7,
                            playState: .init(played: true, percentage: 1, positionSeconds: 0))
        try await store.saveItems([item], tenant: tenant)
        let cached = try #require(try await store.item("e1", tenant: tenant))
        #expect(cached.item.seriesID == "s1")
        #expect(cached.item.seasonNumber == 2)
        #expect(cached.item.episodeNumber == 7)
        #expect(cached.item.playState?.played == true)
        #expect(cached.progressFetchedAt != nil, "写入时给了进度，应记进度时间戳")
    }

    // MARK: - 宽容解码

    /// 旧 payload 缺字段必须能解出来（这是「加字段不用迁移」的全部依据）。
    @Test func decodesPayloadMissingNewFields() async throws {
        // 只给最小字段集的 JSON——模拟「老版本写下的 payload，新版本来读」。
        let legacy = #"{"id":"x1","name":"老条目","kind":"movie"}"#
        let decoded = PayloadCodec.decode(MediaItem.self, from: Data(legacy.utf8),
                                          storedVersion: Schema.payloadVersion)
        let item = try #require(decoded)
        #expect(item.id == "x1")
        #expect(item.name == "老条目")
        #expect(item.kind == .movie)
        // 缺失字段落到默认值，而不是抛错。
        #expect(item.genres.isEmpty)
        #expect(item.cast.isEmpty)
        #expect(item.overview == nil)
        #expect(item.playState == nil)
    }

    /// 认不出的版本 = 当未命中（不迁移、不抛错）。
    @Test func unknownPayloadVersionReadsAsMiss() {
        let json = #"{"id":"x1","name":"N","kind":"movie"}"#
        let data = Data(json.utf8)
        #expect(PayloadCodec.decode(MediaItem.self, from: data,
                                    storedVersion: Schema.payloadVersion + 1) == nil)
    }

    /// 服务端报出没见过的 `Type` 串时落 `.other`，而不是让整个 payload 解不出来。
    @Test func unknownKindDecodesAsOther() async throws {
        let json = #"{"id":"x1","name":"N","kind":"SomethingNew"}"#
        let item = try #require(PayloadCodec.decode(MediaItem.self, from: Data(json.utf8),
                                                    storedVersion: Schema.payloadVersion))
        #expect(item.kind == .other)
    }

    // MARK: - 进度

    /// `markPlayed` 这类只带进度的写：payload 与投影列都要更新（否则读回来还是旧进度），
    /// 且**不该**动 `fetched_at`（元数据没变）。
    @Test func updatePlayStateUpdatesPayloadButNotMetadataTimestamp() async throws {
        let (store, tenant, dir) = try makeStore()
        defer { dir.cleanUp() }
        try await store.saveItems([makeItem(id: "m1", name: "电影")], tenant: tenant)
        let before = try #require(try await store.item("m1", tenant: tenant))

        try await store.updatePlayState(.init(played: true, percentage: 1, positionSeconds: 7200),
                                  forItemID: "m1", tenant: tenant)

        let after = try #require(try await store.item("m1", tenant: tenant))
        #expect(after.item.playState?.played == true)
        #expect(after.item.playState?.positionSeconds == 7200)
        #expect(after.fetchedAt == before.fetchedAt, "进度更新不该刷新元数据时间戳")
        #expect(after.progressFetchedAt != nil)
        // 其它字段不能被只有进度的对象盖掉。
        #expect(after.item.name == "电影")
    }

    /// 进度新旧独立判定：刚写入不算过期，给了很久以前的时间戳就算过期。
    @Test func progressStalenessIsIndependentOfMetadata() {
        let old = Date(timeIntervalSinceNow: -Freshness.progress - 60)
        let fresh = CachedItem(item: makeItem(id: "a"), fetchedAt: Date(), progressFetchedAt: Date())
        let stale = CachedItem(item: makeItem(id: "a"), fetchedAt: Date(), progressFetchedAt: old)
        let unknown = CachedItem(item: makeItem(id: "a"), fetchedAt: Date(), progressFetchedAt: nil)
        #expect(!fresh.isProgressStale())
        #expect(stale.isProgressStale())
        // 从没被服务端确认过的进度按「可能过期」处理（宁可提示，不要假装准）。
        #expect(unknown.isProgressStale())
    }

    // MARK: - 租户隔离

    /// 两台服务器（或同一台的两个人）的同名 itemID 不能互相污染。
    @Test func tenantsAreIsolated() async throws {
        let (store, tenantA, dir) = try makeStore()
        defer { dir.cleanUp() }
        let tenantB = TenantID(rawValue: "other:user")

        try await store.saveItems([makeItem(id: "shared", name: "A 的条目")], tenant: tenantA)
        try await store.saveItems([makeItem(id: "shared", name: "B 的条目")], tenant: tenantB)

        let readA = try await store.item("shared", tenant: tenantA)
        let readB = try await store.item("shared", tenant: tenantB)
        #expect(readA?.item.name == "A 的条目")
        #expect(readB?.item.name == "B 的条目")

        // 清 A 不能动 B。
        try await store.clear(tenant: tenantA)
        let afterClearA = try await store.item("shared", tenant: tenantA)
        let afterClearB = try await store.item("shared", tenant: tenantB)
        #expect(afterClearA == nil)
        #expect(afterClearB?.item.name == "B 的条目")
    }

    /// 租户 id 从档案派生：有 id 用 id，id 为空时退回 kind:userID（不能全挤进空串）。
    @Test func tenantIDDerivation() {
        let normal = makeProfile()
        #expect(TenantID(profile: normal).rawValue == "srv:user")

        var blank = makeProfile()
        blank.id = ""
        #expect(TenantID(profile: blank).rawValue == "jellyfin:user")

        var whitespace = makeProfile()
        whitespace.id = "   "
        #expect(TenantID(profile: whitespace).rawValue == "jellyfin:user")
    }

    /// 一台服务器多条地址：`baseURL` 变了（换到 Tailscale）但 tenant 必须不变，
    /// 否则换个网络首页缓存就"空"了。
    @Test func tenantIgnoresBaseURL() {
        var lan = makeProfile()
        lan.baseURL = URL(string: "http://192.168.5.107:8096")!
        var tailscale = makeProfile()
        tailscale.baseURL = URL(string: "http://100.127.128.96:8096")!
        #expect(TenantID(profile: lan) == TenantID(profile: tailscale))
    }

    // MARK: - 批量读

    @Test func bulkReadReturnsOnlyExistingInRequestedOrder() async throws {
        let (store, tenant, dir) = try makeStore()
        defer { dir.cleanUp() }
        try await store.saveItems([makeItem(id: "a"), makeItem(id: "b"), makeItem(id: "c")], tenant: tenant)
        let got = try await store.items(["c", "missing", "a"], tenant: tenant)
        // 缺的直接跳过，其余按请求顺序（详情页按季/集顺序取用）。
        #expect(got.map(\.item.id) == ["c", "a"])
    }
}
