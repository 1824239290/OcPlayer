import AppDesignKit
import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
import XCTest

/// 合集详情页的展示策略（真 AppModel + 真 SQLite + 替身服务器，**全部离线**）。
///
/// 这一层要守住的是「接线对不对」：TMDB 的合集数据接上了没有、标题该不该被顶替、
/// 背景图的三个来源谁优先。包内单测（`TMDbCollectionTests`）只证明「能定位到 TMDB 合集」，
/// 证明不了页面会把它用起来。
@MainActor
final class CollectionDetailTests: XCTestCase {

    /// 按**当前生效的图片根**拼 TMDB 图片地址（镜像源会换掉 host/前缀）。
    /// 用例里不写死 `image.tmdb.org`：设了镜像的开发机上写死必红，
    /// 而这里真正要钉的是「哪张图、哪个档位」。
    static func tmdbImageURL(_ path: String, size: String) -> String {
        TMDbEndpointSettings().endpoints.imageURL(
            path: "/\(path)", size: TMDbImageSize(rawValue: size) ?? .w500
        )?.absoluteString ?? ""
    }

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
        tmdbSession: URLSessionConfiguration? = nil,
        seed: (MetadataStore, TenantID) async throws -> Void = { _, _ in }
    ) async throws -> (AppModel, StubMediaServer, MetadataStore) {
        // key 必须在造 `AppModel` **之前**写进隔离域：协调器在 init 时读一次
        // `isConfigured`（见 `TMDbCoordinator.init`）。
        if configureKey {
            defaults.set("0123456789abcdef0123456789abcdef",
                         forKey: TMDbCredentialStore.defaultsKey)
        }
        // 注入 `tmdbSession` 才换得掉 TMDB 的网络：不注入时协调器用生产会话，
        // App 层「TMDB 请求失败」的分支就造不出来（见 `TMDbCoordinator.init` 的注释）。
        let app = AppModel(
            tmdb: TMDbCoordinator(defaults: try XCTUnwrap(defaults),
                                  sessionConfiguration: tmdbSession),
            preferences: try XCTUnwrap(defaults))
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

    // MARK: - 标题：用户给合集起的名字不许被 TMDB 顶掉

    /// 实测两边的名字并不一样：Jellyfin「新世纪福音战士新剧场版（系列）」
    /// vs TMDB「福音战士新剧场版（系列）」。合集名是**用户自己的标签**，
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

        XCTAssertNotNil(model.tmdbOverlay, "已落库的 TMDB 合集数据应当被读进来")
        XCTAssertEqual(model.displayName, "新世纪福音战士新剧场版（系列）",
                       "合集标题用服务端（用户起的）名字")
        XCTAssertEqual(model.displayOverview, "再构建作品。", "简介仍由 TMDB 补缺")
    }

    /// 剧集仍按「TMDB 文本优先」——上面那条只管合集，别把既有行为改坏。
    func testSeriesStillPrefersTMDbTitle() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            try await store.saveTMDbLink(itemID: "s-1", entityKey: .tv(71785),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
            try await store.saveTMDbPayload(
                .entity(TMDbEntity(id: 71785, mediaType: .tv, title: "TMDB 标题")),
                key: .tv(71785), language: "zh-CN", lifetime: 3600)
        }
        let series = MediaItem(id: "s-1", name: "服务端标题", kind: .series)
        stub.itemResult = .success(series)

        let model = DetailViewModel(item: series)
        model.attach(app)
        await model.load()

        XCTAssertNotNil(model.tmdbOverlay)
        XCTAssertEqual(model.displayName, "TMDB 标题")
    }

    // MARK: - 背景图：三个来源的优先级
    //
    // 下面四条都必须先 `await model.resolveBackdropSource()` 再断言。
    // 理由（2026-11-03「背景闪图」修复的语义）：`DetailViewModel.backdropTarget`
    // 走 `BackdropSourceLatch`，**解析完成前一律返回 nil**（那条语义用来堵住
    // 「app 已挂上、overlay 还没读回」那一帧把服务端图画出去的窗口）。
    // 只 `attach` 不解析的话，四条拿到的都是 nil：
    //   * 两条正向用例会假性失败（规则根本没被验到）；
    //   * 两条「应当没有背景」的用例会**碰巧通过**（nil 是因为没解析，不是因为没图）。
    // 所以这个序列属于被测行为的一部分，不是测试脚手架。

    /// 合集自己没有背景图（实测 `ImageTags: {}`）→ 用**第一个带图的成员**兜底。
    func testCollectionBackdropFallsBackToFirstMember() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: boxSet())
        model.attach(app)
        await model.resolveBackdropSource()
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
        await model.resolveBackdropSource()
        model.collectionMembers = [member("m-1", backdrop: nil)]

        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(model.backdropTarget(width: 800).url)
    }

    /// 非合集条目**不许**借用成员兜底（电影缺背景图时拿别人的图是错的）。
    func testNonCollectionNeverUsesMemberFallback() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: MediaItem(id: "m-1", name: "电影", kind: .movie))
        model.attach(app)
        await model.resolveBackdropSource()
        model.collectionMembers = [member("m-2", backdrop: "bd-2")]

        XCTAssertFalse(model.hasBackdrop)
        XCTAssertNil(model.backdropTarget(width: 800).url)
    }

    /// 服务端自己有背景图时，**不看** TMDB / 成员兜底（默认策略下服务端优先）。
    func testServerBackdropWins() async throws {
        let (app, _, _) = try await makeApp()
        let item = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                             backdropImageTag: "server-bd")
        let model = DetailViewModel(item: item)
        model.attach(app)
        await model.resolveBackdropSource()
        model.collectionMembers = [member("m-2", backdrop: "bd-2")]

        let target = model.backdropTarget(width: 800)
        XCTAssertTrue(target.url?.absoluteString.contains("server-bd") == true,
                      "实际: \(target.url?.absoluteString ?? "nil")")
        XCTAssertTrue(model.hasBackdrop)
    }

    /// 解析完成前**必须扣住**背景图（`nil`），解析后立刻给出。
    ///
    /// 这条钉的是「背景不闪」的接线本身：视图在 `attach` 之后、`load()` 的第一次
    /// await 返回之前会渲染一帧，那时若 `backdropTarget` 提前给出服务端图，
    /// 用户就会看到「服务端图 → TMDB 图」的二次顶替。把它改成恒返回 nil，
    /// 这条立刻变红（「预期解析后就该给图」那一半）。
    func testBackdropTargetIsWithheldUntilSourceResolved() async throws {
        let (app, _, _) = try await makeApp()
        let item = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                             backdropImageTag: "server-bd")
        let model = DetailViewModel(item: item)
        model.attach(app)

        XCTAssertFalse(model.isBackdropSourceResolved)
        XCTAssertNil(model.backdropTarget(width: 800).url,
                     "解析完成前不该把本条目的图交给视图（否则会画出第一张再被顶掉）")

        await model.resolveBackdropSource()
        XCTAssertTrue(model.isBackdropSourceResolved)
        XCTAssertTrue(model.backdropTarget(width: 800).url?.absoluteString.contains("server-bd") == true,
                      "解析完成后必须立刻给出最终那张")
    }

    /// `load()` 必须在**内容提前 return 之前**解析完背景图来源。
    ///
    /// ## 这条用例的第一版名不副实（2026-11-03 审查实测，已重写）
    ///
    /// 第一版只断言「`load()` 跑完后 `isBackdropSourceResolved == true`」，并且走的是
    /// **冷启动路径**（`cachedDetail` 返回 nil）。审查把 `await resolveBackdropSource()`
    /// 从 `load()` 第一句挪到最后一句，它**照样全绿** —— 因为它没有任何顺序观测点：
    /// 无论解析在开头还是结尾，函数返回时那个标志都是 true。
    ///
    /// ## 现在钉的是真正的生产回归：`cached.isFresh` 那条提前 `return`
    ///
    /// `load()` 命中「内存且新鲜」的快照时会在中途 `return`（不再走网络确认）。
    /// 解析一旦被挪到这段 `return` **之后**，重进页就永远不会解析 ⇒ latch 永不置位
    /// ⇒ `backdropTarget` 恒返回 nil ⇒ 页面永久停在氛围池**别的条目**的兜底图上，
    /// 本条目的图一次都不出，而且不报错。这正是审查指出的那条失效路径。
    ///
    /// 所以这里必须先真的造出「新鲜内存快照」，否则用例会悄悄退化回冷启动路径、
    /// 重新失去判别力 —— 中间那两条 `XCTAssert` 就是在守这件事本身。
    ///
    /// ## 它证伪不了什么（别把它当万能）
    ///
    /// 把解析挪到「内容落地之后、提前 return 之前」这种更窄的位置，这条抓不住：
    /// 那种写法退回到「先画服务端图再换 TMDB 图」的闪图问题，由
    /// `testBackdropTargetIsWithheldUntilSourceResolved`（解析前必须扣住）与
    /// `testLateContentBackdropIsLockedOnce`（迟到补锁后不再改口）共同覆盖。
    func testLoadResolvesBackdropSourceBeforeContent() async throws {
        let (app, stub, _) = try await makeApp()
        let item = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                             backdropImageTag: "server-bd")
        stub.itemResult = .success(item)

        // 先真跑一轮刷新，把快照写进仓储**内存**：`MediaSnapshot.isFresh` 要求
        // `source != .disk`，从磁盘读回来的恒为 false，走不出提前 return 那条分支。
        _ = try await app.metadata.refreshDetail(itemID: item.id, kindHint: .boxSet)
        let seeded = await app.metadata.cachedDetail(itemID: item.id)
        XCTAssertNotNil(seeded, "预热应当写回快照")
        XCTAssertTrue(seeded?.isFresh(ttl: 60) == true,
                      "必须命中「内存且新鲜」的快照，否则本用例退化回冷启动路径、失去判别力")

        let model = DetailViewModel(item: item)
        model.attach(app)

        await model.load()

        XCTAssertTrue(model.isBackdropSourceResolved,
                      "load() 必须在命中新鲜快照后提前 return **之前**解析完背景来源")
        XCTAssertNotNil(model.detail, "确实走了快照落地那条路径（不是冷启动）")
        XCTAssertTrue(model.backdropTarget(width: 800).url?.absoluteString.contains("server-bd") == true,
                      "解析完后本条目的图必须能取到，实际: \(model.backdropTarget(width: 800).url?.absoluteString ?? "nil")")
    }

    /// 解析那一刻没图可锁（`shown` 还是不带 tag 的列表条目）⇒ 详情落地时**补锁**，
    /// 且之后不再改口。
    ///
    /// ## 这条守的是「锁窗口被关太早」那个退化（2026-11-03 审查发现）
    ///
    /// 把锁定逻辑从 `BackdropSourceLatch` 搬进 VM 之后，`lockBackdropTargetsIfNeeded()`
    /// 只在 `resolveBackdropSource()` 那一刻算一次。而解析在 `load()` 第一句，那时
    /// `shown` 还是列表带来的条目、常常没有 backdrop tag ⇒ 全返回 nil ⇒ **一个档都没锁**。
    /// 之后缓存详情落地（服务端图出现）、后台 TMDB 补齐（TMDB 图出现）都会让
    /// `backdropTarget` 现算出不同的图，服务端图被 TMDB 顶掉，**闪图原样回归**。
    ///
    /// 补锁挂在 `detail.didSet` / `tmdbOverlay.didSet` 上（既有状态变更点，不在 body
    /// 求值路径上）。这条用例钉住两件事：
    /// 1. 迟到落地的详情能把图补上（不是永久 nil）；
    /// 2. 补锁之后再来一次详情变化也**不覆盖**已锁的值（「本页不改口」）。
    ///
    /// ## 判别力只来自第 3 条断言（审查变异实测，别被前两条骗了）
    ///
    /// 审查把 `detail.didSet` 里的补锁删掉做变异，结果：
    /// - 第 1 条断言（解析时 nil）**仍绿**
    /// - 第 2 条断言（详情落地后有图）**也仍绿** —— 因为 `backdropTarget` 缓存未命中时
    ///   会走「现算不写」分支，碰巧算出同一张服务端图。**它不具判别力。**
    /// - 只有第 3 条（换成 `server-bd-v2` 后必须仍是 `server-bd`）会红
    ///
    /// 所以第 2 条只是「接线通不通」的冒烟，**真正守补锁的是第 3 条**。
    /// 改这个文件时别把第 3 条当成冗余删掉。
    func testLateContentBackdropIsLockedOnce() async throws {
        let (app, _, _) = try await makeApp()
        // 列表带来的条目：没有 backdrop tag。
        let landed = MediaItem(id: "box-1", name: "合集", kind: .boxSet)
        let model = DetailViewModel(item: landed)
        model.attach(app)
        await model.resolveBackdropSource()

        // 不具判别力的冒烟断言：删掉补锁它也会绿（见上面的变异记录）。
        XCTAssertNil(model.backdropTarget(width: 800).url,
                     "解析那一刻没有 tag，算不出图，本来就该是 nil")

        // 详情落地：tag 出现。
        model.detail = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                                 backdropImageTag: "server-bd")
        // 冒烟：接线通不通。**不是**补锁的守护者（删掉补锁它仍绿）。
        XCTAssertTrue(model.backdropTarget(width: 800).url?.absoluteString.contains("server-bd") == true,
                      "详情落地必须补锁上服务端图，实际: \(model.backdropTarget(width: 800).url?.absoluteString ?? "nil")")

        // 同一个页面里详情再变一次（换了个 tag）：已锁的档不覆盖。
        // ↓ 这两条才是补锁的真正判别点（变异实验里唯一会红的）。
        model.detail = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                                 backdropImageTag: "server-bd-v2")
        XCTAssertTrue(model.backdropTarget(width: 800).url?.absoluteString.contains("server-bd") == true,
                      "已锁的档不许因迟到数据改口，实际: \(model.backdropTarget(width: 800).url?.absoluteString ?? "nil")")
        XCTAssertFalse(model.backdropTarget(width: 800).url?.absoluteString.contains("server-bd-v2") == true,
                       "闪图的定义就是这一条：同一条目的两张图先后上屏")
    }

    /// 取详情那一刻，背景图来源必须**已经解析完**（顺序的真实观测点）。
    ///
    /// ## 观测点：`onApplyDetailContent`（上屏那一刻），不再是 `onItemCall`
    ///
    /// 早先用的是 `StubMediaServer.onItemCall`（`item()` 入口）。它在**内存未命中**时
    /// 确实落在「解析之后、上屏之前」，方向对；但有两个坑（Review 2026-11-03 读
    /// `MediaRepository+Detail.swift` 指出，已核）：
    /// 1. **内存命中**路径 `cachedDetail` 直接返回、根本不调 `item` ⇒ 钩子零触发；
    /// 2. stale 路径会触发**两次**（`cachedDetail` 一次 + `refreshDetail` 一次）。
    /// 之前这条用例能过，只是因为 `makeApp()` 每次建全新临时目录、必然内存未命中 ——
    /// 靠构造巧合，不是靠判据。
    ///
    /// 换成 `DetailViewModel.onApplyDetailContent`：`applyDetailContent` 是详情内容进入
    /// 各展示状态的**唯一入口**，内存命中 / 磁盘命中 / 网络刷新三条分支 100% 经过，
    /// 正好是「内容即将上屏」那一刻。它被调用的当下若 `isBackdropSourceResolved` 还是
    /// false，说明解析排在了上屏之后 —— 正是闪图的成因路径（先画②服务端图，再换③TMDB 图）。
    func testBackdropSourceResolvedBeforeDetailIsFetched() async throws {
        let (app, stub, _) = try await makeApp()
        let item = MediaItem(id: "box-1", name: "合集", kind: .boxSet,
                             backdropImageTag: "server-bd")
        stub.itemResult = .success(item)
        let model = DetailViewModel(item: item)
        model.attach(app)

        // 内容上屏那一刻的现场快照（取首次：stale 路径会调两次）。
        var observedAtApply: [(resolved: Bool, url: String?)] = []
        model.onApplyDetailContent = {
            observedAtApply.append((
                model.isBackdropSourceResolved,
                model.backdropTarget(width: 800).url?.absoluteString
            ))
        }

        await model.load()

        let first = try XCTUnwrap(observedAtApply.first, "详情内容应当至少上屏一次")
        XCTAssertTrue(first.resolved,
                      "内容上屏时背景图来源必须已解析完成（把 resolveBackdropSource() 挪到上屏之后即红）")
        XCTAssertEqual(first.url?.contains("server-bd"), true,
                       "内容上屏时 backdropTarget 就该给出最终那张，实际: \(first.url ?? "nil")")
    }

    func testLaterMemberPageSubmitsFirstBackdropPixels() async throws {
        try await assertMemberBackdropSubmission(reset: false)
    }

    func testRestoredMemberCacheSubmitsFirstBackdropPixels() async throws {
        try await assertMemberBackdropSubmission(reset: true)
    }

    private func assertMemberBackdropSubmission(reset: Bool) async throws {
        let (app, stub, _) = try await makeApp()
        let item = MediaItem(id: "late-member-box", name: "合集", kind: .boxSet)
        stub.itemResult = .success(item)
        #if os(macOS)
        let image = PlatformImage(size: CGSize(width: 2, height: 2))
        #else
        let image = PlatformImage()
        #endif
        var decodedTargets: [URL] = []
        let artwork = DetailBackdropArtwork(cachedImage: { url, _, pixels in
            guard pixels == DetailAmbienceImage.artDecodePixels else { return nil }
            decodedTargets.append(url)
            return image
        }, loader: { _, _, _ in
            XCTFail("本例的最终图片已缓存，不应发起异步加载")
            return nil
        })
        let model = DetailViewModel(item: item, backdropArtwork: artwork)
        model.attach(app)
        await model.load()
        XCTAssertNil(artwork.content, "首屏无图时不能提交其他来源")

        let member = MediaItem(id: "late-member", name: "电影", kind: .movie,
                               backdropImageTag: "late-art")
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [member], startIndex: 0, totalRecordCount: 1))
        if reset {
            _ = try await app.metadata.refreshCollectionMembers(itemID: item.id, startIndex: 0)
        }
        let calls = stub.callCount("itemsPage")
        await model.loadMembers(reset: reset)

        let snapshot = try XCTUnwrap(artwork.content, "成员到达后必须提交像素，只有来源锁不够")
        XCTAssertTrue(snapshot.image === image)
        XCTAssertTrue(snapshot.target.url?.absoluteString.contains("late-art") == true)
        XCTAssertTrue(snapshot.target.url?.absoluteString.contains("maxWidth=1600") == true)
        XCTAssertEqual(decodedTargets.count, 1)
        XCTAssertEqual(stub.callCount("itemsPage"), calls + (reset ? 0 : 1),
                       "缓存恢复不请求，分页只拉一个新窗口")
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
        // 期望值按**当前生效的图片根**拼（镜像源会换掉它）：这里要钉的是
        // 「网格卡拿到的是 TMDB 合集海报、且 width 400 → w500」，不是官方 CDN 的
        // 字面量——写死字面量会让设了镜像的开发机整片变红。
        XCTAssertEqual(url?.absoluteString, Self.tmdbImageURL("eva-poster.jpg", size: "w500"),
                       "网格卡应拿到 TMDB 合集海报")
    }

    /// 网格解析：列一次成员 → 命中已落库的 TMDB 对应（**零 TMDB 请求**）→ 出图；
    /// 再调一次直接早退（卡片每次进入可视区都会调它，这是成本闸门）。
    func testResolveCollectionArtworkThenStopsAsking() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            // 预置对应 + 数据 → `refreshCollection` 走缓存早退，全程不打 TMDB。
            // **必须预置**：不预置的话定位会真去打 api.themoviedb.org（用例会慢到
            // 分钟级且依赖网络），而 TMDB 的定位逻辑本身已在 `TMDbCollectionTests`
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
                       Self.tmdbImageURL("eva-poster.jpg", size: "w500"),
                       "width 400 取不小于它的最小档 = w500")
        XCTAssertEqual(stub.callCount("itemsPage"), 1, "列一次成员")
        XCTAssertTrue(app.collectionArtworkAttempted.contains(box.id))

        await app.resolveCollectionArtworkIfNeeded(for: box)
        XCTAssertEqual(stub.callCount("itemsPage"), 1, "已解析过就不该再发请求")
    }

    /// 成员列出了、但定位不出 TMDB 合集：这是**确定结论**（TMDB 上没有 / 成员没 id），
    /// 记账，免得每次滚回来都重新列一遍成员。
    func testResolveCollectionArtworkRecordsDefinitiveNoMatch() async throws {
        let (app, stub, _) = try await makeApp(configureKey: true) { store, tenant in
            try await store.saveTMDbLink(itemID: "box-1", entityKey: .collection(210303),
                                         source: .providerID, confidence: 1.0, tenant: tenant)
        }
        // 成员没有 `ProviderIds["Tmdb"]`：定位不出来，且**一个 TMDB 请求都不会发**。
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

    /// 服务端自己有封面的条目**不许**被 TMDB 顶掉（「只补缺」策略）。
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

    /// 没配 TMDB key 时网格不做任何事（连成员列表都不拉）。
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


    /// 成员请求失败**且一张海报都没拿到** → 不记账（可重试）。
    ///
    /// 这是「把失败吞成确定结论」那类缺陷的库卡版本：早先 `try?` 把成员请求的失败
    /// 吞成「这个合集没海报」，再记账，结果一次断网就让库卡永久空白。
    func testLibraryCoverWithFailedMemberLookupIsNotRecorded() async throws {
        let (app, stub, _) = try await makeApp()
        // 列合集成功、成员请求全部失败。
        stub.itemsPageByParent = [
            "lib-boxsets": MediaItemsPage(
                items: [MediaItem(id: "box-1", name: "EVA", kind: .boxSet)],
                startIndex: 0, totalRecordCount: 1),
        ]
        // 成员查询走 `itemsPageResult`（按 parentID 分派的字典里没有 box-1）→ 注入失败。
        stub.itemsPageResult = .failure(JellyfinError(.transport("请求超时。")))

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())

        XCTAssertTrue(app.libraryCoverURLs(for: boxsetsLibrary()).isEmpty)
        XCTAssertFalse(app.libraryCoverAttempted.contains("lib-boxsets"),
                       "成员请求失败不该被记成「确定没有海报」")
    }

    /// 个别合集的成员拉不到、但另一个合集给得出海报 → **存下来并记账**
    /// （画面已经可用，不该为一次局部失败把整张库卡丢掉）。
    func testLibraryCoverKeepsPartialResult() async throws {
        let (app, stub, _) = try await makeApp()
        stub.itemsPageByParent = [
            "lib-boxsets": MediaItemsPage(
                items: [MediaItem(id: "box-ok", name: "好的", kind: .boxSet)],
                startIndex: 0, totalRecordCount: 1),
            "box-ok": MediaItemsPage(
                items: [posterMember("m-1", poster: "p1")],
                startIndex: 0, totalRecordCount: 1),
        ]

        await app.resolveLibraryCoverIfNeeded(for: boxsetsLibrary())

        XCTAssertEqual(app.libraryCoverURLs(for: boxsetsLibrary()).count, 1)
        XCTAssertTrue(app.libraryCoverAttempted.contains("lib-boxsets"))
    }


    // MARK: - App 层：「失败」与「确定没有」的分野（补上前一批记录的覆盖缺口）

    /// **TMDB 请求失败时不许记账** —— 这条正是上一批修掉的那个缺陷的回归用例。
    ///
    /// 现场：`collectionArtworkAttempted` 是**会话级**缓存，一旦在断网时被写入，
    /// 这个合集在本会话内再也不会重试 → **卡片永久空白，只能重启 App**。
    /// 此前测不到是因为 `TMDbCoordinator` 的客户端硬编码、换不掉 TMDB 的网络；
    /// 现在能注入 `URLSessionConfiguration`，这条分支才第一次真正被测到。
    func testCollectionArtworkIsNotRecordedWhenTMDbRequestFails() async throws {
        // TMDB 侧全部失败（模拟断网）：成员列表（媒体服务器）正常，TMDB 请求打不通。
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.handler = nil }

        let member = MediaItem(id: "m-1", name: "Q", kind: .movie, tmdbID: "75629")
        let (app, stub, _) = try await makeApp(
            configureKey: true, tmdbSession: TestSupport.mockedSessionConfiguration())
        { store, _ in
            // 预置「模型自己」的 TMDB 对应，让定位不依赖网络也能走到「拉合集详情」那一步。
            // 注意：这里**不**预置合集载荷，于是 `fetchAndStore` 会真去拉 → 失败。
            _ = store
        }
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [member], startIndex: 0, totalRecordCount: 1))
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertNil(app.collectionPosterURL(for: box, width: 400))
        XCTAssertFalse(app.collectionArtworkAttempted.contains(box.id),
                       "TMDB 失败绝不能记账：记了就是「断网一次 → 本会话永久空白」")
    }

    /// 与上一条成对：TMDB **确实没有**这个合集（响应正常、只是没有对应）→ 记账。
    /// 两条一起把「可重试的失败」与「确定的没有」钉死在 App 层。
    func testCollectionArtworkIsRecordedWhenTMDbSaysNoMatch() async throws {
        // TMDB 正常响应，但不含 belongs_to_collection（`/movie/{id}` 与 `/collection/{id}`
        // 都走这个分支）。
        MockURLProtocol.handler = { request in
            let body = #"{"id":75629,"title":"福音战士新剧场版：Q","overview":"简介"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let member = MediaItem(id: "m-1", name: "Q", kind: .movie, tmdbID: "75629")
        let (app, stub, _) = try await makeApp(
            configureKey: true, tmdbSession: TestSupport.mockedSessionConfiguration())
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [member], startIndex: 0, totalRecordCount: 1))
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertTrue(app.collectionArtworkAttempted.contains(box.id),
                      "TMDB 明确说没有 → 记账，不必每次滚回来都重列成员")
    }

    /// 断网 → 恢复网络后**还能再试成功**（上一条「不记账」的收益闭环）。
    func testCollectionArtworkRetriesAfterFailureAndThenSucceeds() async throws {
        var tmdbs = 0
        MockURLProtocol.handler = { request in
            tmdbs += 1
            // 第一次调用（成员详情）直接失败；之后恢复正常。
            if tmdbs == 1 { throw URLError(.notConnectedToInternet) }
            // ⚠️ 两个端点的载荷**必须按路径分派**：合集载荷的 `id` 要等于合集 id，
            // 否则 `MetadataStore.tmdbPayload` 的 `matches(key)` 会（正确地）拒收它，
            // `fetchAndStore` 于是返回 false，用例会误报成「实现有问题」。
            let path = request.url?.path ?? ""
            let body = path.contains("/collection/")
                ? #"{"id":210303,"name":"EVA","poster_path":"/eva.jpg"}"#
                : #"{"id":75629,"title":"Q","belongs_to_collection":{"id":210303,"name":"EVA"}}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let member = MediaItem(id: "m-1", name: "Q", kind: .movie, tmdbID: "75629")
        let (app, stub, _) = try await makeApp(
            configureKey: true, tmdbSession: TestSupport.mockedSessionConfiguration())
        stub.itemsPageResult = .success(MediaItemsPage(
            items: [member], startIndex: 0, totalRecordCount: 1))
        let box = boxSet()

        await app.resolveCollectionArtworkIfNeeded(for: box)
        XCTAssertFalse(app.collectionArtworkAttempted.contains(box.id), "失败不记账")

        // 再试一次：这次 TMDB 通了，应当定位成功并落库。
        await app.resolveCollectionArtworkIfNeeded(for: box)

        XCTAssertTrue(app.collectionArtworkAttempted.contains(box.id),
                      "恢复后重试成功并记账")
    }

    // MARK: - 没配 TMDB 时不许出岔子

    /// 成员为空（离线首进 / 成员请求失败）+ 没配 TMDB key：整条路静默跳过，不崩不卡。
    func testCollectionOverlayIsNoOpWithoutKeyOrMembers() async throws {
        let (app, _, _) = try await makeApp()
        let model = DetailViewModel(item: boxSet())
        model.attach(app)

        await model.loadCollectionOverlay()

        XCTAssertNil(model.tmdbOverlay)
        XCTAssertFalse(model.hasBackdrop)
    }
}
