import CoreModel
@testable import OcPlayer
import XCTest

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    func testSignOutClearsNavPathsAndPlayerSession() {
        let app = AppModel()
        app.phase = .ready
        app.navPaths.home = [.detail(MediaItem(id: "series-1", name: "测试剧", kind: .series))]
        app.presentedPlayer = PlaybackRequest(title: "ep", uri: "/tmp/a.mkv")
        app.playbackPreparation = .loading(title: "ep")
        app.path = [.detail(MediaItem(id: "m1", name: "电影", kind: .movie))]

        app.signOut()

        XCTAssertTrue(app.navPaths.home.isEmpty)
        XCTAssertNil(app.presentedPlayer)
        XCTAssertNil(app.playbackPreparation)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.phase, .onboarding)
        XCTAssertEqual(app.selectedSection, .home)
    }

    func testReconnectFlowClearsNavPaths() {
        let app = AppModel()
        app.phase = .ready
        app.navPaths.libraries = [.detail(MediaItem(id: "series-2", name: "另一部", kind: .series))]
        app.path = [.detail(MediaItem(id: "m2", name: "电影2", kind: .movie))]

        app.reconnectFlow()

        XCTAssertTrue(app.navPaths.libraries.isEmpty)
        XCTAssertTrue(app.path.isEmpty)
        XCTAssertEqual(app.phase, .onboarding)
        XCTAssertEqual(app.selectedSection, .home)
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
