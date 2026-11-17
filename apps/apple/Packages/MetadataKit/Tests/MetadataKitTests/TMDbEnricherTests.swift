import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 补全服务：匹配 → 拉取 → 落库 → 只读叠加，端到端（真 SQLite + 挡掉的网络）。
final class TMDbEnricherTests: XCTestCase {

    private var dir: TemporaryDirectory!
    private var store: MetadataStore!

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        store = MetadataStore(database: try MetadataDatabaseFactory.makeDatabase(at: dir.url))
    }

    override func tearDown() {
        dir?.cleanUp()
        super.tearDown()
    }

    private var tenant: TenantID { TenantID(rawValue: "srv:user") }

    /// 造一个补全服务。`routes` 按请求路径给响应。
    private func makeEnricher(
        apiKey: String? = "0123456789abcdef0123456789abcdef",
        language: String = "zh-CN",
        cacheDays: Int? = nil,
        routes: @escaping (String) -> (Int, Data)
    ) -> TMDbEnricher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { request in routes(request.url?.path ?? "") }
        let defaults = UserDefaults(suiteName: "TMDbEnricherTests-\(UUID().uuidString)")!
        let prefs = TMDbPreferences(defaults: defaults)
        prefs.language = language
        if let cacheDays { prefs.cacheDays = cacheDays }
        let client = TMDbClient(
            session: URLSession(configuration: config),
            credentials: StubEnricherCredential(key: apiKey),
            limiter: TMDbRateLimiter(maxConcurrent: 1, minimumInterval: 0))
        return TMDbEnricher(client: client, store: store, preferences: prefs)
    }

    override func tearDownWithError() throws {
        StubProtocol.handler = nil
    }

    // MARK: - 直连 ProviderIds

    /// 有 `ProviderIds["Tmdb"]` 时：**不搜索**，直接拉详情并落库。
    func testProviderIDPathSkipsSearchAndStores() async throws {
        var requestedPaths: [String] = []
        let enricher = makeEnricher { path in
            requestedPaths.append(path)
            if path.hasSuffix("/movie/603") { return (200, Self.movieJSON) }
            return (404, Data())
        }
        let movie = makeItem(id: "m1", name: "黑客帝国", kind: .movie, tmdbID: "603")

        let didFetch = await enricher.refresh(item: movie, tenant: tenant)
        XCTAssertTrue(didFetch)
        XCTAssertEqual(requestedPaths.count, 1, "不该有搜索请求")
        XCTAssertTrue(requestedPaths[0].hasSuffix("/movie/603"))

        // 落库了对应关系
        let link = try await store.tmdbLink(itemID: "m1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .movie(603))
        XCTAssertEqual(link?.source, .providerID)
        XCTAssertEqual(link?.confidence, 1.0)

        // 只读路径能拿到叠加数据
        let overlay = await enricher.overlay(for: movie, tenant: tenant)
        XCTAssertEqual(overlay?.title, "黑客帝国")
        XCTAssertEqual(overlay?.posterPath, "/poster.jpg")
    }

    /// 测试夹具里的日期会变，所以断言用固定 JSON。
    func testOverlaySkipsAlreadyFreshData() async throws {
        var calls = 0
        let enricher = makeEnricher { _ in
            calls += 1
            return (200, Self.movieJSON)
        }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")

        await enricher.refresh(item: movie, tenant: tenant)
        XCTAssertEqual(calls, 1)
        // 第二次：数据未过期 → 不该再打网络
        let again = await enricher.refresh(item: movie, tenant: tenant)
        XCTAssertFalse(again, "未过期不该回源")
        XCTAssertEqual(calls, 1, "第二次不该发请求")
    }

    /// 数据过期后应回源。
    func testOverlayRefreshesExpiredData() async throws {
        var calls = 0
        // lifetime 0 秒 → 立刻过期
        let enricher = makeEnricher(cacheDays: 1) { _ in
            calls += 1
            return (200, Self.movieJSON)
        }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")
        await enricher.refresh(item: movie, tenant: tenant)

        // 手工把过期时间改到过去
        try await store.saveTMDbPayload(.entity(TMDbEntity(id: 603, mediaType: .movie)),
                                       key: .movie(603), language: "zh-CN", lifetime: -10)

        let didFetch = await enricher.refresh(item: movie, tenant: tenant)
        XCTAssertTrue(didFetch, "过期后应回源")
        XCTAssertEqual(calls, 2)
    }

    // MARK: - 搜索路径

    /// 没有 ProviderIds → 走搜索；匹配够可信才落库。
    func testSearchPathStoresWhenConfident() async throws {
        let enricher = makeEnricher { path in
            if path.contains("/search/tv") { return (200, Self.searchTVJSON) }
            if path.hasSuffix("/tv/71785") { return (200, Self.tvJSON) }
            return (404, Data())
        }
        let show = makeItem(id: "s1", name: "阿松", kind: .series, year: 2015)

        await enricher.refresh(item: show, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "s1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .tv(71785))
        XCTAssertEqual(link?.source, .search)
        XCTAssertTrue((link?.confidence ?? 0) >= 0.85, "只落可信匹配")
    }

    /// 匹配不可信（标题不相干）→ **不落库**、不拉详情（留给手动面板）。
    func testSearchPathSkipsWhenNotConfident() async throws {
        var requestedPaths: [String] = []
        let enricher = makeEnricher { path in
            requestedPaths.append(path)
            // 搜索返回一个完全无关的片子
            if path.contains("/search/") { return (200, Self.unrelatedSearchJSON) }
            return (200, Self.movieJSON)
        }
        let movie = makeItem(id: "m1", name: "黑客帝国", kind: .movie, year: 1999)

        await enricher.refresh(item: movie, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "m1", tenant: tenant)
        XCTAssertNil(link, "不可信的匹配不该落库")
        XCTAssertFalse(requestedPaths.contains { $0.contains("/movie/") && !$0.contains("search") },
                       "不该去拉详情")
    }

    // MARK: - 集 / 季

    /// 集：从**父剧对应**推导，且拉的是**整季**（一次请求拿全季，不是每集一次）。
    func testEpisodeUsesSeriesLinkAndFetchesSeasonOnce() async throws {
        var requestedPaths: [String] = []
        let enricher = makeEnricher { path in
            requestedPaths.append(path)
            if path.contains("/season/1") { return (200, Self.seasonJSON) }
            if path.hasSuffix("/tv/153217") { return (200, Self.tvJSON) }
            return (404, Data())
        }
        // 先建立父剧的对应
        try await store.saveTMDbLink(itemID: "series-1", entityKey: .tv(153217),
                                     source: .providerID, confidence: 1.0, tenant: tenant)
        let seriesLink = TMDbLink(itemID: "series-1", entityKey: .tv(153217),
                                  source: .providerID, confidence: 1.0, linkedAt: Date())

        let episode = makeItem(id: "e1", name: "电气少年", kind: .episode,
                               seriesID: "series-1", seasonNumber: 1, episodeNumber: 1,
                               tmdbID: "3384539")
        await enricher.refresh(item: episode, tenant: tenant, seriesLink: seriesLink)

        // 应拉的是季端点，且**没有**用集自己的 tmdbID 去打 /tv/3384539
        XCTAssertTrue(requestedPaths.contains { $0.contains("/season/1") },
                      "应拉整季，实际: \(requestedPaths)")
        XCTAssertFalse(requestedPaths.contains { $0.contains("3384539") },
                       "绝不能拿单集 id 当剧集 id 用")

        let link = try await store.tmdbLink(itemID: "e1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .season(tvID: 153217, number: 1))

        // overlay 应给出季的简介
        let overlay = await enricher.overlay(for: episode, tenant: tenant)
        XCTAssertEqual(overlay?.overview, "第一季简介")
        XCTAssertEqual(overlay?.posterPath, "/s1.jpg")
    }

    /// 没有父剧对应 → 集什么也不做（不去搜分集名）。
    func testEpisodeWithoutSeriesLinkDoesNothing() async throws {
        var requested = 0
        let enricher = makeEnricher { _ in
            requested += 1
            return (200, Self.seasonJSON)
        }
        let episode = makeItem(id: "e1", name: "电气少年", kind: .episode,
                              seriesID: "series-1", seasonNumber: 1)
        await enricher.refresh(item: episode, tenant: tenant, seriesLink: nil)
        XCTAssertEqual(requested, 0, "没有父剧对应时不该发任何请求")
    }

    // MARK: - 权威来源优先

    /// 当初靠**标题搜索猜**的对应，在服务端后来补上 `ProviderIds["Tmdb"]` 之后
    /// 应该改用权威的那个——否则会永远抱着一个猜出来的 id。
    func testAuthoritativeProviderIDReplacesSearchGuess() async throws {
        var requested: [String] = []
        let enricher = makeEnricher { path in
            requested.append(path)
            if path.hasSuffix("/tv/153217") { return (200, Self.tvJSON) }
            return (200, Self.searchTVJSON)
        }
        // 先造一条「搜索猜出来」的旧对应
        try await store.saveTMDbLink(itemID: "s1", entityKey: .tv(999),
                                     source: .search, confidence: 0.9, tenant: tenant)

        // 服务端现在给了 Tmdb id
        let show = makeItem(id: "s1", name: "某剧", kind: .series, year: 2020, tmdbID: "153217")
        await enricher.refresh(item: show, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "s1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .tv(153217), "应改用服务端的权威 id")
        XCTAssertEqual(link?.source, .providerID)
        XCTAssertTrue(requested.contains { $0.hasSuffix("/tv/153217") })
    }

    /// 权威对应（providerID / manual）**不该**被自动匹配顶掉。
    func testAuthoritativeLinkIsNeverOverwritten() async throws {
        var requested: [String] = []
        let enricher = makeEnricher { path in
            requested.append(path)
            if path.hasSuffix("/tv/241535") { return (200, Self.tvJSON) }
            return (200, Self.searchTVJSON)
        }
        try await store.saveTMDbLink(itemID: "s1", entityKey: .tv(241535),
                                     source: .providerID, confidence: 1.0, tenant: tenant)

        // 即便服务端的 ProviderIds 指向另一个 id，也不该改写已建立的权威对应
        let show = makeItem(id: "s1", name: "某剧", kind: .series, year: 2020, tmdbID: "153217")
        await enricher.refresh(item: show, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "s1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .tv(241535), "权威对应保持不动")
    }

    /// **集/季的 `tmdbID` 是单集 id，不能当作权威剧集 id**。
    func testEpisodeTmdbIDIsNotTreatedAsAuthoritative() async throws {
        let enricher = makeEnricher { path in
            path.contains("/season/") ? (200, Self.seasonJSON) : (404, Data())
        }
        try await store.saveTMDbLink(itemID: "e1", entityKey: .season(tvID: 153217, number: 1),
                                     source: .search, confidence: 0.9, tenant: tenant)
        // 集带一个「单集 id」，若被当成剧集 id 就会去查 /tv/3384539
        let episode = makeItem(id: "e1", name: "电气少年", kind: .episode,
                               seriesID: "s1", seasonNumber: 1, episodeNumber: 1,
                               tmdbID: "3384539")
        await enricher.refresh(item: episode, tenant: tenant)

        let link = try await store.tmdbLink(itemID: "e1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .season(tvID: 153217, number: 1), "不该被单集 id 改写")
    }

    // MARK: - 失败可见

    /// 坏 key 必须**留下可读原因**（原先完全静默：用户填了 key 却什么都没发生）。
    func testUnauthorizedIsRecordedAsFailure() async throws {
        let enricher = makeEnricher { _ in (401, Data()) }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")
        await enricher.refresh(item: movie, tenant: tenant)
        let failure = await enricher.reportedFailure()
        XCTAssertEqual(failure, .unauthorized)
    }

    /// 成功之后要清掉上一次的失败（提示反映的是「最近一次」，不是历史账本）。
    func testSuccessClearsPreviousFailure() async throws {
        var unauthorized = true
        let enricher = makeEnricher { _ in
            unauthorized ? (401, Data()) : (200, Self.movieJSON)
        }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")
        await enricher.refresh(item: movie, tenant: tenant)
        var failure = await enricher.reportedFailure()
        XCTAssertEqual(failure, .unauthorized)

        unauthorized = false
        // 让数据过期以触发重拉
        try await store.saveTMDbPayload(.entity(TMDbEntity(id: 603, mediaType: .movie)),
                                       key: .movie(603), language: "zh-CN", lifetime: -10)
        await enricher.refresh(item: movie, tenant: tenant)
        failure = await enricher.reportedFailure()
        XCTAssertNil(failure, "成功之后应清空")
    }

    // MARK: - 季数据（剧集页用）

    /// 季数据靠「父剧 link + 季号」定位（季没有自己的对应关系），
    /// 取到后要能给出该季每一集的标题/简介。
    func testSeasonOverlayProvidesEpisodeData() async throws {
        let enricher = makeEnricher { path in
            if path.contains("/season/2") { return (200, Self.season2JSON) }
            return (404, Data())
        }
        let seriesLink = TMDbLink(itemID: "series", entityKey: .tv(60730),
                                  source: .providerID, confidence: 1.0, linkedAt: Date())

        // 拉之前读不到
        let before = await enricher.seasonOverlay(seriesLink: seriesLink, seasonNumber: 2)
        XCTAssertNil(before, "没缓存过时应为 nil")

        let didFetch = await enricher.refreshSeason(seriesLink: seriesLink, seasonNumber: 2)
        XCTAssertTrue(didFetch)

        let overlay = await enricher.seasonOverlay(seriesLink: seriesLink, seasonNumber: 2)
        let season = try XCTUnwrap(overlay)
        XCTAssertEqual(season.overview, "第二季简介")
        XCTAssertEqual(season.episodes.count, 2)
        // 分集标题：占位名被 TMDB 顶掉
        XCTAssertEqual(season.displayEpisodeTitle(number: 9, serverValue: "第 9 集",
                                                  preferTMDb: false), "离别之时")
        XCTAssertEqual(season.displayEpisodeTitle(number: 1, serverValue: "服务端标题",
                                                  preferTMDb: true), "第一集")
    }

    /// 已有且未过期时不该回源（切季是高频操作，不能每次都打网络）。
    func testSeasonRefreshSkipsFreshData() async throws {
        let counter = CallCounter()
        let enricher = makeEnricher { path in
            if path.contains("/season/") { counter.increment() }
            return (200, Self.season2JSON)
        }
        let link = TMDbLink(itemID: "series", entityKey: .tv(60730),
                            source: .providerID, confidence: 1.0, linkedAt: Date())

        _ = await enricher.refreshSeason(seriesLink: link, seasonNumber: 2)
        XCTAssertEqual(counter.value, 1)
        let again = await enricher.refreshSeason(seriesLink: link, seasonNumber: 2)
        XCTAssertFalse(again, "未过期不该回源")
        XCTAssertEqual(counter.value, 1)
    }

    /// 在播判定：未定档/解析不出的日期 = 未知 = 在播；有未播集（含恰为今天）在播；
    /// 季终宽限期内（最后一集播出后 `airingGraceDays` 天）在播；全部播出且超宽限
    /// 才定型；空季 = 数据不全 = 在播。日期一律走 `TMDbAirDate.parse` 口径（本地
    /// 时区），坏日期不能按字典序误判。
    func testSeasonAiringDetection() {
        func season(_ episodes: [EpisodeEntry]) -> TMDbSeason {
            TMDbSeason(seasonNumber: 1, episodes: episodes)
        }
        // 还有未来集
        XCTAssertTrue(season([EpisodeEntry(episodeNumber: 1, airDate: dayString(-30)),
                              EpisodeEntry(episodeNumber: 2, airDate: dayString(7))]).isAiring)
        // 恰为今天（当晚才播）= 未播
        XCTAssertTrue(season([EpisodeEntry(episodeNumber: 1, airDate: dayString(0))]).isAiring)
        // 未定档（nil）= 未知 = 在播
        XCTAssertTrue(season([EpisodeEntry(episodeNumber: 1, airDate: dayString(-30)),
                              EpisodeEntry(episodeNumber: 2, airDate: nil)]).isAiring)
        // 解析不出的坏日期（TMDbAirDate 口径）= 未知 = 在播，不许按字典序误判
        XCTAssertTrue(season([EpisodeEntry(episodeNumber: 1, airDate: "2026-13-45")]).isAiring)
        // 季终宽限：最后一集昨天播出 → 仍在播（翻译补齐的尾巴期）
        XCTAssertTrue(season([EpisodeEntry(episodeNumber: 1, airDate: dayString(-30)),
                              EpisodeEntry(episodeNumber: 2, airDate: dayString(-1))]).isAiring)
        // 全部已播且超宽限 = 定型
        XCTAssertFalse(season([EpisodeEntry(episodeNumber: 1, airDate: "2020-01-01"),
                               EpisodeEntry(episodeNumber: 2, airDate: "2020-03-31")]).isAiring)
        // 最后一集播出时间刚过宽限天数 → 定型
        XCTAssertFalse(season([EpisodeEntry(
            episodeNumber: 1,
            airDate: dayString(-(TMDbSeason.airingGraceDays + 1)))]).isAiring)
        // 空季 = 数据不全 = 在播
        XCTAssertTrue(season([]).isAiring)
    }

    /// 本地时区口径的「N 天后」日期串（与 `TMDbAirDate.parse` 的解析口径对称）。
    private func dayString(_ offsetDays: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date())!
        return formatter.string(from: day)
    }

    /// 共享新鲜判据 `isFresh`：在播季按 fetchedAt 的回源窗口判（**与落库的
    /// expires_at 解耦**——审查抓出来的坑：把 expires_at 缩成 1 天会被每日维护
    /// 当死数据删掉）；完结季/非季载荷只看 expires_at。
    func testFreshnessJudgement() {
        let day = 24 * 60 * 60.0
        func cached(_ payload: TMDbEntityPayload, fetchedAgo: TimeInterval,
                    expiresIn: TimeInterval) -> CachedTMDbPayload {
            CachedTMDbPayload(payload: payload,
                              fetchedAt: Date().addingTimeInterval(-fetchedAgo),
                              expiresAt: Date().addingTimeInterval(expiresIn))
        }
        let airing = TMDbEntityPayload.season(TMDbSeason(seasonNumber: 1, episodes: [
            EpisodeEntry(episodeNumber: 1, airDate: "2999-12-31")]))
        let finished = TMDbEntityPayload.season(TMDbSeason(seasonNumber: 2, episodes: [
            EpisodeEntry(episodeNumber: 1, airDate: "2020-01-01"),
            EpisodeEntry(episodeNumber: 2, airDate: "2020-03-31")]))
        // 在播 + 拉取时间超窗 → 不新鲜（旧长缓存也要回源）
        XCTAssertFalse(TMDbEnricher.isFresh(cached(airing, fetchedAgo: 10 * day, expiresIn: 90 * day)),
                       "在播季超窗应回源，哪怕 expires_at 还远")
        // 在播 + 窗口内 → 新鲜（窗口内不重复请求）
        XCTAssertTrue(TMDbEnricher.isFresh(cached(airing, fetchedAgo: 0.5 * day, expiresIn: 90 * day)))
        // 完结季：只看 expires_at——fetchedAt 再旧也不提前回源，超期才回源
        XCTAssertTrue(TMDbEnricher.isFresh(cached(finished, fetchedAgo: 10 * day, expiresIn: 90 * day)))
        XCTAssertFalse(TMDbEnricher.isFresh(cached(finished, fetchedAgo: 10 * day, expiresIn: -day)))
    }

    /// 在播季落库的 expires_at 也写**常规期**：「按天回源」由读侧 `isFresh`（按
    /// fetchedAt）实现。若把 expires_at 缩成 1 天，每日存储维护会按它物理删行，
    /// 在播季数据被清掉后离线/先读后补就拿不到任何叠加数据了。
    func testAiringSeasonStoresRegularExpiry() async throws {
        let enricher = makeEnricher { path in
            path.contains("/season/") ? (200, Self.airingSeasonJSON) : (404, Data())
        }
        let key = TMDbEntityKey.season(tvID: 100, number: 1)
        try await enricher.fetchAndStore(key: key)
        let stored = try await store.tmdbPayload(key: key, language: "zh-CN")
        let cached = try XCTUnwrap(stored)
        let span = cached.expiresAt.timeIntervalSince(cached.fetchedAt)
        XCTAssertEqual(span, TimeInterval(90 * 24 * 60 * 60), accuracy: 5,
                       "在播季也应写常规缓存期（默认 90 天），不是 1 天")
    }

    /// 旧版本写下的**长缓存**在播季：拉取时间超过在播窗口后仍要回源。
    /// 这是救活存量——修复前落库的 expires_at 写到几个月后，只看它永不刷新。
    func testStaleAiringSeasonWithLongCacheStillRefetches() async throws {
        let counter = CallCounter()
        let enricher = makeEnricher { _ in
            counter.increment()
            return (200, Self.airingSeasonJSON)
        }
        let link = TMDbLink(itemID: "series", entityKey: .tv(100),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        let season = TMDbSeason(seasonNumber: 1, episodes: [
            EpisodeEntry(episodeNumber: 1, name: "第 1 集", airDate: "2026-10-01"),
            EpisodeEntry(episodeNumber: 2, name: "第 2 集", airDate: "2999-12-31"),
        ])
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        try await store.saveTMDbPayload(.season(season), key: .season(tvID: 100, number: 1),
                                        language: "zh-CN", lifetime: 90 * 24 * 60 * 60,
                                        now: tenDaysAgo)
        let didFetch = await enricher.refreshSeason(seriesLink: link, seasonNumber: 1)
        XCTAssertTrue(didFetch, "expires 未到但已过在播窗口，应回源")
        XCTAssertEqual(counter.value, 1)
        // 刷下来的新数据（仍在播）在窗口内不重复刷
        let again = await enricher.refreshSeason(seriesLink: link, seasonNumber: 1)
        XCTAssertFalse(again)
        XCTAssertEqual(counter.value, 1)
    }

    /// 播完的季：旧长缓存不回源（只看 expires_at），与在播季的按天回源互为反面——
    /// 若 `isFresh` 的在播守卫被误删（完结季也按 fetchedAt 判），这条会红。
    func testFinishedSeasonWithLongCacheSkipsRefetch() async throws {
        let counter = CallCounter()
        let enricher = makeEnricher { _ in
            counter.increment()
            return (200, Self.airingSeasonJSON)
        }
        let link = TMDbLink(itemID: "series", entityKey: .tv(100),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        let finished = TMDbSeason(seasonNumber: 1, episodes: [
            EpisodeEntry(episodeNumber: 1, name: "第一集", airDate: "2020-01-01"),
            EpisodeEntry(episodeNumber: 2, name: "第二集", airDate: "2020-03-31"),
        ])
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        try await store.saveTMDbPayload(.season(finished), key: .season(tvID: 100, number: 1),
                                        language: "zh-CN", lifetime: 90 * 24 * 60 * 60,
                                        now: tenDaysAgo)
        let didFetch = await enricher.refreshSeason(seriesLink: link, seasonNumber: 1)
        XCTAssertFalse(didFetch, "完结季的旧长缓存照旧跳过")
        XCTAssertEqual(counter.value, 0)
    }

    /// 季终宽限：最后一集昨天播出 → 整季仍按在播处理，超窗的长缓存照样回源。
    /// 不给宽限的话，季终集播出次日整季就被判定型，季终集占位名锁进常规缓存期——
    /// 恰好是最想让用户看到真名的一集。
    func testSeasonFinaleWithinGraceStillRefetches() async throws {
        let counter = CallCounter()
        let enricher = makeEnricher { _ in
            counter.increment()
            return (200, Self.airingSeasonJSON)
        }
        let link = TMDbLink(itemID: "series", entityKey: .tv(100),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        let justEnded = TMDbSeason(seasonNumber: 1, episodes: [
            EpisodeEntry(episodeNumber: 1, name: "第一集", airDate: dayString(-30)),
            EpisodeEntry(episodeNumber: 2, name: "第二集", airDate: dayString(-1)),
        ])
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        try await store.saveTMDbPayload(.season(justEnded), key: .season(tvID: 100, number: 1),
                                        language: "zh-CN", lifetime: 90 * 24 * 60 * 60,
                                        now: tenDaysAgo)
        let didFetch = await enricher.refreshSeason(seriesLink: link, seasonNumber: 1)
        XCTAssertTrue(didFetch, "季终宽限内的旧长缓存应回源")
        XCTAssertEqual(counter.value, 1)
    }

    /// 非 `.tv` 的 link（电影）不该被当成剧来查季。
    func testSeasonOverlayRejectsNonTVLink() async throws {
        let enricher = makeEnricher { _ in (200, Self.season2JSON) }
        let movieLink = TMDbLink(itemID: "m", entityKey: .movie(603),
                                 source: .providerID, confidence: 1.0, linkedAt: Date())
        let overlay = await enricher.seasonOverlay(seriesLink: movieLink, seasonNumber: 1)
        XCTAssertNil(overlay)
        let didFetch = await enricher.refreshSeason(seriesLink: movieLink, seasonNumber: 1)
        XCTAssertFalse(didFetch)
    }

    /// 不同季各存一份，互不覆盖。
    func testSeasonsAreStoredSeparately() async throws {
        let enricher = makeEnricher { path in
            path.contains("/season/1") ? (200, Self.seasonJSON) : (200, Self.season2JSON)
        }
        let link = TMDbLink(itemID: "series", entityKey: .tv(60730),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        _ = await enricher.refreshSeason(seriesLink: link, seasonNumber: 1)
        _ = await enricher.refreshSeason(seriesLink: link, seasonNumber: 2)

        let s1 = await enricher.seasonOverlay(seriesLink: link, seasonNumber: 1)
        let s2 = await enricher.seasonOverlay(seriesLink: link, seasonNumber: 2)
        XCTAssertEqual(s1?.overview, "第一季简介")
        XCTAssertEqual(s2?.overview, "第二季简介")
    }

    // MARK: - 失效与容错

    /// 未配置 key → 全部无操作，不抛错、不发请求（功能整体禁用）。
    func testDisabledWhenNoKey() async throws {
        var requested = 0
        let enricher = makeEnricher(apiKey: nil) { _ in
            requested += 1
            return (200, Self.movieJSON)
        }
        let enabled = await enricher.isEnabled
        XCTAssertFalse(enabled)

        let didFetch = await enricher.refresh(
            item: makeItem(id: "m1", kind: .movie, tmdbID: "603"), tenant: tenant)
        XCTAssertFalse(didFetch)
        XCTAssertEqual(requested, 0)
        let overlay = await enricher.overlay(
            for: makeItem(id: "m1", kind: .movie, tmdbID: "603"), tenant: tenant)
        XCTAssertNil(overlay)
    }

    /// 404（脏 ProviderIds）→ 不落库、不崩；下次仍会重试（因为库里没有对应）。
    func testNotFoundDoesNotStoreLink() async throws {
        let enricher = makeEnricher { _ in (404, Data()) }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "999999999")
        await enricher.refresh(item: movie, tenant: tenant)
        let link = try await store.tmdbLink(itemID: "m1", tenant: tenant)
        XCTAssertEqual(link?.entityKey, .movie(999999999), "对应关系仍会记下（来源是服务端 id）")
        let overlay = await enricher.overlay(for: movie, tenant: tenant)
        XCTAssertNil(overlay, "但没数据可叠加")
    }

    /// 网络失败**不删已有数据**：旧数据比没有强（缓存优先的价值）。
    func testTransportFailureKeepsExistingData() async throws {
        var shouldFail = false
        let enricher = makeEnricher { _ in
            shouldFail ? (500, Data()) : (200, Self.movieJSON)
        }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")
        await enricher.refresh(item: movie, tenant: tenant)
        let beforeFailure = await enricher.overlay(for: movie, tenant: tenant)
        XCTAssertNotNil(beforeFailure)

        // 让数据过期，然后网络挂掉
        try await store.saveTMDbPayload(.entity(TMDbEntity(id: 603, mediaType: .movie)),
                                       key: .movie(603), language: "zh-CN", lifetime: -10)
        shouldFail = true
        await enricher.refresh(item: movie, tenant: tenant)

        let overlay = await enricher.overlay(for: movie, tenant: tenant)
        XCTAssertNotNil(overlay, "拉取失败时旧数据必须保留")
    }

    // MARK: - 语言

    /// 语言进缓存键：同一实体两种语言各存一份，互不覆盖。
    ///
    /// 注意 `StubProtocol.handler` 是**静态共享**的——不能同时造两个 enricher
    /// 各带各的路由（后造的会覆盖前者的 handler，第一个就此打到别人的响应上）。
    /// 所以这里按语言分别串行地建/用，并在切换前重建 handler。
    func testLanguageAffectsStoredData() async throws {
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")

        StubProtocol.handler = { _ in (200, Self.movieJSON) }
        let zh = makeEnricher(language: "zh-CN") { _ in (200, Self.movieJSON) }
        await zh.refresh(item: movie, tenant: tenant)
        let zhOverlay = await zh.overlay(for: movie, tenant: tenant)
        XCTAssertEqual(zhOverlay?.title, "黑客帝国")

        let en = makeEnricher(language: "en-US") { _ in (200, Self.movieENJSON) }
        await en.refresh(item: movie, tenant: tenant)
        let enOverlay = await en.overlay(for: movie, tenant: tenant)
        XCTAssertEqual(enOverlay?.title, "The Matrix")

        // 中文那份**没被英文覆盖**（语言进主键的意义）
        let zhAgain = await zh.overlay(for: movie, tenant: tenant)
        XCTAssertEqual(zhAgain?.title, "黑客帝国")
    }

    // MARK: - 维护

    func testLinkedCountAndClear() async throws {
        let enricher = makeEnricher { _ in (200, Self.movieJSON) }
        let movie = makeItem(id: "m1", kind: .movie, tmdbID: "603")
        await enricher.refresh(item: movie, tenant: tenant)

        var count = await enricher.linkedCount(tenant: tenant)
        XCTAssertEqual(count, 1)

        await enricher.clear(tenant: tenant)
        count = await enricher.linkedCount(tenant: tenant)
        XCTAssertEqual(count, 0)
        let afterClear = await enricher.overlay(for: movie, tenant: tenant)
        XCTAssertNil(afterClear)
    }

    // MARK: - 并发合并

    /// 同一实体并发请求只打一次网络（详情页与剧集页可能同时要它）。
    func testConcurrentFetchesAreCoalesced() async throws {
        // 计数用 `@unchecked Sendable` + 内部锁：StubProtocol 的 handler 是**同步**的，
        // 没法在其中 await actor。
        let counter = CallCounter()
        let enricher = makeEnricher { _ in
            counter.increment()
            return (200, Self.movieJSON)
        }
        async let a = enricher.fetchAndStore(key: .movie(603))
        async let b = enricher.fetchAndStore(key: .movie(603))
        async let c = enricher.fetchAndStore(key: .movie(603))
        _ = await (a, b, c)

        let total = counter.value
        XCTAssertLessThanOrEqual(total, 3)
        XCTAssertGreaterThanOrEqual(total, 1)
    }

    // MARK: - 样例响应

    static let movieJSON = Data(#"""
    {"id":603,"title":"黑客帝国","original_title":"The Matrix","overview":"简介",
     "poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","vote_average":8.2,
     "genres":[{"id":28,"name":"动作"}]}
    """#.utf8)

    static let movieENJSON = Data(#"""
    {"id":603,"title":"The Matrix","original_title":"The Matrix","overview":"A hacker learns",
     "poster_path":"/poster.jpg","vote_average":8.2,"genres":[{"id":28,"name":"Action"}]}
    """#.utf8)

    static let tvJSON = Data(#"""
    {"id":71785,"name":"阿松","original_name":"Osomatsu-san","overview":"六胞胎",
     "poster_path":"/osomatsu.jpg","genres":[{"id":16,"name":"动画"}],
     "seasons":[{"season_number":1,"name":"第 1 季","episode_count":25}]}
    """#.utf8)

    static let searchTVJSON = Data(#"""
    {"results":[{"id":71785,"name":"阿松","original_name":"Osomatsu-san",
                 "first_air_date":"2015-10-06","poster_path":"/osomatsu.jpg","popularity":30.0}]}
    """#.utf8)

    static let unrelatedSearchJSON = Data(#"""
    {"results":[{"id":999,"title":"完全无关","release_date":"2020-01-01","popularity":1.0}]}
    """#.utf8)

    static let season2JSON = Data(#"""
    {"season_number":2,"name":"第 2 季","overview":"第二季简介","poster_path":"/s2.jpg",
     "episodes":[{"episode_number":1,"name":"第一集","still_path":"/a.jpg"},
                 {"episode_number":9,"name":"离别之时","still_path":"/b.jpg"}]}
    """#.utf8)

    static let seasonJSON = Data(#"""
    {"season_number":1,"name":"第 1 季","overview":"第一季简介","poster_path":"/s1.jpg",
     "episodes":[{"episode_number":1,"name":"电气少年","still_path":"/st1.jpg"}]}
    """#.utf8)

    /// 在播季：还有一集播在遥远的未来。
    static let airingSeasonJSON = Data(#"""
    {"season_number":1,"name":"在播季","episodes":[
      {"episode_number":1,"name":"第一集","air_date":"2026-10-01"},
      {"episode_number":2,"name":"第二集","air_date":"2999-12-31"}]}
    """#.utf8)
}

private struct StubEnricherCredential: TMDbCredentialProviding {
    let key: String?
    func apiKey() -> String? { key }
}


/// 调用计数。内部锁 + `@unchecked Sendable`：handler 是同步闭包，用不了 actor。
/// `internal`：同测试模块的 `TMDbBatchTests` 也用。
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
