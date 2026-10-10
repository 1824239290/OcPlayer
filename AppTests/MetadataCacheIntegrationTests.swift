import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 端到端：冷启动读缓存**不发请求**，网络失败时页面仍有内容。
///
/// 这些用例走的是真实的 `AppModel` + 真实的 `MetadataKit`（临时目录真 SQLite），
/// 只有网络那一层是 `StubMediaServer`。之所以值得这么测：本模块的价值全在
/// 「App 层有没有正确接上那条读路径」上——包内单测全绿但接线漏了，用户看到的
/// 仍是空白页。
@MainActor
final class MetadataCacheIntegrationTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataCacheIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // **必须用隔离的 UserDefaults 域**：`loadHome` 会写首屏骨架条数
        // （`home.railPresence`），而 `xcodebuild` 默认并行多进程跑用例，
        // 写 `.standard` 就是与 `HomeRailLoadingTests` 抢同一个键
        // （实测把它整挂）。见 `AppModel.init(preferences:)`。
        suiteName = "MetadataCacheIntegration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    /// 建好一个「已建库 + 已预置缓存」的 AppModel。
    private func makeApp(seed: (MetadataStore, TenantID) async throws -> Void) async throws
        -> (AppModel, StubMediaServer, MetadataStore, TenantID) {
        let app = AppModel(preferences: try XCTUnwrap(defaults))
        app.metadata.setup(directory: directory)
        let ready = await app.metadata.waitUntilReady()
        XCTAssertTrue(ready, "临时目录建库应成功")
        let store = try XCTUnwrap(app.metadata.activeStore)

        let stub = StubMediaServer()
        let tenant = TenantID(profile: stub.profile)
        try await seed(store, tenant)
        return (app, stub, store, tenant)
    }

    // MARK: - 首页

    /// 冷启动：磁盘有内容时填进内存，且**一条网络请求都不发**。
    func testHomeHydrationFillsStateWithoutAnyRequest() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveLibraries([
                MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows),
            ], tenant: tenant)
            try await store.saveRail([MediaItem(id: "r1", name: "续播", kind: .movie)],
                                     rail: "resume", tenant: tenant)
            try await store.saveRail([MediaItem(id: "l1", name: "最近", kind: .movie)],
                                     rail: "latest", tenant: tenant)
        }

        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        await app.hydrateBrowserDataFromCache(server: stub, generation: 1)

        XCTAssertEqual(app.libraries.map(\.id), ["lib-1"])
        XCTAssertEqual(app.home.resume.map(\.id), ["r1"])
        XCTAssertEqual(app.home.latest.map(\.id), ["l1"])
        // 关键：读缓存不该顺带打网络。
        XCTAssertEqual(stub.callCount("userViews"), 0)
        XCTAssertEqual(stub.callCount("resumeItems"), 0)
        XCTAssertEqual(stub.callCount("latestItems"), 0)
    }

    /// 没有缓存时不填、也不报错（保持原有的骨架屏 → 空态路径）。
    func testHomeHydrationIsNoOpWithoutCache() async throws {
        let (app, stub, _, _) = try await makeApp { _, _ in }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        await app.hydrateBrowserDataFromCache(server: stub, generation: 1)

        XCTAssertTrue(app.libraries.isEmpty)
        XCTAssertTrue(app.home.resume.isEmpty)
        XCTAssertNil(app.home.cachedFetchedAt)
    }

    /// 内存里已有内容时**不覆盖**（下拉刷新 / 重试走同一入口，
    /// 用磁盘上的旧版本盖掉刚拉到的内容就倒退了）。
    func testHomeHydrationDoesNotOverwriteExistingContent() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveRail([MediaItem(id: "disk", name: "磁盘", kind: .movie)],
                                     rail: "resume", tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        app.home.resume = [MediaItem(id: "memory", name: "内存", kind: .movie)]

        await app.hydrateBrowserDataFromCache(server: stub, generation: 1)
        XCTAssertEqual(app.home.resume.map(\.id), ["memory"])
    }

    /// 换服务器后不显示上一台的缓存（租户隔离在 App 层的体现）。
    func testHydrationIsScopedToCurrentServer() async throws {
        let (app, _, _, _) = try await makeApp { store, tenant in
            try await store.saveRail([MediaItem(id: "a", name: "A 台", kind: .movie)],
                                     rail: "resume", tenant: tenant)
        }
        // 另一台服务器（档案 id 不同 = 不同租户）。
        let other = StubMediaServer(profileID: "other:user")
        app.phase = .ready
        app.server = other
        app.sessionGeneration = 1
        await app.hydrateBrowserDataFromCache(server: other, generation: 1)

        XCTAssertTrue(app.home.resume.isEmpty, "不该读到另一台服务器的缓存")
    }

    /// 网络成功后清掉「展示的是缓存」标记；失败且是连不上时标记为离线。
    func testStaleNoticeReflectsRefreshOutcome() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveRail([MediaItem(id: "r1", name: "续播", kind: .movie)],
                                     rail: "resume", tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        await app.hydrateBrowserDataFromCache(server: stub, generation: 1)
        XCTAssertNotNil(app.home.cachedFetchedAt, "来自磁盘的内容要带上时间")

        // 三条 rail 全失败（断网）→ 内容保留 + 提示离线。
        stub.resumeResult = .failure(JellyfinError(.noNetwork))
        stub.nextUpResult = .failure(JellyfinError(.noNetwork))
        stub.latestResult = .failure(JellyfinError(.noNetwork))
        await app.loadHome(server: stub, generation: 1)

        XCTAssertEqual(app.home.resume.map(\.id), ["r1"], "失败要保留缓存内容，不清空")
        let notice = try XCTUnwrap(app.homeStaleNotice)
        XCTAssertTrue(notice.causedByConnectivity)
        XCTAssertNotNil(notice.fetchedAt)

        // 三条全成功 → 标记清掉。
        stub.resumeResult = .success([MediaItem(id: "fresh", name: "新", kind: .movie)])
        stub.nextUpResult = .success([])
        stub.latestResult = .success([])
        await app.loadHome(server: stub, generation: 1)
        XCTAssertNil(app.home.cachedFetchedAt)
        XCTAssertNil(app.homeStaleNotice)
    }

    /// **用户实测的离线场景端到端复现**：磁盘有内容 → 三条 rail 全挂（连不上）
    /// → 首页必须显示内容（而不是骨架屏或错误页），并带一行离线提示。
    ///
    /// 这条用例的价值在于它把「缓存读出来了」与「界面显示了」**串成一个断言**：
    /// 之前只有前者被测到（日志里 `resume=3 nextUp=6` 明明读出来了），而界面判定
    /// 用的 `latest.isEmpty` 把它挡在门外——两个各自"正确"的部分拼起来是坏的。
    func testOfflineColdStartShowsCachedContentInsteadOfSkeleton() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            // 复现「latest 为空」的形态：有「继续观看」「接下来看」，这一条 rail 没内容。
            // （本机 2026-10-07 之前正是这样，原因见 `JellyfinServer.latestItems`；
            //  但「某条 rail 为空」本身也是合法的服务器形态，缓存预热必须扛住。）
            try await store.saveLibraries([
                MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows),
            ], tenant: tenant)
            try await store.saveRail((0..<3).map { MediaItem(id: "r\($0)", name: "续播\($0)", kind: .movie) },
                                     rail: "resume", tenant: tenant)
            try await store.saveRail((0..<6).map { MediaItem(id: "n\($0)", name: "下一集\($0)", kind: .episode) },
                                     rail: "nextUp", tenant: tenant)
            // latest 刻意不写：这条 rail 没有内容。
        }

        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1

        // ① 磁盘预热（真实冷启动走的是 loadInitialData → hydrate）
        await app.hydrateBrowserDataFromCache(server: stub, generation: 1)
        XCTAssertEqual(app.home.resume.count, 3)
        XCTAssertEqual(app.home.nextUp.count, 6)

        // ② 网络全挂前先确认：此时即便还在加载，也不该回到骨架屏
        app.home.isLoading = true
        XCTAssertEqual(app.homePresentation, .content, "有内容时加载中也要显示内容，不能转骨架")

        // ③ 三条 rail 全挂（断网）
        app.home.isLoading = false
        let offline = JellyfinError(.noNetwork)
        stub.resumeResult = .failure(offline)
        stub.nextUpResult = .failure(offline)
        stub.latestResult = .failure(offline)
        await app.loadHome(server: stub, generation: 1)

        // ④ 内容仍在 + 显示内容态 + 有离线提示
        XCTAssertEqual(app.home.resume.map(\.id), ["r0", "r1", "r2"], "失败要保留缓存内容")
        XCTAssertEqual(app.homePresentation, .content, "必须显示内容，不能是骨架屏或错误页")
        let notice = try XCTUnwrap(app.homeStaleNotice)
        XCTAssertTrue(notice.causedByConnectivity)
    }

    /// 反面：**没有**缓存时离线冷启动，仍走原有的骨架 → 错误页路径
    /// （这次改动不该把「什么都没有」时的正确报错弄丢）。
    func testOfflineColdStartWithoutCacheKeepsErrorPath() async throws {
        let (app, stub, _, _) = try await makeApp { _, _ in }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1

        await app.hydrateBrowserDataFromCache(server: stub, generation: 1)
        XCTAssertFalse(app.hasAnyHomeContent)

        let offline = JellyfinError(.noNetwork)
        stub.resumeResult = .failure(offline)
        stub.nextUpResult = .failure(offline)
        stub.latestResult = .failure(offline)
        await app.loadHome(server: stub, generation: 1)

        XCTAssertNotNil(app.home.error)
        guard case .error = app.homePresentation else {
            return XCTFail("没有内容时该走错误页，实际 \(app.homePresentation)")
        }
    }

    // MARK: - 详情

    /// 离线进详情页：显示缓存内容 + 离线提示，而不是空白错误页。
    func testDetailShowsCachedContentWhenOffline() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "series-1", name: "某番", kind: .series, overview: "简介"),
                MediaItem(id: "season-1", name: "第 1 季", kind: .season,
                          seriesID: "series-1", seasonNumber: 1),
                MediaItem(id: "ep-1", name: "第一集", kind: .episode,
                          seriesID: "series-1", seasonNumber: 1, episodeNumber: 1),
            ], tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1

        // 网络全挂（断网）。
        stub.itemResult = .failure(JellyfinError(.noNetwork))
        stub.seasonsResult = .failure(JellyfinError(.noNetwork))
        stub.episodesResult = .failure(JellyfinError(.noNetwork))

        let model = DetailViewModel(item: MediaItem(id: "series-1", name: "某番", kind: .series))
        model.attach(app)
        await model.load()

        // 内容来自磁盘
        XCTAssertEqual(model.shown.overview, "简介")
        XCTAssertEqual(model.seasons.map(\.id), ["season-1"])
        XCTAssertEqual(model.episodes.map(\.id), ["ep-1"])
        // 且明确告诉用户这是缓存
        let notice = try XCTUnwrap(model.staleNotice)
        XCTAssertTrue(notice.causedByConnectivity)
        // 不该落成整页错误（有内容就不该报错）
        XCTAssertNil(model.loadError)
    }

    /// 服务端出错（非断网）时不谎称「离线」。
    func testDetailDoesNotClaimOfflineForServerError() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "m1", name: "电影", kind: .movie, overview: "简介"),
            ], tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        stub.itemResult = .failure(JellyfinError(.http(status: 500)))

        let model = DetailViewModel(item: MediaItem(id: "m1", name: "电影", kind: .movie))
        model.attach(app)
        await model.load()

        let notice = try XCTUnwrap(model.staleNotice)
        XCTAssertFalse(notice.causedByConnectivity, "5xx 不能说成离线")
        XCTAssertFalse(notice.text().contains("离线"))
    }

    /// 没有缓存 + 网络失败 → 走既有的整页错误态（不叠离线提示）。
    func testDetailWithoutCacheKeepsExistingErrorPath() async throws {
        let (app, stub, _, _) = try await makeApp { _, _ in }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        stub.itemResult = .failure(JellyfinError(.noNetwork))

        let model = DetailViewModel(item: MediaItem(id: "nope", name: "无", kind: .movie))
        model.attach(app)
        await model.load()

        XCTAssertNotNil(model.loadError, "没内容就该报错")
        XCTAssertNil(model.staleNotice, "整页错误态不该再叠离线提示")
    }

    /// 网络成功时用网络内容覆盖磁盘内容，并清掉离线提示。
    func testDetailPrefersNetworkOverCache() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "m1", name: "旧名字", kind: .movie, overview: "旧简介"),
            ], tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        stub.itemResult = .success(MediaItem(id: "m1", name: "新名字", kind: .movie, overview: "新简介"))

        let model = DetailViewModel(item: MediaItem(id: "m1", name: "m1", kind: .movie))
        model.attach(app)
        await model.load()

        XCTAssertEqual(model.shown.name, "新名字")
        XCTAssertEqual(model.shown.overview, "新简介")
        XCTAssertNil(model.staleNotice)
    }

    // MARK: - 详情页占位（库里没有的集）

    /// 预置「已匹配 + 已缓存且未过期」的 TMDb 状态。
    ///
    /// **必须三份都齐**（对应 + 剧集实体 + 季数据）：少一份，`performRefresh` 就会
    /// 走到真正的网络请求——用例碰真实 TMDb 既慢又不稳，本仓的规矩是包测试全部离线。
    /// 三份都未过期时 `performRefresh` 第一步就短路（「已有对应且数据够新 → 不动」）。
    private func seedTMDb(
        store: MetadataStore,
        tenant: TenantID,
        tvID: Int = 100,
        seasonNumber: Int = 3,
        episodes: [(number: Int, airDate: String?)]
    ) async throws {
        let lifetime = TimeInterval(TMDbPreferences.defaultCacheDays) * 24 * 60 * 60
        try await store.saveTMDbLink(itemID: "series-1", entityKey: .tv(tvID),
                                     source: .providerID, confidence: 1.0, tenant: tenant)
        try await store.saveTMDbPayload(
            .entity(TMDbEntity(id: tvID, mediaType: .tv, title: "某番")),
            key: .tv(tvID), language: "zh-CN", lifetime: lifetime)
        try await store.saveTMDbPayload(
            .season(TMDbSeason(seasonNumber: seasonNumber, name: "第 \(seasonNumber) 季",
                               episodes: episodes.map { entry in
                                   EpisodeEntry(episodeNumber: entry.number,
                                                name: "第 \(entry.number) 话",
                                                airDate: entry.airDate, runtime: 24)
                               })),
            key: .season(tvID: tvID, number: seasonNumber), language: "zh-CN", lifetime: lifetime)
    }

    /// 剧集页的选集轨道：库内只有 S3E25，TMDb 的季数据说这一季有 25…36 →
    /// 轨道补出 26…36 的占位卡，而 `episodes`（服务端事实）与选中集**一个都不多**。
    ///
    /// 这条同时钉住「占位是派生展示、不是数据」：`episodes` 里多出一张假条目，
    /// 就会顺着播放、已看标记、连播与磁盘快照流出去。
    func testDetailFillsMissingEpisodesFromTMDbSeason() async throws {
        let (app, stub, store, tenant) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "series-1", name: "某番", kind: .series, tmdbID: "100"),
                MediaItem(id: "season-3", name: "第 3 季", kind: .season,
                          seriesID: "series-1", seasonNumber: 3),
                MediaItem(id: "ep-25", name: "第 25 集", kind: .episode,
                          seriesID: "series-1", seasonID: "season-3",
                          seasonNumber: 3, episodeNumber: 25),
            ], tenant: tenant)
        }
        // 配 key + 装配补全服务（生产路径里这两步在 bootstrap，测试宿主刻意跳过它）。
        app.tmdb.setAPIKey("0123456789abcdef0123456789abcdef")
        app.tmdb.attach(store: store)
        // 26…35 早已播出、36 定在 2099（永远「未播出」），两种标签都能断言。
        try await seedTMDb(store: store, tenant: tenant,
                           episodes: (25...36).map {
                               (number: $0, airDate: $0 == 36 ? "2099-01-01" : "2020-01-01")
                           })

        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        let series = MediaItem(id: "series-1", name: "某番", kind: .series, tmdbID: "100")
        stub.itemResult = .success(series)
        stub.seasonsResult = .success([
            MediaItem(id: "season-3", name: "第 3 季", kind: .season,
                      seriesID: "series-1", seasonNumber: 3),
        ])
        stub.episodesResult = .success([
            MediaItem(id: "ep-25", name: "第 25 集", kind: .episode,
                      seriesID: "series-1", seasonID: "season-3",
                      seasonNumber: 3, episodeNumber: 25),
        ])

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()
        await model.loadEpisodes()

        XCTAssertEqual(model.selectedSeasonID, "season-3")
        XCTAssertEqual(model.episodes.map(\.id), ["ep-25"], "服务端事实里不能多出假条目")
        XCTAssertEqual(model.selectedEpisodeID, "ep-25")
        XCTAssertEqual(model.episodeSlots.compactMap(\.episode).map(\.id), ["ep-25"])

        let placeholders = model.episodeSlots.compactMap(\.placeholder)
        XCTAssertEqual(placeholders.map(\.number), Array(26...36))
        XCTAssertTrue(placeholders.allSatisfy { $0.seasonNumber == 3 })
        XCTAssertTrue(placeholders.dropLast().allSatisfy { $0.reason == .notInLibrary },
                      "早已播出的集 → 「未入库」")
        XCTAssertEqual(placeholders.last?.reason, .notAired, "2099 那一集 → 「未播出」")
        XCTAssertEqual(placeholders.first?.displayTitle, "第 26 话")
        XCTAssertEqual(placeholders.first?.episodeLabel, "S3E26")
        XCTAssertEqual(model.episodeSlots.map(\.id).count, Set(model.episodeSlots.map(\.id)).count,
                       "占位 id 不能与本地 id 或彼此相撞")
    }

    /// 关掉开关 → 即使 TMDb 季数据就在库里也不出占位（退回加占位之前的行为）。
    func testDetailPlaceholdersRespectTheSetting() async throws {
        let (app, stub, store, tenant) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "series-1", name: "某番", kind: .series, tmdbID: "100"),
            ], tenant: tenant)
        }
        app.tmdb.setAPIKey("0123456789abcdef0123456789abcdef")
        app.tmdb.attach(store: store)
        app.tmdb.setShowPlaceholders(false)
        try await seedTMDb(store: store, tenant: tenant,
                           episodes: (25...27).map { (number: $0, airDate: "2020-01-01") })

        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        let series = MediaItem(id: "series-1", name: "某番", kind: .series, tmdbID: "100")
        stub.itemResult = .success(series)
        stub.seasonsResult = .success([
            MediaItem(id: "season-3", name: "第 3 季", kind: .season,
                      seriesID: "series-1", seasonNumber: 3),
        ])
        stub.episodesResult = .success([
            MediaItem(id: "ep-25", name: "第 25 集", kind: .episode,
                      seriesID: "series-1", seasonID: "season-3",
                      seasonNumber: 3, episodeNumber: 25),
        ])

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()
        await model.loadEpisodes()

        XCTAssertEqual(model.episodeSlots.map(\.id), ["ep-25"])
        XCTAssertTrue(model.episodeSlots.allSatisfy { $0.placeholder == nil })
    }

    /// 没配 TMDb（没 key）→ 不补占位；此时 Bangumi 章节兜底接手。
    ///
    /// 这条同时验证优先级：编号对不上的来源**必须被忽略**（宁可没有占位，也不要错号的
    /// 假卡片）。用注入的候选数组就能测，不需要 Bangumi 登录态
    /// （`isAuthenticated` 依赖真实凭据文件，测试里伪造不了）。
    func testDetailPlaceholdersFallBackToBangumiCandidates() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "series-1", name: "某番", kind: .series),
            ], tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        let series = MediaItem(id: "series-1", name: "某番", kind: .series)
        stub.itemResult = .success(series)
        stub.seasonsResult = .success([
            MediaItem(id: "season-3", name: "第 3 季", kind: .season,
                      seriesID: "series-1", seasonNumber: 3),
        ])
        stub.episodesResult = .success([
            MediaItem(id: "ep-25", name: "第 25 集", kind: .episode,
                      seriesID: "series-1", seasonID: "season-3",
                      seasonNumber: 3, episodeNumber: 25),
        ])

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()
        await model.loadEpisodes()
        XCTAssertEqual(model.episodeSlots.map(\.id), ["ep-25"], "没有来源时不该凭空补占位")

        // 区块递上本篇章节（25 是锚点，26、27 是库里没有的）。
        model.acceptBangumiCandidates([
            EpisodeCandidate(number: 25, title: "第 25 话", airDate: past),
            EpisodeCandidate(number: 26, title: "第 26 话", airDate: past),
            EpisodeCandidate(number: 27, title: "第 27 话", airDate: past),
        ])

        XCTAssertEqual(model.episodeSlots.compactMap(\.episode).map(\.id), ["ep-25"])
        XCTAssertEqual(model.episodeSlots.compactMap(\.placeholder).map(\.number), [26, 27])
        XCTAssertEqual(model.episodeSlots.compactMap(\.placeholder).map(\.displayTitle),
                       ["第 26 话", "第 27 话"])
        XCTAssertTrue(model.episodeSlots.compactMap(\.placeholder)
            .allSatisfy { $0.reason == .notInLibrary })

        // 编号对不上的来源（季内相对号 vs 绝对号）不该补出假卡。
        model.acceptBangumiCandidates((1...12).map { EpisodeCandidate(number: $0, airDate: past) })
        XCTAssertEqual(model.episodeSlots.map(\.id), ["ep-25"])
    }

    /// 占位卡的取图：TMDb 有剧照就用它（免鉴权）；没有就用**剧集自己的横版图**
    /// （首页「继续观看」那条链），把格子填上而不是留一块灰底。
    func testPlaceholderThumbPrefersTMDbStillThenFallsBackToSeriesImage() async throws {
        let series = MediaItem(id: "series-1", name: "某番", kind: .series,
                               thumbImageTag: "series-thumb-tag")
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveItems([series], tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        stub.itemResult = .success(series)
        stub.seasonsResult = .success([
            MediaItem(id: "season-3", name: "第 3 季", kind: .season,
                      seriesID: "series-1", seasonNumber: 3),
        ])
        stub.episodesResult = .success([
            MediaItem(id: "ep-25", name: "第 25 集", kind: .episode,
                      seriesID: "series-1", seasonID: "season-3",
                      seasonNumber: 3, episodeNumber: 25),
        ])

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()
        await model.loadEpisodes()

        // 没有 TMDb 剧照 → 剧集自己的 Thumb（服务端图，带凭证）。
        // 断言拆成「路径」与「query」两段而不是整串字面量：替身的 `imageURL` 与真实
        // 实现同形（`?maxWidth=…&tag=…`），整串比较会在每次调整取图参数时无意义地变红；
        // 这里真正要钉住的是「回落到**剧集自己**的那张 Thumb」与「tag 传下去了」。
        let noStill = EpisodePlaceholder(number: 26, seasonNumber: 3, reason: .notInLibrary)
        let fallback = model.placeholderThumbTarget(for: noStill, width: 400)
        let fallbackURL = try XCTUnwrap(fallback.url)
        XCTAssertEqual(fallbackURL.host, "stub.local")
        XCTAssertEqual(fallbackURL.path, "/Items/series-1/Images/Thumb")
        XCTAssertTrue(fallbackURL.absoluteString.contains("tag=series-thumb-tag"),
                      "tag 要进 URL：图换了 URL 就变，磁盘缓存自然失效")
        XCTAssertEqual(fallback.authHeader, stub.authorizationHeader)

        // 有 TMDb 剧照 → 走 TMDb CDN，且**不带**服务端凭证（CDN 不校验，多送一处没意义）。
        let withStill = EpisodePlaceholder(number: 27, seasonNumber: 3,
                                           stillPath: "/s27.jpg", reason: .notInLibrary)
        let tmdb = model.placeholderThumbTarget(for: withStill, width: 400)
        XCTAssertEqual(tmdb.url?.absoluteString, "https://image.tmdb.org/t/p/w500/s27.jpg")
        XCTAssertNil(tmdb.authHeader)
    }

    /// 换季时上一季的兜底候选必须作废，否则会拿旧季的集号配新季的季号。
    func testSwitchingSeasonDropsStaleCandidates() async throws {
        let (app, stub, _, _) = try await makeApp { store, tenant in
            try await store.saveItems([
                MediaItem(id: "series-1", name: "某番", kind: .series),
            ], tenant: tenant)
        }
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        let series = MediaItem(id: "series-1", name: "某番", kind: .series)
        stub.itemResult = .success(series)
        stub.seasonsResult = .success([
            MediaItem(id: "season-3", name: "第 3 季", kind: .season,
                      seriesID: "series-1", seasonNumber: 3),
            MediaItem(id: "season-4", name: "第 4 季", kind: .season,
                      seriesID: "series-1", seasonNumber: 4),
        ])
        stub.episodesResult = .success([
            MediaItem(id: "ep-25", name: "第 25 集", kind: .episode,
                      seriesID: "series-1", seasonID: "season-3",
                      seasonNumber: 3, episodeNumber: 25),
        ])

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()
        await model.loadEpisodes()
        model.acceptBangumiCandidates([
            EpisodeCandidate(number: 25, airDate: past),
            EpisodeCandidate(number: 26, airDate: past),
        ])
        XCTAssertEqual(model.episodeSlots.compactMap(\.placeholder).map(\.number), [26])

        model.selectSeason("season-4")
        XCTAssertTrue(model.episodeSlots.allSatisfy { $0.placeholder == nil },
                      "换季后旧季的候选必须清掉，不能拿旧集号配新季号")
    }

    /// 固定的过去时刻（占位标签只用它判断「未播出」，用真实 `Date()` 会让用例随
    /// 时间漂移）。
    private var past: Date { Date(timeIntervalSince1970: 1_600_000_000) }
}
