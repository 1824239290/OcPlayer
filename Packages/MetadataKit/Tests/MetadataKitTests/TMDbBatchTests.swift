import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 批量补全与手动匹配。
final class TMDbBatchTests: XCTestCase {

    private var dir: TemporaryDirectory!
    private var store: MetadataStore!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        store = MetadataStore(database: try MetadataDatabaseFactory.makeDatabase(at: dir.url))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        dir?.cleanUp()
        super.tearDown()
    }

    private var tenant: TenantID { TenantID(rawValue: "srv:user") }

    private func makeEnricher(
        routes: @escaping (String) -> (Int, Data)
    ) -> TMDbEnricher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { request in routes(request.url?.path ?? "") }
        let defaults = UserDefaults(suiteName: "TMDbBatchTests-\(UUID().uuidString)")!
        let client = TMDbClient(
            session: URLSession(configuration: config),
            credentials: BatchCredential(key: "0123456789abcdef0123456789abcdef"),
            limiter: TMDbRateLimiter(maxConcurrent: 1, minimumInterval: 0))
        return TMDbEnricher(client: client, store: store,
                            preferences: TMDbPreferences(defaults: defaults))
    }

    private func movie(_ id: String, name: String = "某片", tmdbID: String? = nil) -> MediaItem {
        var item = MediaItem(id: id, name: name, kind: .movie)
        item.tmdbID = tmdbID
        return item
    }

    // MARK: - 基本流程

    /// 逐条补全：新条目计数进 `enriched`，进度按条汇报且最终收尾。
    func testEnrichesAllAndReportsProgress() async throws {
        let enricher = makeEnricher { path in
            path.hasSuffix("/movie/603") ? (200, Self.movieJSON) : (404, Data())
        }
        let items = [movie("m1", name: "黑客帝国", tmdbID: "603")]

        let recorder = ProgressRecorder()
        let result = await enricher.enrichAll(items: items, tenant: tenant) { progress in
            recorder.append(progress)
        }

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.enriched, 1)
        XCTAssertEqual(result.unmatched, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(result.wasCancelled)

        let snapshots = recorder.values
        XCTAssertGreaterThanOrEqual(snapshots.count, 2, "至少要有初始与收尾两次")
        XCTAssertEqual(snapshots.first?.completed, 0)
        XCTAssertEqual(snapshots.last?.completed, 1)
        XCTAssertNil(snapshots.last?.currentTitle, "收尾不应还挂着标题")
        XCTAssertEqual(snapshots.last?.fraction, 1.0)
    }

    /// **天然可续**：第二次跑时已有且未过期的条目直接跳过，且**不再发请求**。
    func testSecondRunSkipsFreshItemsWithoutNetwork() async throws {
        let counter = CallCounter()
        let enricher = makeEnricher { path in
            if path.hasSuffix("/movie/603") { counter.increment() }
            return (200, Self.movieJSON)
        }
        let items = [movie("m1", name: "黑客联盟", tmdbID: "603")]

        let first = await enricher.enrichAll(items: items, tenant: tenant)
        XCTAssertEqual(first.enriched, 1)
        XCTAssertEqual(counter.value, 1)

        let second = await enricher.enrichAll(items: items, tenant: tenant)
        XCTAssertEqual(second.skipped, 1, "第二次应跳过")
        XCTAssertEqual(second.enriched, 0)
        XCTAssertEqual(counter.value, 1, "第二次不该再打请求（可续性的核心）")
    }

    /// 单条失败**不影响**其它条目继续。
    func testOneFailureDoesNotStopTheRest() async throws {
        let enricher = makeEnricher { path in
            // ⚠️ 夹具的 `id` 必须与查询键一致：`saveTMDbPayload` 会校验载荷与键匹配
            // （`TMDbEntityPayload.matches`），拿 id=603 的 JSON 去回答 `/movie/2`
            // 会被当作未命中——这是**正确**的守卫，不是 bug。
            if path.hasSuffix("/movie/1") { return (500, Data()) }            // 拉取失败
            if path.hasSuffix("/movie/603") { return (200, Self.movieJSON) }  // 成功
            return (404, Data())                                             // 实体不存在
        }
        let items = [movie("a", tmdbID: "1"), movie("b", tmdbID: "603"),
                     movie("c", tmdbID: "3")]

        let result = await enricher.enrichAll(items: items, tenant: tenant)

        XCTAssertEqual(result.processed, 3, "三条都要处理到（一条失败不该中断其余）")
        XCTAssertEqual(result.failed, 2, "500 与 404 都算失败")
        XCTAssertEqual(result.enriched, 1, "中间那条要成功")
    }

    /// 非电影/剧（合集、音乐…）被跳过但计入 `processed`——TMDb 的 movie/tv 端点不适用。
    func testNonVideoKindsAreSkippedButCounted() async throws {
        var requests = 0
        let enricher = makeEnricher { _ in requests += 1; return (200, Self.movieJSON) }
        var boxSet = MediaItem(id: "b1", name: "合集", kind: .boxSet)
        boxSet.tmdbID = "999"
        var album = MediaItem(id: "a1", name: "专辑", kind: .musicAlbum)
        album.tmdbID = "888"

        let result = await enricher.enrichAll(items: [boxSet, album], tenant: tenant)

        XCTAssertEqual(result.processed, 2)
        XCTAssertEqual(result.enriched, 0)
        XCTAssertEqual(requests, 0, "不该为它们发任何请求")
    }

    /// 空列表：直接返回，不发请求、不崩。
    func testEmptyListIsNoOp() async throws {
        var requests = 0
        let enricher = makeEnricher { _ in requests += 1; return (200, Self.movieJSON) }
        let result = await enricher.enrichAll(items: [], tenant: tenant)
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(result.progress.fraction, 1.0, "没有活要干时进度视为完成")
    }

    // MARK: - 剧集连季一起拉

    /// **剧集要把它各季也拉了**：季数据决定分集标题/剧照/切季简介，只拉剧集本身的话，
    /// 那些展示面在没访问过的剧集上仍然是空的——而批量补全的意义正是「不用一个个点开」。
    func testSeriesAlsoFetchesItsSeasons() async throws {
        var requested: [String] = []
        let enricher = makeEnricher { path in
            requested.append(path)
            if path.hasSuffix("/tv/71785") { return (200, Self.tvWithSeasonsJSON) }
            // 季 JSON 的 `season_number` 必须与查询的季号一致，否则会被匹配守卫拦下
            if path.contains("/season/1") { return (200, Self.seasonJSON) }
            if path.contains("/season/2") { return (200, Self.season2JSON) }
            return (404, Data())
        }
        var show = MediaItem(id: "s1", name: "阿松", kind: .series)
        show.tmdbID = "71785"

        let result = await enricher.enrichAll(items: [show], tenant: tenant)

        XCTAssertEqual(result.enriched, 1)
        XCTAssertEqual(result.seasons, 2, "该剧有 2 季，都应被拉取")
        XCTAssertTrue(requested.contains { $0.contains("/season/1") })
        XCTAssertTrue(requested.contains { $0.contains("/season/2") })
        // 季数据确实落库了
        let s1 = try await store.tmdbPayload(key: .season(tvID: 71785, number: 1), language: "zh-CN")
        XCTAssertNotNil(s1)
    }

    /// 电影不该去找季（它没有季端点）。
    func testMovieDoesNotFetchSeasons() async throws {
        var requested: [String] = []
        let enricher = makeEnricher { path in
            requested.append(path)
            return (200, Self.movieJSON)
        }
        _ = await enricher.enrichAll(items: [movie("m1", tmdbID: "603")], tenant: tenant)
        XCTAssertFalse(requested.contains { $0.contains("/season/") })
    }

    // MARK: - 取消

    /// 取消后：**已处理的都已落库**（可续），未处理的跳过，`wasCancelled` 为真。
    func testCancellationKeepsWhatWasDone() async throws {
        // stub 必须**慢**：内存打桩 40 条会在几毫秒内跑完，根本来不及取消
        // （第一版就是这么失败的：`processed == 40`、`wasCancelled == false`）。
        let enricher = makeEnricher { path in
            usleep(4_000)
            if path.hasSuffix("/movie/603") { return (200, Self.movieJSON) }
            return (404, Data())
        }
        let items = (0..<40).map { movie("m\($0)", name: "片\($0)", tmdbID: "603") }

        // `tenant` 是**计算属性**（读 `self`）：直接写进 Task 闭包会让闭包捕获测试类
        // 实例，而它非 Sendable → 编译期数据竞争报错。先取成局部值再捕获。
        let tenantID = tenant
        let total = items.count
        let task = Task { await enricher.enrichAll(items: items, tenant: tenantID) }
        // 让第一条先跑完再取消
        try? await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(result.processed, total, "应中途停下")
        // 已处理的条目要留下痕迹（同一部电影 → 同一条对应）
        let link = try await store.tmdbLink(itemID: "m0", tenant: tenant)
        XCTAssertNotNil(link, "取消不该丢掉已完成的部分")
    }

    // MARK: - 手动匹配

    /// 手动绑定：写入 `source: .manual`（**不会被自动匹配覆盖**）并立刻拉数据。
    func testManualBindFetchesImmediately() async throws {
        // 用 JSON 里真实的 id（71785）当键——载荷与键必须一致。
        let enricher = makeEnricher { path in
            if path.hasSuffix("/tv/71785") { return (200, Self.tvWithSeasonsJSON) }
            return (200, Self.seasonJSON)
        }
        let didFetch = await enricher.bindManually(itemID: "s1", entityKey: .tv(71785),
                                                   tenant: tenant)
        XCTAssertTrue(didFetch)

        let link = try await store.tmdbLink(itemID: "s1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .tv(71785))
        XCTAssertEqual(link?.source, .manual)
        XCTAssertEqual(link?.confidence, 1.0)
        XCTAssertEqual(link?.source.isAuthoritative, true)

        let overlay = await enricher.overlay(
            for: MediaItem(id: "s1", name: "x", kind: .series), tenant: tenant)
        XCTAssertNotNil(overlay, "绑定后应立刻有数据可展示")
    }

    /// 手动绑定的对应**不会被后来的自动匹配顶掉**（哪怕服务端有另一个 ProviderIds）。
    func testManualBindSurvivesAutoMatch() async throws {
        let enricher = makeEnricher { _ in (200, Self.tvWithSeasonsJSON) }
        _ = await enricher.bindManually(itemID: "s1", entityKey: .tv(71785), tenant: tenant)

        var show = MediaItem(id: "s1", name: "阿松", kind: .series)
        show.tmdbID = "71785"      // 服务端给的是另一个 id
        _ = await enricher.refresh(item: show, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "s1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .tv(71785), "用户手动选的不该被自动匹配覆盖")
        XCTAssertEqual(link?.source, .manual)
    }

    /// 解除绑定后：对应没了，overlay 也没了。
    func testUnbindClearsLink() async throws {
        let enricher = makeEnricher { _ in (200, Self.movieJSON) }
        _ = await enricher.bindManually(itemID: "m1", entityKey: .movie(603), tenant: tenant)
        let before = await enricher.overlay(for: movie("m1"), tenant: tenant)
        XCTAssertNotNil(before)

        await enricher.unbind(itemID: "m1", tenant: tenant)

        let linkAfter = try await store.tmdbLink(itemID: "m1", tenant: tenant)
        XCTAssertNil(linkAfter)
        let after = await enricher.overlay(for: movie("m1"), tenant: tenant)
        XCTAssertNil(after)
    }

    /// 手动搜索：空串不请求；有结果原样返回；失败**要抛错**（与自动补全不同——
    /// 用户主动发起时，「没搜到」与「搜索失败」必须区分）。
    func testManualSearch() async throws {
        var requests = 0
        let enricher = makeEnricher { _ in
            requests += 1
            return (200, Self.searchJSON)
        }
        let empty = try await enricher.searchCandidates(query: "   ", mediaType: .movie)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(requests, 0, "空串不该发请求")

        let results = try await enricher.searchCandidates(query: "matrix", mediaType: .movie)
        XCTAssertEqual(results.map(\.id), [603])
        XCTAssertEqual(requests, 1)

        let failing = makeEnricher { _ in (500, Data()) }
        do {
            _ = try await failing.searchCandidates(query: "x", mediaType: .movie)
            XCTFail("应抛错")
        } catch {
            // 期望：错误上抛给 UI
        }
    }

    /// 批量补全**不该**吞掉「未配置 key」：直接返回全零，不发请求。
    func testBatchWithoutKeyIsNoOp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var requests = 0
        StubProtocol.handler = { _ in requests += 1; return (200, Self.movieJSON) }
        let client = TMDbClient(
            session: URLSession(configuration: config),
            credentials: BatchCredential(key: nil),
            limiter: TMDbRateLimiter(maxConcurrent: 1, minimumInterval: 0))
        let defaults = UserDefaults(suiteName: "TMDbBatchTests-\(UUID().uuidString)")!
        let enricher = TMDbEnricher(client: client, store: store,
                                    preferences: TMDbPreferences(defaults: defaults))

        let result = await enricher.enrichAll(
            items: [movie("m1", tmdbID: "603")], tenant: tenant)
        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(requests, 0)
    }

    // MARK: - 样例

    static let movieJSON = Data(#"""
    {"id":603,"title":"黑客帝国","overview":"简介","poster_path":"/p.jpg",
     "genres":[{"id":28,"name":"动作"}]}
    """#.utf8)

    static let tvWithSeasonsJSON = Data(#"""
    {"id":71785,"name":"阿松","overview":"六胞胎","poster_path":"/o.jpg",
     "seasons":[{"season_number":1,"name":"第 1 季","episode_count":25},
                {"season_number":2,"name":"第 2 季","episode_count":25}]}
    """#.utf8)

    static let seasonJSON = Data(#"""
    {"season_number":1,"name":"第 1 季","overview":"季简介",
     "episodes":[{"episode_number":1,"name":"第一集","still_path":"/s.jpg"}]}
    """#.utf8)

    static let season2JSON = Data(#"""
    {"season_number":2,"name":"第 2 季","overview":"第二季简介",
     "episodes":[{"episode_number":1,"name":"第一集","still_path":"/s2.jpg"}]}
    """#.utf8)

    static let searchJSON = Data(#"""
    {"results":[{"id":603,"title":"黑客帝国","release_date":"1999-03-31","popularity":50.0}]}
    """#.utf8)
}

private struct BatchCredential: TMDbCredentialProviding {
    let key: String?
    func apiKey() -> String? { key }
}

/// 收集进度回调（handler 是同步闭包，用锁而非 actor）。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TMDbBatchProgress] = []
    var values: [TMDbBatchProgress] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ value: TMDbBatchProgress) { lock.lock(); items.append(value); lock.unlock() }
}
