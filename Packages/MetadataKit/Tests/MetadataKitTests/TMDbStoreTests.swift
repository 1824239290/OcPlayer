import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// TMDb 落库：实体（跨租户共享）+ 对应关系（按租户隔离）+ 迁移 + 清理。
final class TMDbStoreTests: XCTestCase {

    private func makeStore() throws -> (MetadataStore, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        return (MetadataStore(database: pool), dir)
    }

    private var tenantA: TenantID { TenantID(rawValue: "srv-a:user") }
    private var tenantB: TenantID { TenantID(rawValue: "srv-b:user") }

    private func movie(_ id: Int = 603, title: String = "黑客帝国") -> TMDbEntity {
        TMDbEntity(id: id, mediaType: .movie, title: title, originalTitle: "The Matrix",
                   overview: "简介", posterPath: "/p.jpg", voteAverage: 8.2,
                   genres: ["动作"], cast: [CastMember(id: 1, name: "基努", character: "Neo")],
                   imdbID: "tt0133093")
    }

    private func season(_ number: Int = 1) -> TMDbSeason {
        TMDbSeason(seasonNumber: number, name: "第 1 季", overview: "季简介",
                   posterPath: "/s1.jpg",
                   episodes: [EpisodeEntry(episodeNumber: 1, name: "第一集", stillPath: "/st1.jpg")])
    }

    // MARK: - 实体往返

    func testEntityRoundTrips() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie()), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        let cached = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")

        let payload = try XCTUnwrap(cached?.payload)
        guard case .entity(let e) = payload else { return XCTFail("应是 entity") }
        XCTAssertEqual(e.id, 603)
        XCTAssertEqual(e.title, "黑客帝国")
        XCTAssertEqual(e.originalTitle, "The Matrix")
        XCTAssertEqual(e.genres, ["动作"])
        XCTAssertEqual(e.cast.first?.name, "基努")
        XCTAssertEqual(e.imdbID, "tt0133093")
        XCTAssertFalse(cached?.isExpired() == true, "lifetime 3600 秒，不该立刻过期")
    }

    func testSeasonRoundTrips() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        let key = TMDbEntityKey.season(tvID: 1399, number: 1)
        try await store.saveTMDbPayload(.season(season()), key: key, language: "zh-CN", lifetime: 3600)
        let cached = try await store.tmdbPayload(key: key, language: "zh-CN")

        guard case .season(let s)? = cached?.payload else { return XCTFail("应是 season") }
        XCTAssertEqual(s.seasonNumber, 1)
        XCTAssertEqual(s.episodes.count, 1)
        XCTAssertEqual(s.episodes.first?.stillPath, "/st1.jpg")
    }

    /// 语言进主键：同一实体两种语言各存一份，互不覆盖。
    func testLanguagesAreStoredSeparately() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie(title: "黑客帝国")), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        try await store.saveTMDbPayload(.entity(movie(title: "The Matrix")), key: .movie(603),
                                       language: "en-US", lifetime: 3600)

        let zh = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        let en = try await store.tmdbPayload(key: .movie(603), language: "en-US")
        guard case .entity(let zhEntity)? = zh?.payload, case .entity(let enEntity)? = en?.payload else {
            return XCTFail("两边都该有")
        }
        XCTAssertEqual(zhEntity.title, "黑客帝国")
        XCTAssertEqual(enEntity.title, "The Matrix")
    }

    /// 载荷与键**不匹配**时当未命中：防止把 `tv/1` 的数据拿去当 `tv/2` 展示
    /// （那是「显示别人的剧情简介」级别的错误）。
    func testMismatchedPayloadIsTreatedAsMiss() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        // 故意把 id=999 的实体存到 movie/603 这个键下
        try await store.saveTMDbPayload(.entity(movie(999)), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        let cached = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        XCTAssertNil(cached, "id 不匹配的载荷必须当未命中")
    }

    /// 电影载荷不能顶替剧集键（`movie/603` 与 `tv/603` 是不同实体）。
    func testMoviePayloadDoesNotSatisfyTVKey() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie(603)), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        let asTV = try await store.tmdbPayload(key: .tv(603), language: "zh-CN")
        XCTAssertNil(asTV)
    }

    func testExpiryIsRecordedAndDetectable() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        // 用一个已经过去的 lifetime（0 秒）→ 立刻过期
        try await store.saveTMDbPayload(.entity(movie()), key: .movie(603),
                                       language: "zh-CN", lifetime: 0)
        let cached = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        XCTAssertEqual(cached?.isExpired(), true, "过期的数据仍可读，但要能识别")
    }

    // MARK: - 跨租户共享

    /// 实体是**全局**的：A 服务器拉过的电影，B 服务器直接能读（省一次请求）。
    /// 这是 `tmdb_entity` 不带 `tenant_id` 的全部意义。
    func testEntitiesAreSharedAcrossTenants() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie()), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        // 不经过任何「B 租户」的写入，直接读
        let forB = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        XCTAssertNotNil(forB, "实体数据应跨服务器档案共享")
    }

    /// 对应关系相反：**按租户隔离**（条目 id 是服务端生成的，两台服务器上同 id
    /// 可能是完全不同的片子）。
    func testLinksAreTenantScoped() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbLink(itemID: "item-1", entityKey: .movie(603),
                                     source: .providerID, confidence: 1.0, tenant: tenantA)

        let linkA = try await store.tmdbLink(itemID: "item-1", tenant: tenantA)
        let linkB = try await store.tmdbLink(itemID: "item-1", tenant: tenantB)
        let countA = try await store.tmdbLinkCount(tenant: tenantA)
        let countB = try await store.tmdbLinkCount(tenant: tenantB)
        XCTAssertNotNil(linkA)
        XCTAssertNil(linkB, "另一台服务器不该看到这条对应")
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 0)
    }

    func testLinkRoundTripsSourceAndConfidence() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbLink(itemID: "i", entityKey: .season(tvID: 1399, number: 2),
                                     source: .search, confidence: 0.7, tenant: tenantA)
        let fetched = try await store.tmdbLink(itemID: "i", tenant: tenantA)
        let link = try XCTUnwrap(fetched)
        XCTAssertEqual(link.entityKey, .season(tvID: 1399, number: 2))
        XCTAssertEqual(link.source, .search)
        XCTAssertEqual(link.confidence, 0.7, accuracy: 0.001)
    }

    /// 重复写同一对 (租户, 条目) 是**更新**而不是报错（重新匹配时就是这条路）。
    func testLinkUpsertReplacesPrevious() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbLink(itemID: "i", entityKey: .movie(1),
                                     source: .search, confidence: 0.6, tenant: tenantA)
        try await store.saveTMDbLink(itemID: "i", entityKey: .movie(2),
                                     source: .manual, confidence: 1.0, tenant: tenantA)

        let updated = try await store.tmdbLink(itemID: "i", tenant: tenantA)
        let link = try XCTUnwrap(updated)
        XCTAssertEqual(link.entityKey, .movie(2))
        XCTAssertEqual(link.source, .manual)
        let count = try await store.tmdbLinkCount(tenant: tenantA)
        XCTAssertEqual(count, 1, "不该留下两条")
    }

    /// 权威来源（providerID / manual）标记正确，供匹配器判断「不可被自动覆盖」。
    func testAuthoritativeSourcesAreMarked() {
        XCTAssertTrue(TMDbLinkSource.providerID.isAuthoritative)
        XCTAssertTrue(TMDbLinkSource.manual.isAuthoritative)
        XCTAssertFalse(TMDbLinkSource.search.isAuthoritative, "搜索结果可以被更好的匹配顶掉")
    }

    func testRemoveLink() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbLink(itemID: "i", entityKey: .movie(1),
                                     source: .providerID, confidence: 1.0, tenant: tenantA)
        try await store.removeTMDbLink(itemID: "i", tenant: tenantA)
        let after = try await store.tmdbLink(itemID: "i", tenant: tenantA)
        XCTAssertNil(after)
    }

    // MARK: - 维护

    func testEvictsExpiredEntities() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie(1)), key: .movie(1),
                                       language: "zh-CN", lifetime: 0)          // 立刻过期
        try await store.saveTMDbPayload(.entity(movie(2)), key: .movie(2),
                                       language: "zh-CN", lifetime: 3600)       // 还有效

        let removed = try await store.evictExpiredTMDbEntities()
        let gone = try await store.tmdbPayload(key: .movie(1), language: "zh-CN")
        let kept = try await store.tmdbPayload(key: .movie(2), language: "zh-CN")
        XCTAssertEqual(removed, 1)
        XCTAssertNil(gone)
        XCTAssertNotNil(kept)
    }

    /// 清除只影响该租户的对应关系，且清完后**孤儿实体也一起走**
    /// （用户点「清除」不该留下查不到的死数据）。
    func testClearRemovesLinksAndOrphanEntities() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie(603)), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        try await store.saveTMDbLink(itemID: "i", entityKey: .movie(603),
                                     source: .providerID, confidence: 1.0, tenant: tenantA)

        try await store.clearTMDbData(tenant: tenantA)

        let link = try await store.tmdbLink(itemID: "i", tenant: tenantA)
        let payload = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        XCTAssertNil(link)
        XCTAssertNil(payload, "没人再引用的实体也该被清掉")
    }

    /// A 清自己的时候，**不能**把 B 还在用的实体删掉。
    func testClearKeepsEntitiesStillUsedByOtherTenant() async throws {
        let (store, dir) = try makeStore()
        defer { dir.cleanUp() }

        try await store.saveTMDbPayload(.entity(movie(603)), key: .movie(603),
                                       language: "zh-CN", lifetime: 3600)
        try await store.saveTMDbLink(itemID: "a1", entityKey: .movie(603),
                                     source: .providerID, confidence: 1.0, tenant: tenantA)
        try await store.saveTMDbLink(itemID: "b1", entityKey: .movie(603),
                                     source: .providerID, confidence: 1.0, tenant: tenantB)

        try await store.clearTMDbData(tenant: tenantA)

        let linkA = try await store.tmdbLink(itemID: "a1", tenant: tenantA)
        let linkB = try await store.tmdbLink(itemID: "b1", tenant: tenantB)
        let payload = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
        XCTAssertNil(linkA)
        XCTAssertNotNil(linkB)
        XCTAssertNotNil(payload, "B 还在用，实体不能删")
    }

    // MARK: - 迁移

    /// v2 迁移是**纯加表**：v1 的老数据必须原样保留（用户不必重拉一遍缓存）。
    func testMigrationPreservesExistingData() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanUp() }

        // 先建库（跑完 v1+v2），写一条普通条目
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let store = MetadataStore(database: pool)
        let tenant = tenantA
        try await store.saveItems([makeItem(id: "m1", name: "老电影", kind: .movie)],
                                  tenant: tenant)

        // 重开（模拟下次启动）：数据仍在
        let reopened = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        let store2 = MetadataStore(database: reopened)
        let preserved = try await store2.item("m1", tenant: tenant)
        XCTAssertNotNil(preserved, "v2 迁移不该动 v1 的数据")
        // 新表也可用
        try await store2.saveTMDbLink(itemID: "m1", entityKey: .movie(5),
                                      source: .providerID, confidence: 1.0, tenant: tenant)
        let count = try await store2.tmdbLinkCount(tenant: tenant)
        XCTAssertEqual(count, 1)
    }

    /// 建库幂等：反复重开不该重复跑迁移、也不该报错。
    func testReopeningIsIdempotent() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanUp() }

        for _ in 0..<3 {
            let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
            let store = MetadataStore(database: pool)
            try await store.saveTMDbPayload(.entity(movie()), key: .movie(603),
                                           language: "zh-CN", lifetime: 3600)
            let cached = try await store.tmdbPayload(key: .movie(603), language: "zh-CN")
            XCTAssertNotNil(cached)
        }
    }
}
