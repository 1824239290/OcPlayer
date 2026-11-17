import CoreModel
import Foundation
import JellyfinKit
import Testing

@testable import MetadataKit

/// `MetadataStore.posterCandidates` 的回归——登录页海报墙的**条目身份**来源。
///
/// ## 为什么这条查询值得单独测
///
/// 图片缓存里同时存着**演员头像**（`/Items/{personId}/Images/Primary`）与条目海报，
/// 两者都是 2:3 竖图，按宽高比根本分不开（本机实测：429 张竖图里最大的两档尺寸
/// 342×513 共 101 张、240×360 共 65 张**几乎全是演员头像**）。所以「墙上摆哪些图」
/// 只能由条目身份决定——这条查询就是那个身份的唯一来源。它多放一类进来，墙上就会
/// 出现一墙陌生人的脸；它少放，墙就变空。两者都不报错。
struct PosterCandidatesTests {

    private func makeStore() async throws -> (MetadataStore, TenantID, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let pool = try MetadataDatabaseFactory.makeDatabase(at: dir.url)
        return (MetadataStore(database: pool), TenantID(rawValue: "srv:user"), dir)
    }

    /// 只有「电影 / 剧集」且**有主图**的条目能上墙。
    @Test func onlyMoviesAndSeriesWithAPosterQualify() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }

        try await store.saveItems([
            makeItem(id: "movie-1", name: "电影有图", kind: .movie, primaryImageTag: "t1"),
            makeItem(id: "series-1", name: "剧集有图", kind: .series, primaryImageTag: "t2"),
            // 有图但不是「条目」：单集 / 季 / 合集
            makeItem(id: "episode-1", name: "某集", kind: .episode, primaryImageTag: "t3"),
            makeItem(id: "season-1", name: "某季", kind: .season, primaryImageTag: "t4"),
            makeItem(id: "boxset-1", name: "合集", kind: .boxSet, primaryImageTag: "t5"),
            // 是条目但没图：上墙只会占个空位
            makeItem(id: "movie-2", name: "电影没图", kind: .movie),
        ], tenant: tenant)

        let candidates = try await store.posterCandidates(tenant: tenant, limit: 50)
        #expect(Set(candidates.map(\.item.id)) == ["movie-1", "series-1"])
    }

    /// 标题与年份要带出来：它们既是无障碍标签，也是程序化封面的素材。
    @Test func candidatesCarryTitleAndYear() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }

        try await store.saveItems([
            makeItem(id: "movie-1", name: "药屋少女的呢喃", kind: .movie, year: 2023,
                     primaryImageTag: "t1"),
        ], tenant: tenant)

        let candidates = try await store.posterCandidates(tenant: tenant, limit: 10)
        let item = try #require(candidates.first?.item)
        #expect(item.name == "药屋少女的呢喃")
        #expect(item.year == 2023)
        #expect(item.primaryImageTag == "t1")
    }

    /// `limit` 是硬上限：墙只要几十张，不该把整个库拖回来。
    @Test func limitIsRespected() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }

        let items = (0..<40).map { index in
            makeItem(id: "movie-\(index)", name: "片 \(index)", kind: .movie, primaryImageTag: "t\(index)")
        }
        try await store.saveItems(items, tenant: tenant)

        #expect(try await store.posterCandidates(tenant: tenant, limit: 7).count == 7)
        #expect(try await store.posterCandidates(tenant: tenant, limit: 0).isEmpty)
        #expect(try await store.posterCandidates(tenant: tenant, limit: -3).isEmpty)
    }

    /// **顺序确定**：同一份缓存两次装配必须得到同一面墙，否则每次冷启动墙都换一副
    /// 面孔（而「换了一副面孔」在装饰性背景上没人会当成 bug 报上来）。
    @Test func orderIsDeterministicAcrossCalls() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }

        let items = (0..<20).map { index in
            makeItem(id: "movie-\(index)", name: "片 \(index)", kind: .movie, primaryImageTag: "t\(index)")
        }
        try await store.saveItems(items, tenant: tenant)

        let first = try await store.posterCandidates(tenant: tenant, limit: 10).map(\.item.id)
        let second = try await store.posterCandidates(tenant: tenant, limit: 10).map(\.item.id)
        #expect(first == second)
        #expect(first.count == 10)
    }

    /// 别的租户的条目不上墙：条目 id 只在那台服务器里有意义。
    @Test func otherTenantsAreInvisible() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        let other = TenantID(rawValue: "other:user")

        try await store.saveItems([
            makeItem(id: "mine", name: "我的", kind: .movie, primaryImageTag: "t1"),
        ], tenant: tenant)
        try await store.saveItems([
            makeItem(id: "theirs", name: "别人的", kind: .movie, primaryImageTag: "t2"),
        ], tenant: other)

        #expect(try await store.posterCandidates(tenant: tenant, limit: 50).map(\.item.id) == ["mine"])
        #expect(try await store.posterCandidates(tenant: other, limit: 50).map(\.item.id) == ["theirs"])
    }

    /// 空库返回空数组，不抛不崩（首次安装就是这样）。
    @Test func emptyStoreYieldsNothing() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }
        #expect(try await store.posterCandidates(tenant: tenant, limit: 50).isEmpty)
    }

    /// 「无图条目」占比很高时仍要凑得满：扫描窗口给了余量（`limit * 8`，至少 240 行）。
    ///
    /// 这条挡的是一个很隐蔽的失败——窗口太小时，库里前面几百条恰好都没图，
    /// 墙就会**莫名其妙地只有几张**，而代码没有任何报错。
    @Test func scanWindowSkipsPosterlessItems() async throws {
        let (store, tenant, dir) = try await makeStore()
        defer { dir.cleanUp() }

        // 300 条无图条目排在前面，后面才有 20 条有图的。
        var items = (0..<300).map { index in
            makeItem(id: "bare-\(index)", name: "无图 \(index)", kind: .movie)
        }
        items += (0..<20).map { index in
            makeItem(id: "art-\(index)", name: "有图 \(index)", kind: .movie, primaryImageTag: "t\(index)")
        }
        try await store.saveItems(items, tenant: tenant)

        let candidates = try await store.posterCandidates(tenant: tenant, limit: 20)
        #expect(candidates.count == 20, "扫描窗口没给够余量，墙会莫名变空")
        #expect(candidates.allSatisfy { $0.item.id.hasPrefix("art-") })
    }
}
