import CoreModel
@testable import OcPlayer
import XCTest

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    func testSignOutClearsNavPathsAndPlayerSession() {
        let app = AppModel()
        app.phase = .ready
        app.setNavPath([.detail(MediaItem(id: "series-1", name: "测试剧", kind: .series))], for: .home)
        app.presentedPlayer = PlaybackRequest(title: "ep", uri: "/tmp/a.mkv")
        app.playbackPreparation = .loading(title: "ep")
        app.handleStackPathChange([.detail(MediaItem(id: "m1", name: "电影", kind: .movie))])

        app.signOut()

        XCTAssertTrue(app.navPath(for: .home).isEmpty)
        XCTAssertNil(app.presentedPlayer)
        XCTAssertNil(app.playbackPreparation)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.phase, .onboarding)
        XCTAssertEqual(app.selectedSection, .home)
    }

    func testReconnectFlowClearsNavPaths() {
        let app = AppModel()
        app.phase = .ready
        app.setNavPath([.detail(MediaItem(id: "series-2", name: "另一部", kind: .series))], for: .bangumi)
        app.handleStackPathChange([.detail(MediaItem(id: "m2", name: "电影2", kind: .movie))])

        app.reconnectFlow()

        XCTAssertTrue(app.navPath(for: .bangumi).isEmpty)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.phase, .onboarding)
        XCTAssertEqual(app.selectedSection, .home)
    }

    /// 回归（僵尸 server）：401 之后磁盘 token 已删、内存 `server` 实例却还活着。
    /// `reconnectFlow` 必须走**完整**会话重置，否则用户点「先不登录」进 `.ready`
    /// 时首页会因为 `server != nil` 渲染旧服务器的数据，随即被下一个 401 再拉回
    /// 登录页——进不去「本地播放」。
    func testReconnectFlowDropsServerAndSessionScopedCaches() {
        let app = AppModel()
        app.phase = .ready
        app.server = StubMediaServer()
        app.libraries = [MediaLibrary(id: "lib-1", name: "电影", collectionType: .movies)]
        app.home = AppModel.HomeData(resume: [MediaItem(id: "ep-1", name: "第一集", kind: .episode)])
        app.cacheLibraryPage(
            AppModel.LibraryPage(items: [MediaItem(id: "m1", name: "电影", kind: .movie)], totalCount: 1),
            for: "lib-1")
        app.storeDetailSnapshot(
            AppModel.DetailSnapshot(detail: MediaItem(id: "s1", name: "剧", kind: .series),
                                    seasons: [], similar: [], selectedSeasonID: nil,
                                    episodesBySeason: [:]),
            for: "s1")
        app.pushWindowAmbience(
            id: UUID(),
            WindowAmbience(url: URL(string: "https://old.example/a.jpg"), authHeader: "Bearer old"))
        app.pendingMoviePilotQuery = "旧服务器的搜索词"

        app.reconnectFlow()

        XCTAssertNil(app.server, "内存里的 server 必须一起丢掉，否则会渲染旧服务器首页")
        XCTAssertTrue(app.libraries.isEmpty)
        XCTAssertTrue(app.home.resume.isEmpty)
        XCTAssertNil(app.detailSnapshot(for: "s1"), "详情快照按 item id 索引，跨服务器会撞 id")
        XCTAssertNil(app.windowAmbience, "氛围图带着旧服务器的 authHeader")
        XCTAssertNil(app.pendingMoviePilotQuery)
        XCTAssertEqual(app.phase, .onboarding)
    }

    /// 回归（声明被覆盖丢失）：详情页（声明 D）呈现资源搜索页（声明 R）后返回，
    /// 单值声明会被 R 的 onDisappear 清成 nil，D 已被覆盖、详情页不会再补发——
    /// 返回详情页背景照样丢。声明必须按栈恢复：离屏摘掉自己的条目、栈顶回到 D。
    func testWindowAmbienceStackRestoresCoveredDeclarationAfterPresentedDismiss() {
        let app = AppModel()
        let detailEntry = UUID()
        let resourceEntry = UUID()
        let detail = WindowAmbience(url: URL(string: "https://srv/detail.jpg"), authHeader: "Bearer a")
        let resource = WindowAmbience(url: URL(string: "https://srv/resource.jpg"), authHeader: "Bearer a")

        app.pushWindowAmbience(id: detailEntry, detail)
        XCTAssertEqual(app.windowAmbience, detail)
        app.pushWindowAmbience(id: resourceEntry, resource)
        XCTAssertEqual(app.windowAmbience, resource)

        // 资源搜索页返回：摘自己的条目，详情页的声明回到栈顶。
        app.removeWindowAmbience(id: resourceEntry)
        XCTAssertEqual(app.windowAmbience, detail)

        // 声明晚到 / 变化（详情页底图就绪才发）：原位换新，不得新增条目。
        let updated = WindowAmbience(url: URL(string: "https://srv/detail-v2.jpg"), authHeader: "Bearer a")
        app.updateWindowAmbience(id: detailEntry, updated)
        XCTAssertEqual(app.windowAmbience, updated)

        // 详情页离屏：栈空，整窗层回落到首页轮播。
        app.removeWindowAmbience(id: detailEntry)
        XCTAssertNil(app.windowAmbience)
    }

    /// 无氛围页（url 为空的声明）也占一层：详情页（有声明的）上呈现无 backdrop
    /// 的详情页时，整窗层不能漏出前者的氛围；它离屏后声明照常恢复。
    func testWindowAmbienceNilEntryCoversPreviousDeclaration() {
        let app = AppModel()
        let detailEntry = UUID()
        let detail = WindowAmbience(url: URL(string: "https://srv/d.jpg"), authHeader: nil)
        app.pushWindowAmbience(id: detailEntry, detail)

        let noBackdropEntry = UUID()
        app.pushWindowAmbience(id: noBackdropEntry, nil)
        XCTAssertNil(app.windowAmbience, "无氛围声明要盖住下层的声明")

        app.removeWindowAmbience(id: noBackdropEntry)
        XCTAssertEqual(app.windowAmbience, detail)
    }

    /// 回归：呈现式页面（`navigationDestination(isPresented:)`，如下载管理 /
    /// 管理服务器）**不在 `path` 上**，返回键若调 `back()` 会被 `guard !path.isEmpty`
    /// 整个吞掉——常规布局下就是「点了没反应」。这类页面必须走对称的 `popPresented`。
    func testPopPresentedDismissesWhileBackIsNoOpOnEmptyStack() {
        let app = AppModel()
        // 直切落地，省掉 0.45s 淡出等待（两段式的时序由 Motion token 保证）。
        app.reduceMotion = true
        app.phase = .ready

        app.back()
        XCTAssertTrue(app.path.isEmpty, "空栈上 back() 是空操作——正是呈现式页面踩的坑")

        var dismissed = false
        app.popPresented { dismissed = true }

        XCTAssertTrue(dismissed, "呈现式页面的返回必须真的关掉落地开关")
        XCTAssertFalse(app.routeExiting, "落地后不得留着退场态，否则整页卡在半透明")
    }

    /// 回归：compact（iPhone / iPad Tab）布局下 push 必须落到**当前 Tab 的独立栈**
    /// （`navPaths.<tab>`），落进常规布局的共享 `path` 等于点了没反应——Bangumi
    /// 「个人主页 / 每日放送」两个 toolbar 按钮是这条链最显性的探针。
    func testCompactPushLandsInTheSelectedTabsOwnStack() {
        let app = AppModel()
        app.reduceMotion = true   // 两段式直切落地，不等 0.45s 淡出
        app.setCompact(true)
        app.selectedSection = .bangumi

        app.openBangumiProfile()
        app.openBangumiCalendar()

        XCTAssertEqual(app.navPath(for: .bangumi).count, 2, "两个入口都必须进 Bangumi Tab 自己的栈")
        XCTAssertTrue(app.path.isEmpty, "compact 下共享栈不得被写入（只写不读 = 死按钮）")
    }

    /// 回归：快照超限曾整份 `removeAll()`，连刚写入的那条一起丢——第 41 次进入
    /// 详情页立刻退回冷骨架屏，SWR 的收益变成随机的。现在只淘汰最旧的。
    func testDetailSnapshotEvictionKeepsTheJustStoredEntry() {
        let app = AppModel()
        let limit = AppModel.detailSnapshotLimit

        for index in 0...limit {   // 写 limit+1 条，必定触发一次淘汰
            let id = "subject-\(index)"
            app.storeDetailSnapshot(
                AppModel.DetailSnapshot(detail: MediaItem(id: id, name: "条目\(index)", kind: .series),
                                        seasons: [], similar: [], selectedSeasonID: nil,
                                        episodesBySeason: [:]),
                for: id)
        }

        XCTAssertNotNil(app.detailSnapshot(for: "subject-\(limit)"), "刚写入的快照不得被本次淘汰带走")
        XCTAssertNil(app.detailSnapshot(for: "subject-0"), "最旧的应被淘汰")
        XCTAssertLessThanOrEqual(app.detailSnapshots.count, limit)
    }

    /// 读快照要刷新使用顺序，否则「刚看过的页」会被后续新页挤掉（与 LRU 相反）。
    func testDetailSnapshotReadRefreshesRecency() {
        let app = AppModel()
        let limit = AppModel.detailSnapshotLimit

        func snapshot(_ id: String) -> AppModel.DetailSnapshot {
            AppModel.DetailSnapshot(detail: MediaItem(id: id, name: id, kind: .series),
                                    seasons: [], similar: [], selectedSeasonID: nil,
                                    episodesBySeason: [:])
        }

        for index in 0..<limit { app.storeDetailSnapshot(snapshot("s\(index)"), for: "s\(index)") }
        _ = app.detailSnapshot(for: "s0")                     // 重新「看过」最旧的那条
        app.storeDetailSnapshot(snapshot("new"), for: "new")  // 触发一次淘汰

        XCTAssertNotNil(app.detailSnapshot(for: "s0"), "刚读过的条目应被保留")
        XCTAssertNil(app.detailSnapshot(for: "s1"), "应淘汰此后最旧的条目")
    }

    func testPresentLocalFileSetsPreparationWithoutTouchingHomeError() {
        let app = AppModel()
        app.phase = .onboarding
        app.home.error = nil

        let url = URL(fileURLWithPath: "/tmp/ocplayer-lifecycle-test.mkv")
        app.presentLocalFile(url)

        XCTAssertEqual(app.phase, .ready)
        XCTAssertNotNil(app.presentedPlayer)
        XCTAssertEqual(app.presentedPlayer?.uri, url.path)
        guard case .loading(let title) = app.playbackPreparation else {
            return XCTFail("local present must show preparation loading")
        }
        XCTAssertEqual(title, url.lastPathComponent)
        XCTAssertNil(app.home.error)
    }

    func testPlayerClosePolicyRejectsStaleDismissAfterNewRequest() {
        let oldID = UUID()
        let newID = UUID()
        XCTAssertTrue(PlayerClosePolicy.shouldDismiss(presentedID: oldID, closingID: oldID))
        XCTAssertFalse(PlayerClosePolicy.shouldDismiss(presentedID: newID, closingID: oldID))
        XCTAssertFalse(PlayerClosePolicy.shouldDismiss(presentedID: nil, closingID: oldID))
        XCTAssertFalse(PlayerClosePolicy.shouldDismiss(presentedID: oldID, closingID: nil))
    }

    func testDismissPlayerClearsPresentedPlayerAndNowPlayingItem() {
        let app = AppModel()
        app.phase = .ready
        let request = PlaybackRequest(title: "ep-1", uri: "/tmp/ep1.mkv")
        app.presentedPlayer = request
        app.nowPlayingItem = MediaItem(id: "ep-1", name: "第1集", kind: .episode)
        app.retryPlaybackItem = app.nowPlayingItem
        app.nextEpisode = nil

        app.dismissPlayer()

        XCTAssertNil(app.presentedPlayer)
        XCTAssertNil(app.nowPlayingItem)
        XCTAssertNil(app.retryPlaybackItem)
        XCTAssertNil(app.nextEpisode)
    }

    func testLibraryPageCursorIsRetainedPerLibrary() {
        let app = AppModel()
        let firstLibrary = MediaLibrary(id: "movies", name: "电影", collectionType: .movies)
        let secondLibrary = MediaLibrary(id: "shows", name: "剧集", collectionType: .tvshows)
        let firstPage = AppModel.LibraryPage(
            items: [MediaItem(id: "movie-1", name: "电影1", kind: .movie)],
            totalCount: 500,
            nextStartIndex: 200,
            lastPageWasFull: true
        )
        let secondPage = AppModel.LibraryPage(
            items: [MediaItem(id: "show-1", name: "剧集1", kind: .series)],
            totalCount: 300,
            nextStartIndex: 100,
            lastPageWasFull: true
        )

        app.cacheLibraryPage(firstPage, for: firstLibrary.id)
        app.cacheLibraryPage(secondPage, for: secondLibrary.id)

        let firstKey = AppModel.LibraryPageKey(libraryID: firstLibrary.id)
        let secondKey = AppModel.LibraryPageKey(libraryID: secondLibrary.id)
        XCTAssertEqual(app.libraryPages[firstKey]?.nextStartIndex, 200)
        XCTAssertEqual(app.libraryPages[secondKey]?.nextStartIndex, 100)

        app.clearLibraryPage(for: firstLibrary.id)

        XCTAssertNil(app.libraryPages[firstKey])
        XCTAssertEqual(app.libraryPages[secondKey]?.nextStartIndex, 100)
    }

    /// 库内搜索曾与浏览页**共用**同一格分页缓存：搜「败犬女主」→ 点进详情 → 回首页
    /// → 再点该库，`LibraryView.searchText`（`@State`）随视图重建已空，缓存里却还是
    /// 那几条搜索结果 → 搜索框空着、网格只剩当初搜出来的几个，且没有任何入口能切回
    /// 浏览页（只能重新搜一次再清空）。键带上搜索词后两者各占一格。
    func testBrowsingPageSurvivesAnInLibrarySearch() {
        let app = AppModel()
        let library = MediaLibrary(id: "shows", name: "剧集", collectionType: .tvshows)
        let browsing = AppModel.LibraryPage(
            items: (1...3).map { MediaItem(id: "show-\($0)", name: "剧集\($0)", kind: .series) },
            totalCount: 300,
            nextStartIndex: 100,
            lastPageWasFull: true
        )
        let searched = AppModel.LibraryPage(
            items: [MediaItem(id: "show-42", name: "败犬女主太多了", kind: .series)],
            totalCount: 1,
            nextStartIndex: 1,
            lastPageWasFull: false
        )

        app.cacheLibraryPage(browsing, for: library.id)
        app.cacheLibraryPage(searched, for: library.id, searchTerm: "败犬女主")

        // 回到该库时取页键是浏览页（空词），网格必须是原来那 3 条、而不是搜索结果。
        let browsingKey = AppModel.LibraryPageKey(libraryID: library.id)
        XCTAssertEqual(app.libraryPages[browsingKey]?.items.count, 3)
        XCTAssertEqual(app.libraryPages[browsingKey]?.nextStartIndex, 100)
        XCTAssertEqual(app.libraryPages[browsingKey]?.totalCount, 300)
        // 同一个库、不同词的格子互不影响。
        XCTAssertEqual(
            app.libraryPages[AppModel.LibraryPageKey(libraryID: library.id, searchTerm: "败犬女主")]?.items.count,
            1
        )
    }

    /// 搜索页之间的连带作废：搜索框一次只装一个词、切库还会清空，旧词的格子再也读不到，
    /// 不能留在字典里无界累积；浏览页是「切走再回来」的落脚点，必须保住。
    func testNewSearchTermDropsStaleSearchPagesButKeepsBrowsing() {
        let app = AppModel()
        let library = MediaLibrary(id: "shows", name: "剧集", collectionType: .tvshows)
        let browsing = AppModel.LibraryPage(items: [], totalCount: 300, nextStartIndex: 100)
        let firstSearch = AppModel.LibraryPage(items: [], totalCount: 1, nextStartIndex: 1)
        let secondSearch = AppModel.LibraryPage(items: [], totalCount: 2, nextStartIndex: 2)

        app.cacheLibraryPage(browsing, for: library.id)
        app.cacheLibraryPage(firstSearch, for: library.id, searchTerm: "败犬")
        app.cacheLibraryPage(secondSearch, for: library.id, searchTerm: "女主")

        XCTAssertNil(app.libraryPages[AppModel.LibraryPageKey(libraryID: library.id, searchTerm: "败犬")])
        XCTAssertEqual(
            app.libraryPages[AppModel.LibraryPageKey(libraryID: library.id, searchTerm: "女主")]?.totalCount,
            2
        )
        XCTAssertEqual(app.libraryPages[AppModel.LibraryPageKey(libraryID: library.id)]?.totalCount, 300)
    }
}
