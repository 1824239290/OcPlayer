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
            // 复现这台服务器的形态：有「继续观看」「接下来看」，**没有「最近添加」**。
            try await store.saveLibraries([
                MediaLibrary(id: "lib-1", name: "电视剧", collectionType: .tvshows),
            ], tenant: tenant)
            try await store.saveRail((0..<3).map { MediaItem(id: "r\($0)", name: "续播\($0)", kind: .movie) },
                                     rail: "resume", tenant: tenant)
            try await store.saveRail((0..<6).map { MediaItem(id: "n\($0)", name: "下一集\($0)", kind: .episode) },
                                     rail: "nextUp", tenant: tenant)
            // latest 刻意不写：服务器没有这一个 rail。
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
}
