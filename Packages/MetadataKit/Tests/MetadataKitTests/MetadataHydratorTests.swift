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

        let parts = try await store.homeSnapshotParts(tenant: tenant)

        let expectedLibraries = try await store.libraries(tenant: tenant).map(\.library)
        #expect(parts.libraries.map(\.library) == expectedLibraries, "库列表必须与独立读一致")
        #expect(parts.rails["resume"]?.items.map(\.id) == ["r1"])
        #expect(parts.rails["nextUp"]?.items.map(\.id) == ["n1"])
        #expect(parts.rails["latest"] == nil, "没写的 rail 必须是 nil，不能被别的 rail 顶替")
    }

    /// **真实读失败必须能被上报，而不是被压成「全空」。**
    ///
    /// 第一版写的是 `(try? database.read { ... }) ?? ([], [:])` —— 那会把
    /// 「库损坏 / 表被删」压成「没有任何缓存」，与「服务端确实是空的」不可区分。
    ///
    /// 这里**真的制造一次读失败**：把 `rail` 表改名，于是 `homeSnapshotParts`
    /// 里的查询必然抛错。断言它 **throws**（而不是安静返回空）。
    @Test func readFailureThrowsInsteadOfLookingEmpty() async throws {
        let (_, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        // 先造一点正常数据，确保「空」本来不该是答案。
        try await store.saveRail([makeItem(id: "r1", name: "续播")], rail: "resume", tenant: tenant)

        // 制造读失败：把 rail 表改名（`homeSnapshotParts` 的查询随即失败）。
        try await store.rawWriteForTesting { db in
            try db.execute(sql: "ALTER TABLE rail RENAME TO rail_broken")
        }

        var threw = false
        do {
            _ = try await store.homeSnapshotParts(tenant: tenant)
        } catch {
            threw = true
        }
        #expect(threw, "读失败被压成了「空结果」——无法与「没有缓存」区分")

        // 修好表之后应恢复正常（证明失败不是永久态）。
        try await store.rawWriteForTesting { db in
            try db.execute(sql: "ALTER TABLE rail_broken RENAME TO rail")
        }
        let recovered = try await store.homeSnapshotParts(tenant: tenant)
        #expect(recovered.rails["resume"]?.items.map(\.id) == ["r1"], "修好后必须能读回")
    }

    /// **库列表必须按 `position` 排，不能靠 rowid 巧合。**
    ///
    /// `saveLibraries` 是整表替换、position 恒等于插入序（= rowid 序），所以正常
    /// 路径下「有没有 `ORDER BY position`」看不出来 —— 这也是变异能存活的原因。
    ///
    /// 这里直接写一份 **position ≠ rowid 序** 的数据（真实场景：服务端调整了库顺序、
    /// 或将来改成增量写），断言读回来按 position 排。
    @Test func librariesAreOrderedByPositionNotRowID() async throws {
        let (_, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        // 先正常存三条，拿到 payload。
        try await store.saveLibraries([
            MediaLibrary(id: "p0", name: "零", collectionType: .movies),
            MediaLibrary(id: "p1", name: "一", collectionType: .tvshows),
            MediaLibrary(id: "p2", name: "二", collectionType: .music),
        ], tenant: tenant)
        let baseline = try await store.libraries(tenant: tenant)
        #expect(baseline.map(\.library.id) == ["p0", "p1", "p2"], "前置：正常顺序")

        // 把 position 改成「倒序」：p0→2、p1→1、p2→0。
        // 注意 library_id 不变、rowid 也不变，只有 position 变 —— 于是
        // 「按 rowid 读」与「按 position 读」会给出**相反**的结果。
        try await store.rawWriteForTesting { db in
            for (id, position) in [("p0", 2), ("p1", 1), ("p2", 0)] {
                try db.execute(
                    sql: "UPDATE library SET position = ? WHERE tenant_id = ? AND library_id = ?",
                    arguments: [position, tenant.rawValue, id])
            }
        }

        let reordered = try await store.libraries(tenant: tenant)
        #expect(reordered.map(\.library.id) == ["p2", "p1", "p0"],
                "没有按 position 排（很可能退化成 rowid 序 = p0,p1,p2）")

        let parts = try await store.homeSnapshotParts(tenant: tenant)
        #expect(parts.libraries.map(\.library.id) == ["p2", "p1", "p0"],
                "homeSnapshotParts 也必须按 position 排")
    }

    /// 空库时四份全空，不崩、不串。    /// 空库时四份全空，不崩、不串。
    /// **跨租户绝不能串读**（审查实测：去掉 `tenant_id = ?` 会让新用例全绿）。
    ///
    /// 合并成一条 `IN (?,?,?)` 查询后，`tenant_id` 条件只剩一处 —— 写漏就是
    /// 「A 账号的首页看到 B 账号的续播」，而且不崩、不报错。
    @Test func homeSnapshotPartsDoesNotLeakAcrossTenants() async throws {
        let (_, store, tenantA, dir) = try await makeFixture()
        defer { dir.cleanUp() }
        let tenantB = TenantID(rawValue: "srv:other-user")

        try await store.saveLibraries([MediaLibrary(id: "lib-A", name: "A库", collectionType: .movies)],
                                      tenant: tenantA)
        try await store.saveLibraries([MediaLibrary(id: "lib-B", name: "B库", collectionType: .movies)],
                                      tenant: tenantB)
        for rail in ["resume", "nextUp", "latest"] {
            try await store.saveRail([makeItem(id: "A-\(rail)", name: "A")], rail: rail, tenant: tenantA)
            try await store.saveRail([makeItem(id: "B-\(rail)", name: "B")], rail: rail, tenant: tenantB)
        }

        let a = try await store.homeSnapshotParts(tenant: tenantA)
        #expect(a.libraries.map(\.library.id) == ["lib-A"], "读到了别的租户的库")
        #expect(a.rails["resume"]?.items.map(\.id) == ["A-resume"], "读到了别的租户的 rail")
        #expect(a.rails["nextUp"]?.items.map(\.id) == ["A-nextUp"])
        #expect(a.rails["latest"]?.items.map(\.id) == ["A-latest"])

        let b = try await store.homeSnapshotParts(tenant: tenantB)
        #expect(b.libraries.map(\.library.id) == ["lib-B"])
        #expect(b.rails["resume"]?.items.map(\.id) == ["B-resume"])
    }

    @Test func homeSnapshotPartsOnEmptyCacheIsAllEmpty() async throws {
        let (_, store, tenant, dir) = try await makeFixture()
        defer { dir.cleanUp() }

        let parts = try await store.homeSnapshotParts(tenant: tenant)
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
