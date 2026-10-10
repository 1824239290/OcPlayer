import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 合集详情页的展示策略（真 AppModel + 真 SQLite + 替身服务器，**全部离线**）。
///
/// 这一层要守住的是「接线对不对」：TMDb 的合集数据接上了没有、标题该不该被顶替、
/// 背景图的三个来源谁优先。包内单测（`TMDbCollectionTests`）只证明「能定位到 TMDb 合集」，
/// 证明不了页面会把它用起来。
@MainActor
final class CollectionDetailTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectionDetail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "CollectionDetail-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    private func makeApp(
        configureKey: Bool = false,
        seed: (MetadataStore, TenantID) async throws -> Void = { _, _ in }
    ) async throws -> (AppModel, StubMediaServer, MetadataStore) {
        // key 必须在造 `AppModel` **之前**写进隔离域：协调器在 init 时读一次
        // `isConfigured`（见 `TMDbCoordinator.init`）。
        if configureKey {
            defaults.set("0123456789abcdef0123456789abcdef",
                         forKey: TMDbCredentialStore.defaultsKey)
        }
        let app = AppModel(preferences: try XCTUnwrap(defaults))
        app.metadata.setup(directory: directory)
        let ready = await app.metadata.waitUntilReady()
        XCTAssertTrue(ready, "临时目录建库应成功")
        let store = try XCTUnwrap(app.metadata.activeStore)
        // 补全服务由 `AppModel.bootstrap()` 在生产路径上装配，而测试宿主整段跳过
        // bootstrap（`RuntimeEnvironment.isRunningTests`），所以这里补上同一步——
        // 不装配的话 `enricher` 恒为 nil，overlay 永远读不到，用例会「碰巧通过」。
        app.tmdb.attach(store: store)
        let stub = StubMediaServer()
        try await seed(store, TenantID(profile: stub.profile))
        app.phase = .ready
        app.server = stub
        app.sessionGeneration = 1
        return (app, stub, store)
    }

    private func boxSet(name: String = "新世纪福音战士新剧场版（系列）") -> MediaItem {
        MediaItem(id: "box-1", name: name, kind: .boxSet, childCount: 2)
    }

    private func member(_ id: String, backdrop: String?) -> MediaItem {
        MediaItem(id: id, name: id, kind: .movie, year: 2012, backdropImageTag: backdrop)
    }

    /// 有服务端海报的成员（库卡拼图用的是它们的 Primary 图）。
    private func posterMember(_ id: String, poster: String) -> MediaItem {
        MediaItem(id: id, name: id, kind: .movie, year: 2012, primaryImageTag: poster)
    }

    private func boxsetsLibrary(id: String = "lib-boxsets") -> MediaLibrary {
        MediaLibrary(id: id, name: "合集", collectionType: .boxsets)
    }

    // MARK: - 媒体库卡封面（首页「媒体库」那排）

    /// 合集库在服务端一张图都没有（7 种图片类型全 404），所以用**成员电影的海报**
    /// 拼一张：列合集（1 请求）+ 每个合集一次成员请求。
    ///
    /// 同时钉住**轮转取图**：先每个合集各来一张，再回头取第二张——这样 2×2 里两个
    /// 合集都露面，而不是被第一个合集的成员占满。
    func testBoxsetsLibraryCoverIsBuiltFromMemberPosters() async throws {
        let (app, stub, _) = try await makeApp()
        let box1 = MediaItem(id: "box-1", name: "EVA", kind: .boxSet)
        let box2 = MediaItem(id: "box-2", name: "中二病", kind: .boxSet)
        stub.itemsPageByParent = [
            "lib-boxsets": MediaItemsPage(items: [box1, box2], startIndex: 0, totalRecordCount: 2),
            "box-1": MediaItemsPage(items: [posterMember("eva-1", poster: "pe1"),
                                            posterMember("eva-2", poster: "pe2")],
                                    startIndex: 0, totalRecordCount: 2),
            "box-2": MediaItemsPage(items: [posterMember("chu-1", poster: "pc1"),
                                            posterMember("chu-2", poster: "pc2")],
                                    startIndex: 0, totalRecordCount: 2),
        ]

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())

        let ids = app.libraryCoverURLs(for: boxsetsLibrary()).map { url -> String in
            url.absoluteString.split(separator: "/").dropLast(2).last.map(String.init) ?? ""
        }
        XCTAssertEqual(ids, ["eva-1", "chu-1", "eva-2", "chu-2"],
                       "轮转取：两个合集各先出一张，再回头补第二张")
        let urls = app.libraryCoverURLs(for: boxsetsLibrary())
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains("Images/Primary") })
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains("tag=p") },
                      "tag 要进 URL，海报换了缓存才会失效")
    }

    /// 服务端**已经给了**库封面（电视剧 / 电影那两个库）→ 一个请求都不发。
    func testLibraryWithServerCoverIsUntouched() async throws {
        let (app, stub, _) = try await makeApp()
        let withCover = MediaLibrary(id: "lib-movies", name: "电影",
                                     collectionType: .movies, primaryImageTag: "cover")

        await app.resolveLibraryCoverIfNeeded(for: withCover)

        XCTAssertEqual(stub.callCount("itemsPage"), 0)
        XCTAssertTrue(app.libraryCoverURLs(for: withCover).isEmpty)
    }

    /// 解析成功后再调一次：不发请求（已记账）。卡片每次进入可视区都会调它。
    func testLibraryCoverResolvesOnlyOnce() async throws {
        let (app, stub, _) = try await makeApp()
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [posterMember("m-1", poster: "p1")], startIndex: 0, totalRecordCount: 1))

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())
        let calls = stub.callCount("itemsPage")
        XCTAssertGreaterThan(calls, 0)

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())
        XCTAssertEqual(stub.callCount("itemsPage"), calls, "已解析过就不该再发请求")
    }

    /// 列表都拉不到（断网）：**不记账**，下次进入可视区还要能再试。
    func testLibraryCoverDoesNotRecordTransportFailure() async throws {
        let (app, stub, _) = try await makeApp()
        stub.itemsPageResult = .failure(JellyfinError(.transport("请求超时。")))

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())

        XCTAssertTrue(app.libraryCoverURLs(for: boxsetsLibrary()).isEmpty)
        XCTAssertFalse(app.libraryCoverAttempted.contains("lib-boxsets"),
                       "失败不记账，否则一次断网就让库卡永远空白")
    }

    /// 库里一条有海报的内容都没有 → 记账但不拼图（落回占位图标，不再重复请求）。
    func testLibraryWithoutAnyPosterIsRecordedButEmpty() async throws {
        let (app, stub, _) = try await makeApp()
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [MediaItem(id: "m-1", name: "没海报", kind: .movie)],
            startIndex: 0, totalRecordCount: 1))

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())

        XCTAssertTrue(app.libraryCoverURLs(for: boxsetsLibrary()).isEmpty)
        XCTAssertTrue(app.libraryCoverAttempted.contains("lib-boxsets"), "确定拼不出来就记账")
    }

    /// 同时最多拼 `libraryCoverCount` 张（2×2 的容量），多出来的成员不取。
    func testLibraryCoverIsCappedAtFour() async throws {
        let (app, stub, _) = try await makeApp()
        stub.itemsPageResult = .success(MediaItemsPage(
            items: (1...6).map { posterMember("m-\($0)", poster: "p\($0)") },
            startIndex: 0, totalRecordCount: 6))

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())

        XCTAssertEqual(app.libraryCoverURLs(for: boxsetsLibrary()).count, 4)
    }

    /// 换会话清空（库 id 与图 URL 都只在那台服务器上有意义）。
    func testLibraryCoverIsClearedOnSessionReset() async throws {
        let (app, stub, _) = try await makeApp()
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [posterMember("m-1", poster: "p1")], startIndex: 0, totalRecordCount: 1))
        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())
        XCTAssertFalse(app.libraryCoverURLs(for: boxsetsLibrary()).isEmpty)

        app.resetBrowseState()

        XCTAssertTrue(app.libraryCoverURLs(for: boxsetsLibrary()).isEmpty)
    }

    // MARK: - 标题：用户给合集起的名字不许被 TMDb 顶掉

    /// 实测两边的名字并不一样：Jellyfin「新世纪福音战士新剧场版（系列）」
    /// vs TMDb「福音战士新剧场版（系列）」。合集名是**用户自己的标签**，
    /// 被顶掉会让页面标题与合集库/侧栏对不上。
    func testCollectionKeepsServerNameOverTMDbTitle() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            try await store.saveTMDbLink(itemID: "box-1", entityKey: .collection(210303),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
            try await store.saveTMDbPayload(
                .entity(TMDbEntity(id: 210303, mediaType: .collection,
                                   title: "福音战士新剧场版（系列）", overview: "再构建作品。")),
                key: .collection(210303), language: "zh-CN", lifetime: 3600)
        }
        let box = boxSet()
        stub.itemResult = .success(box)

        // 走真实加载路径（overlay 是在 `load()` 里读进来的）：只 attach 不 load 的话
        // `tmdbOverlay` 恒为 nil，断言会「碰巧通过」，测不出接线对不对。
        let model = DetailViewModel(item: box)
        model.attach(app)
        await model.load()

        XCTAssertNotNil(model.tmdbOverlay, "已落库的 TMDb 合集数据应当被读进来")
        XCTAssertEqual(model.displayName, "新世纪福音战士新剧场版（系列）",
                       "合集标题用服务端（用户起的）名字")
        XCTAssertEqual(model.displayOverview, "再构建作品。", "简介仍由 TMDb 补缺")
    }

    /// 剧集仍按「TMDb 文本优先」——上面那条只管合集，别把既有行为改坏。
    func testSeriesStillPrefersTMDbTitle() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            try await store.saveTMDbLink(itemID: "s-1", entityKey: .tv(71785),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
            try await store.saveTMDbPayload(
                .entity(TMDbEntity(id: 71785, mediaType: .tv, title: "TMDb 标题")),
                key: .tv(71785), language: "zh-CN", lifetime: 3600)
        }
        let series = MediaItem(id: "s-1", name: "服务端标题", kind: .series)
        stub.itemResult = .success(series)

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()

        XCTAssertNotNil(model.tmdbOverlay)
        XCTAssertEqual(model.displayName, "TMDb 标题")
    }

    // MARK: - 背景图：三个来源的优先级

    /// 合集自己没有背景图（实测 `ImageTags: {}`）→ 用**第一个带图的成员**兜底。
    func testCollectionBackdropFallsBackToFirstMember() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: boxSet())
        model.attach(app)
        model.collectionMembers = [
            member("m-1", backdrop: nil),
            member("m-2", backdrop: "bd-2"),
        ]

        XCTAssertTrue(model.hasBackdrop, "成员有背景图，就该走氛围布局")
        let target = model.backdropTarget(width: 800)
        XCTAssertEqual(target.url?.absoluteString.contains("m-2"), true,
                       "取第一个**有图**的成员，实际: \(target.url?.absoluteString ?? "nil")")
        XCTAssertEqual(target.authHeader, app.server?.authorizationHeader)
    }

    /// 一个成员都没有背景图 → 没有背景，退回老横幅布局（不硬凑一张图）。
    func testCollectionWithoutAnyBackdropHasNone() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: boxSet())
        model.attach(app)
        model.collectionMembers = [member("m-1", backdrop: nil)]

        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(model.backdropTarget(width: 800).url)
    }

    /// 非合集条目**不许**借用成员兜底（电影缺背景图时拿别人的图是错的）。
    func testNonCollectionNeverUsesMemberFallback() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: MediaItem(id: "m-1", name: "电影", kind: .movie))
        model.attach(app)
        model.collectionMembers = [member("m-2", backdrop: "bd-2")]

        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(model.backdropTarget(width: 800).url)
    }

    /// 服务端自己有背景图时，**不看** TMDb / 成员兜底（默认策略下服务端优先）。
    func testServerBackdropWins() async throws {
        let (app, _, _) = try await makeApp()
        let item = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                             backdropImageTag: "server-bd")
        let model = DetailViewModel(item: item)
        model.attach(app)
        model.collectionMembers = [member("m-2", backdrop: "bd-2")]

        let target = model.backdropTarget(width: 800)
        XCTAssertTrue(target.url?.absoluteString.contains("server-bd") == true,
                      "实际: \(target.url?.absoluteString ?? "nil")")
        XCTAssertTrue(model.hasBackdrop)
    }

    // MARK: - 网格卡的封面（合集库）

    /// 详情页读到的海报要**递给网格卡**：这样「先点开详情、再回合集库」是零请求的
    /// （实测用户就是这么发现网格空着的——详情页有图、外部没有）。
    func testDetailNotesPosterForLibraryGrid() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            try await store.saveTMDbLink(itemID: "box-1", entityKey: .collection(210303),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
            try await store.saveTMDbPayload(
                .entity(TMDbEntity(id: 210303, mediaType: .collection,
                                   title: "福音战士新剧场版（系列）",
                                   posterPath: "/eva-poster.jpg")),
                key: .collection(210303), language: "zh-CN", lifetime: 3600)
        }
        let box = boxSet()
        stub.itemResult = .success(box)
        let model = DetailViewModel(item: box)
        model.attach(app)
        await model.load()

        let url = app.collectionPosterURL(for: box, width: 400)
        XCTAssertEqual(url?.absoluteString, "https://image.tmdb.org/t/p/w500/eva-poster.jpg",
                       "网格卡应拿到 TMDb 合集海报")
    }

    /// 网格解析：列一次成员 → 命中已落库的 TMDb 对应（**零 TMDb 请求**）→ 出图；
    /// 再调一次直接早退（卡片每次进入可视区都会调它，这是成本闸门）。
    func testResolveCollectionArtworkThenStopsAsking() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            // 预置对应 + 数据 → `refreshCollection` 走缓存早退，全程不打 TMDb。
            // **必须预置**：不预置的话定位会真去打 api.themoviedb.org（用例会慢到
            // 分钟级且依赖网络），而 TMDb 的定位逻辑本身已在 `TMDbCollectionTests`
            // 里用 `URLProtocol` 桩逐条覆盖过了。
            try await store.saveTMDbLink(itemID: "box-1", entityKey: .collection(210303),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
            try await store.saveTMDbPayload(
                .entity(TMDbEntity(id: 210303, mediaType: .collection,
                                   posterPath: "/eva-poster.jpg")),
                key: .collection(210303), language: "zh-CN", lifetime: 3600)
        }
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [MediaItem(id: "m-q", name: "Q", kind: .movie, tmdbID: "75629")],
            startIndex: 0, totalRecordCount: 1))
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertEqual(app.collectionPosterURL(for: box, width: 400)?.absoluteString,
                       "https://image.tmdb.org/t/p/w500/eva-poster.jpg",
                       "width 400 取不小于它的最小档 = w500")
        XCTAssertEqual(stub.callCount("itemsPage"), 1, "列一次成员")
        XCTAssertTrue(app.collectionArtworkAttempted.contains(box.id))

        await app.resolveCollectionArtworkIfNeeded(for: box)
        XCTAssertEqual(stub.callCount("itemsPage"), 1, "已解析过就不该再发请求")
    }

    /// 成员列出了、但定位不出 TMDb 合集：这是**确定结论**（TMDb 上没有 / 成员没 id），
    /// 记账，免得每次滚回来都重新列一遍成员。
    func testResolveCollectionArtworkRecordsDefinitiveNoMatch() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            try await store.saveTMDbLink(itemID: "box-1", entityKey: .collection(210303),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
        }
        // 成员没有 `ProviderIds["Tmdb"]`：定位不出来，且**一个 TMDb 请求都不会发**。
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [MediaItem(id: "m-1", name: "未刮削", kind: .movie)],
            startIndex: 0, totalRecordCount: 1))
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertNil(app.collectionPosterURL(for: box, width: 400))
        XCTAssertTrue(app.collectionArtworkAttempted.contains(box.id), "确定没有就记账")
        XCTAssertEqual(stub.callCount("itemsPage"), 1)

        await app.resolveCollectionArtworkIfNeeded(for: box)
        XCTAssertEqual(stub.callCount("itemsPage"), 1, "记账后不再重复列成员")
    }

    /// 成员列表本身拉不到（断网 / 服务端出错）：**不记账**，下次进入可视区还要能再试。
    /// 记了的话，一次断网就会让这些卡片此后永远空白。
    func testResolveCollectionArtworkDoesNotRecordTransportFailure() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true)
        stub.itemsPageResult = .failure(JellyfinError(.transport("请求超时。")))
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertNil(app.collectionPosterURL(for: box, width: 400))
        XCTAssertFalse(app.collectionArtworkAttempted.contains(box.id),
                       "失败不记账，否则一次断网就让卡片永远空白")
    }

    /// 服务端自己有封面的条目**不许**被 TMDb 顶掉（「只补缺」策略）。
    func testGridPosterIsNotOverriddenWhenServerHasOne() async throws {
        let (app, _, _) = try await makeApp(configureKey: true)
        app.noteCollectionArtwork(itemID: "box-1", posterPath: "/eva-poster.jpg")
        let withServerImage = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                                        primaryImageTag: "server-tag")

        XCTAssertNil(app.collectionPosterURL(for: withServerImage, width: 400))
    }

    /// 非合集条目不吃这份缓存（电影不该因为 id 相同就用上合集的海报）。
    func testGridPosterOnlyAppliesToCollections() async throws {
        let (app, _, _) = try await makeApp(configureKey: true)
        app.noteCollectionArtwork(itemID: "m-1", posterPath: "/eva-poster.jpg")

        XCTAssertNil(app.collectionPosterURL(for: MediaItem(id: "m-1", name: "电影", kind: .movie),
                                             width: 400))
    }

    /// 没配 TMDb key 时网格不做任何事（连成员列表都不拉）。
    func testResolveCollectionArtworkIsNoOpWithoutKey() async throws {
        let (app, stub, _) = try await makeApp()
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertEqual(stub.callCount("itemsPage"), 0)
        XCTAssertNil(app.collectionPosterURL(for: box, width: 400))
    }

    /// 非合集条目不触发解析（库网格里电影/剧集的卡片也会 onAppear）。
    func testResolveCollectionArtworkIgnoresNonCollections() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true)

        await app.resolveCollectionArtworkIfNeeded(
            for: MediaItem(id: "m-1", name: "电影", kind: .movie))

        XCTAssertEqual(stub.callCount("itemsPage"), 0)
    }

    /// 换会话清空（id 只在那台服务器上有意义）。
    func testCollectionArtworkIsClearedOnSessionReset() async throws {
        let (app, _, _) = try await makeApp(configureKey: true)
        app.noteCollectionArtwork(itemID: "box-1", posterPath: "/eva-poster.jpg")
        XCTAssertNotNil(app.collectionPosterURL(for: boxSet(), width: 400))

        app.resetBrowseState()

        XCTAssertNil(app.collectionPosterURL(for: boxSet(), width: 400))
    }

    // MARK: - 没配 TMDb 时不许出岔子

    /// 成员为空（离线首进 / 成员请求失败）+ 没配 TMDb key：整条路静默跳过，不崩不卡。
    func testCollectionOverlayIsNoOpWithoutKeyOrMembers() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: boxSet())
        model.attach(app)

        await model.loadCollectionOverlay()

        XCTAssertNil(model.tmdbOverlay)
        XCTAssertFalse(model.hasBackdrop)
    }
}
