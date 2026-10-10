import CoreModel
import DiagnosticsKit
import Get
import JellyfinAPI
import XCTest
@testable import JellyfinKit

/// 登录 / 浏览 / URL 拼装的离线测试：网络全走 `MockURLProtocol`。
final class JellyfinServerTests: XCTestCase {

    private var store: ServerStore!

    override func setUp() {
        super.setUp()
        let suiteName = "JellyfinServerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
    }

    // MARK: - 浏览（mock 数据 → 域模型）

    private func makeServer() -> JellyfinServer {
        let profile = ServerProfile(id: "srv:user", serverName: "home-nas",
                                    baseURL: URL(string: "http://nas.local:8096")!,
                                    userID: "user-9", userName: "jumusu", serverVersion: "10.9.11")
        let client = JellyfinServer.makeClient(baseURL: profile.baseURL, token: "tok-123",
                                               sessionConfiguration: TestSupport.mockedSessionConfiguration())
        return JellyfinServer(profile: profile, client: client)
    }

    func testUserViewsMapsKnownCollectionsAndFiltersFolders() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/UserViews")
            return MockURLProtocol.ok(
                """
                {"Items":[
                  {"Id":"lib-1","Name":"电影","CollectionType":"movies"},
                  {"Id":"lib-2","Name":"剧集","CollectionType":"tvshows"},
                  {"Id":"lib-3","Name":"其它文件夹","CollectionType":"folders"},
                  {"Id":"lib-4","Name":"未知"}
                ],"TotalRecordCount":4}
                """,
                for: request.url!
            )
        } with: {
            let libraries = try await makeServer().userViews()
            XCTAssertEqual(libraries.map(\.id), ["lib-1", "lib-2"])
            XCTAssertEqual(libraries[0].name, "电影")
            XCTAssertEqual(libraries[0].collectionType, .movies)
        }
    }

    func testResumeItemsMapsEpisodeWithPlayState() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/UserItems/Resume")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["mediaTypes"], "Video")
            return MockURLProtocol.ok(
                """
                {"Items":[{
                  "Id":"ep-1","Name":"第 4 集","Type":"Episode",
                  "SeriesId":"s-1","SeriesName":"3 体",
                  "ParentIndexNumber":1,"IndexNumber":4,
                  "ProductionYear":2024,"RunTimeTicks":1600000000,
                  "Genres":["科幻","悬疑"],
                  "UserData":{"Key":"ep-1","PlaybackPositionTicks":600000000,"PlayedPercentage":37.5,"IsPlayed":false},
                  "ImageTags":{"Primary":"pri-tag"},"BackdropImageTags":["bd-tag"],
                  "People":[{"Id":"p-1","Name":"曾靖","Role":"Ye Wenjie","Type":"Actor"}]
                }],"TotalRecordCount":1}
                """,
                for: request.url!
            )
        } with: {
            let items = try await makeServer().resumeItems()
            XCTAssertEqual(items.count, 1)
            let item = items[0]
            XCTAssertEqual(item.kind, .episode)
            XCTAssertEqual(item.seriesID, "s-1")
            XCTAssertEqual(item.episodeLabel, "S1E4")
            XCTAssertEqual(item.seriesName, "3 体")
            XCTAssertEqual(try XCTUnwrap(item.runtimeSeconds), 160, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(item.playState).positionSeconds, 60, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(item.playState).percentage, 0.375, accuracy: 0.001)
            XCTAssertEqual(item.genres, ["科幻", "悬疑"])
            XCTAssertEqual(item.cast.first?.name, "曾靖")
            XCTAssertEqual(item.primaryImageTag, "pri-tag")
            XCTAssertEqual(item.backdropImageTag, "bd-tag")
        }
    }

    func testEpisodesRequestsOwnImagesAndIndexOrder() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Shows/series-1/Episodes")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["seasonId"], "season-2")
            XCTAssertEqual(query["enableImages"], "true")
            XCTAssertEqual(query["enableImageTypes"], "Primary")
            XCTAssertTrue(request.url?.query?.contains("enableImageTypes=Thumb") == true)
            XCTAssertEqual(query["enableUserData"], "true")
            XCTAssertEqual(query["sortBy"], "IndexNumber")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"ep-2","Name":"第二集","Type":"Episode","IndexNumber":2,"ImageTags":{"Thumb":"thumb-2"}}]}"#,
                for: request.url!
            )
        } with: {
            let episodes = try await makeServer().episodes(seriesID: "series-1", seasonID: "season-2")
            XCTAssertEqual(episodes.map(\.id), ["ep-2"])
            XCTAssertEqual(episodes[0].thumbImageTag, "thumb-2")
        }
    }

    func testAllSeriesEpisodesAreSortedBySeasonThenEpisode() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Shows/series-1/Episodes")
            XCTAssertNil(TestSupport.queryItems(of: request)["seasonId"])
            return MockURLProtocol.ok(
                """
                {"Items":[
                  {"Id":"s2e1","Name":"第二季第一集","Type":"Episode","ParentIndexNumber":2,"IndexNumber":1},
                  {"Id":"s1e2","Name":"第一季第二集","Type":"Episode","ParentIndexNumber":1,"IndexNumber":2},
                  {"Id":"s1e1","Name":"第一季第一集","Type":"Episode","ParentIndexNumber":1,"IndexNumber":1}
                ]}
                """,
                for: request.url!
            )
        } with: {
            let episodes = try await makeServer().episodes(seriesID: "series-1")
            XCTAssertEqual(episodes.map(\.id), ["s1e1", "s1e2", "s2e1"])
        }
    }

    func testLibraryBrowseSendsRecursiveSortAndTypes() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["parentId"], "lib-1")
            XCTAssertEqual(query["recursive"], "true")
            XCTAssertEqual(query["includeItemTypes"], "Movie")
            return MockURLProtocol.ok(#"{"Items":[{"Id":"m-1","Name":"沙丘 2","Type":"Movie","ProductionYear":2024}],"TotalRecordCount":1}"#, for: request.url!)
        } with: {
            let items = try await makeServer().items(parentID: "lib-1", kinds: [.movie])
            XCTAssertEqual(items.map(\.name), ["沙丘 2"])
            XCTAssertEqual(items[0].year, 2024)
        }
    }

    func testMarkPlayedPostsUserPlayedItemsAndMapsState() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/UserPlayedItems/ep-9")
            XCTAssertEqual(request.httpMethod, "POST")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["userId"], "user-9")
            return MockURLProtocol.ok(
                #"{"Key":"ep-9","Played":true,"PlaybackPositionTicks":0,"PlayedPercentage":100}"#,
                for: request.url!
            )
        } with: {
            let state = try await makeServer().markPlayed(itemID: "ep-9")
            XCTAssertTrue(state.played)
            XCTAssertEqual(state.positionSeconds, 0, accuracy: 0.001)
            XCTAssertEqual(state.percentage, 1, accuracy: 0.001)
        }
    }

    func testMarkUnplayedDeletesUserPlayedItemsAndMapsState() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/UserPlayedItems/ep-9")
            XCTAssertEqual(request.httpMethod, "DELETE")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["userId"], "user-9")
            return MockURLProtocol.ok(
                #"{"Key":"ep-9","Played":false,"PlaybackPositionTicks":0,"PlayedPercentage":0}"#,
                for: request.url!
            )
        } with: {
            let state = try await makeServer().markUnplayed(itemID: "ep-9")
            XCTAssertFalse(state.played)
            XCTAssertEqual(state.percentage, 0, accuracy: 0.001)
        }
    }

    func testFavoriteItemsFiltersFavoritesAndSortsByMediaCreationDate() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["filters"], "IsFavorite")
            XCTAssertTrue(request.url?.query?.contains("includeItemTypes=Movie") == true)
            XCTAssertTrue(request.url?.query?.contains("includeItemTypes=Series") == true)
            XCTAssertEqual(query["sortBy"], "DateCreated")
            XCTAssertEqual(query["sortOrder"], "Descending")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"fav-1","Name":"沙丘 2","Type":"Movie","BackdropImageTags":["bd"]}],"TotalRecordCount":1}"#,
                for: request.url!
            )
        } with: {
            let items = try await makeServer().favoriteItems()
            XCTAssertEqual(items.map(\.id), ["fav-1"])
            XCTAssertEqual(items[0].kind, .movie)
            XCTAssertEqual(items[0].backdropImageTag, "bd")
        }
    }

    /// 回归（用户实测：首页「最近添加」整条消失）：**绝不能再打 `/Items/Latest`**。
    ///
    /// Jellyfin 12.1.0 上 `/Items/Latest` 一旦带 `includeItemTypes` 就恒返回 `[]`（HTTP 200），
    /// 空数组是成功值 → rail 静默为空、连失败日志都不打。改用 `/Items` + `sortBy=DateCreated`
    /// 倒序后本机实测 43 条电影/剧集（旧端点 0 条）。
    ///
    /// 这条用例同时钉三件互相关联的事：**端点**（`/Items` 而不是 `/Items/Latest`）、
    /// **排序口径**（入库时间倒序，与库页「最近添加」同源）、**信封格式**
    /// （`BaseItemDtoQueryResult`，不是 Latest 的裸数组——裸数组会直接解码失败）。
    func testLatestMediaUsesItemsSortedByDateCreatedInsteadOfLatestEndpoint() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items", "不能再用 /Items/Latest：12.1.0 上带 includeItemTypes 恒返回空")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["recursive"], "true", "不递归只会拿到顶层项")
            XCTAssertEqual(query["sortBy"], "DateCreated")
            XCTAssertEqual(query["sortOrder"], "Descending", "最近添加 = 新在前")
            XCTAssertEqual(query["limit"], "24")
            XCTAssertEqual(query["userId"], "user-9")
            XCTAssertTrue(request.url?.query?.contains("includeItemTypes=Movie") == true)
            XCTAssertTrue(request.url?.query?.contains("includeItemTypes=Series") == true)
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"new-1","Name":"刚入库的剧","Type":"Series","ProductionYear":2026}],"TotalRecordCount":1}"#,
                for: request.url!
            )
        } with: {
            let items = try await makeServer().latestItems()
            XCTAssertEqual(items.map(\.id), ["new-1"])
            XCTAssertEqual(items[0].kind, .series)
            XCTAssertEqual(items[0].year, 2026)
        }
    }

    /// 合集成员查询的**形态**必须钉住：这三条约束错了，服务端返回的就不是成员。
    ///
    /// - `recursive=false`：递归会走 `DescendantOfId` 把成员的下一层（剧集的季与集）
    ///   一起带出来；
    /// - **不带 `includeItemTypes`**：给合集 parentId 配上它，服务端会把 parentId 置空、
    ///   改成从用户根重查（返回「所有合集」而不是成员，jellyfin#16454）；
    /// - 排序显式给年份升序（不传 sortBy 时按合集自己的 DisplayOrder 排，不可复现）。
    func testCollectionMembersQueryShape() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["parentId"], "box-1")
            XCTAssertEqual(query["recursive"], "false", "合集成员不能递归取")
            XCTAssertNil(query["includeItemTypes"], "带上它会被服务端把 parentId 置空")
            XCTAssertEqual(query["sortBy"], "ProductionYear")
            XCTAssertEqual(query["sortOrder"], "Ascending")
            XCTAssertEqual(query["userId"], "user-9")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"m-1","Name":"福音战士新剧场版：Q","Type":"Movie","ProductionYear":2012}],"TotalRecordCount":2}"#,
                for: request.url!)
        } with: {
            let page = try await makeServer().collectionMembers(of: "box-1")
            XCTAssertEqual(page.items.map(\.id), ["m-1"])
            XCTAssertEqual(page.totalRecordCount, 2)
        }
    }

    func testItemRequestsPeopleGenresOverviewAndMapsCast() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items/abc")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["userId"], "user-9")
            XCTAssertEqual(query["fields"], "People,Genres,Overview,Chapters")
            return MockURLProtocol.ok(
                """
                {"Id":"abc","Name":"沙丘 2","Type":"Movie",
                 "People":[
                   {"Id":"p-1","Name":"提莫西·查拉梅","Role":"Paul Atreides","Type":"Actor"},
                   {"Id":"p-2","Name":"丹尼斯·维伦纽瓦","Role":"导演","Type":"Director"}
                 ]}
                """,
                for: request.url!
            )
        } with: {
            let item = try await makeServer().item("abc")
            XCTAssertEqual(item.name, "沙丘 2")
            XCTAssertEqual(item.cast.count, 2)
            XCTAssertEqual(item.cast[0].name, "提莫西·查拉梅")
            XCTAssertEqual(item.cast[0].role, "Paul Atreides")
            XCTAssertEqual(item.cast[0].kind, "Actor")
            XCTAssertEqual(item.cast[1].kind, "Director")
        }
    }

    func testLibraryBrowseLoadsEveryPage() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["limit"], "2")
            XCTAssertEqual(query["enableTotalRecordCount"], "true")
            switch query["startIndex"] {
            case "0":
                return MockURLProtocol.ok(
                    #"{"Items":[{"Id":"m-1","Name":"1","Type":"Movie"},{"Id":"m-2","Name":"2","Type":"Movie"}],"TotalRecordCount":5}"#,
                    for: request.url!
                )
            case "2":
                return MockURLProtocol.ok(
                    #"{"Items":[{"Id":"m-3","Name":"3","Type":"Movie"},{"Id":"m-4","Name":"4","Type":"Movie"}],"TotalRecordCount":5}"#,
                    for: request.url!
                )
            case "4":
                return MockURLProtocol.ok(
                    #"{"Items":[{"Id":"m-5","Name":"5","Type":"Movie"}],"TotalRecordCount":5}"#,
                    for: request.url!
                )
            default:
                return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":5}"#, for: request.url!)
            }
        } with: {
            let items = try await makeServer().items(parentID: "lib-1", kinds: [.movie], limit: 2)
            XCTAssertEqual(items.map(\.id), ["m-1", "m-2", "m-3", "m-4", "m-5"])
        }
    }

    func testItemsPageReturnsSinglePageWithoutAutoFetch() async throws {
        var requestCount = 0
        try await TestSupport.withMock { request in
            requestCount += 1
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["limit"], "2")
            XCTAssertEqual(query["startIndex"], "2")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"m-3","Name":"3","Type":"Movie"},{"Id":"m-4","Name":"4","Type":"Movie"}],"TotalRecordCount":5}"#,
                for: request.url!
            )
        } with: {
            let page = try await makeServer().itemsPage(
                parentID: "lib-1",
                kinds: [.movie],
                startIndex: 2,
                limit: 2
            )
            XCTAssertEqual(page.items.map(\.id), ["m-3", "m-4"])
            XCTAssertEqual(page.startIndex, 2)
            XCTAssertEqual(page.totalRecordCount, 5)
            XCTAssertTrue(page.hasMore)
            XCTAssertEqual(requestCount, 1, "itemsPage must not auto-paginate")
        }
    }

    /// query 重复键取值数组（GetItems 的数组参数走 explode 编码：
    /// `sortBy=DateCreated&sortBy=SortName`，与 includeItemTypes 现网同款）。
    private func queryValues(of request: URLRequest, name: String) -> [String] {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [] }
        return items.filter { $0.name == name }.compactMap(\.value)
    }

    func testItemsPageSortDefaultsToNameAscending() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(self.queryValues(of: request, name: "sortBy"), ["SortName"])
            XCTAssertEqual(self.queryValues(of: request, name: "sortOrder"), ["Ascending"])
            return MockURLProtocol.ok(
                #"{"Items":[],"TotalRecordCount":0}"#,
                for: request.url!
            )
        } with: {
            _ = try await makeServer().itemsPage(parentID: "lib-1", limit: 2)
        }
    }

    func testItemsPageSortPassesKeysAndPairedOrders() async throws {
        // 主键带用户方向，副键固定名称升序——副键不受「降序」牵连。
        try await TestSupport.withMock { request in
            XCTAssertEqual(self.queryValues(of: request, name: "sortBy"), ["DateCreated", "SortName"])
            XCTAssertEqual(self.queryValues(of: request, name: "sortOrder"), ["Descending", "Ascending"])
            return MockURLProtocol.ok(
                #"{"Items":[],"TotalRecordCount":0}"#,
                for: request.url!
            )
        } with: {
            _ = try await makeServer().itemsPage(
                parentID: "lib-1",
                sort: MediaItemsSort(field: .dateAdded, ascending: false)
            )
        }
    }

    func testItemsPageSortRandomSendsRandomKey() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(self.queryValues(of: request, name: "sortBy"), ["Random"])
            return MockURLProtocol.ok(
                #"{"Items":[],"TotalRecordCount":0}"#,
                for: request.url!
            )
        } with: {
            _ = try await makeServer().itemsPage(
                parentID: "lib-1",
                sort: MediaItemsSort(field: .random, ascending: false)
            )
        }
    }

    func testItemsPageWatchStatePassesServerFilters() async throws {
        // 看过 → IsPlayed；没看过 → IsUnplayed；默认（all / nil）不带 filters。
        try await TestSupport.withMock { request in
            XCTAssertEqual(self.queryValues(of: request, name: "filters"), ["IsPlayed"])
            return MockURLProtocol.ok(
                #"{"Items":[],"TotalRecordCount":0}"#,
                for: request.url!
            )
        } with: {
            _ = try await makeServer().itemsPage(parentID: "lib-1", watchState: .watched)
        }

        try await TestSupport.withMock { request in
            XCTAssertEqual(self.queryValues(of: request, name: "filters"), ["IsUnplayed"])
            return MockURLProtocol.ok(
                #"{"Items":[],"TotalRecordCount":0}"#,
                for: request.url!
            )
        } with: {
            _ = try await makeServer().itemsPage(parentID: "lib-1", watchState: .unwatched)
        }

        try await TestSupport.withMock { request in
            XCTAssertTrue(self.queryValues(of: request, name: "filters").isEmpty)
            return MockURLProtocol.ok(
                #"{"Items":[],"TotalRecordCount":0}"#,
                for: request.url!
            )
        } with: {
            _ = try await makeServer().itemsPage(parentID: "lib-1")
        }
    }

    func testItemsPagePassesSearchTerm() async throws {
        try await TestSupport.withMock { request in
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["searchTerm"], "沙丘")
            return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
        } with: {
            _ = try await makeServer().itemsPage(parentID: "lib-1", limit: 100, searchTerm: " 沙丘 ")
        }
    }

    func testRequestsCarryCustomUserAgent() async throws {
        try await TestSupport.withCustomUserAgent("SenPlayer/2.1") {
            try await TestSupport.withMock { request in
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "User-Agent"),
                    "SenPlayer/2.1",
                    "设置的自定义 UA 必须逐请求携带（白名单服务器按它放行拉流）"
                )
                return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
            } with: {
                _ = try await makeServer().itemsPage(parentID: "lib-1", limit: 10)
            }
        }
    }

    // MARK: - URL 与认证头

    func testStreamURLHasNoToken() throws {
        let url = try makeServer().streamURL(itemID: "abc")
        XCTAssertTrue(url.hasSuffix("/Videos/abc/stream?Static=true"))
        XCTAssertFalse(url.contains("tok-123"), "token 绝不能进 URL")
        XCTAssertFalse(url.contains("api_key"))
    }

    func testImageURLCarriesMaxWidthAndTagButNoToken() throws {
        let url = try makeServer().imageURL(itemID: "abc", maxWidth: 400, tag: "img-7")
        XCTAssertEqual(url.path, "/Items/abc/Images/Primary")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["maxWidth"], "400")
        XCTAssertEqual(dict["tag"], "img-7")
        XCTAssertNil(dict["api_key"])
    }

    func testImageURLWithLogoType() throws {
        let url = try makeServer().imageURL(itemID: "series-1", type: .logo, maxWidth: 600, tag: "logo-tag")
        XCTAssertEqual(url.path, "/Items/series-1/Images/Logo")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["maxWidth"], "600")
        XCTAssertEqual(dict["tag"], "logo-tag")
    }

    func testItemMappingExtractsLogoAndParentLogo() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items/ep-1")
            return MockURLProtocol.ok(
                """
                {
                  "Id":"ep-1",
                  "Name":"第 1 集",
                  "Type":"Episode",
                  "SeriesId":"s-100",
                  "SeriesName":"进击的巨人",
                  "ParentLogoItemId":"s-100",
                  "ParentLogoImageTag":"parent-logo-tag-123",
                  "ImageTags":{"Primary":"ep-pri"}
                }
                """,
                for: request.url!
            )
        } with: {
            let item = try await makeServer().item("ep-1")
            XCTAssertEqual(item.id, "ep-1")
            XCTAssertEqual(item.logoImageTag, "parent-logo-tag-123")
            XCTAssertEqual(item.parentLogoItemID, "s-100")
            XCTAssertEqual(item.logoItemID, "s-100")
        }
    }

    func testItemMappingCarriesParentImagesForHomeStillChain() async throws {
        // 首页「继续播放 / 接下来看」Jellyfin Web 同款取图链依赖这组父级图
        // 字段（实测 NextUp/Resume 响应恒带 ParentThumb*）。
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items/ep-1")
            return MockURLProtocol.ok(
                """
                {
                  "Id":"ep-1",
                  "Name":"第 1 集",
                  "Type":"Episode",
                  "SeriesId":"s-100",
                  "SeriesName":"进击的巨人",
                  "ImageTags":{"Primary":"ep-pri"},
                  "BackdropImageTags":[],
                  "SeriesThumbImageTag":null,
                  "ParentThumbItemId":"s-100",
                  "ParentThumbImageTag":"series-thumb",
                  "ParentBackdropItemId":"s-100",
                  "ParentBackdropImageTags":["fanart-1","fanart-2"],
                  "ParentPrimaryImageItemId":"season-1",
                  "ParentPrimaryImageTag":"season-poster",
                  "SeriesPrimaryImageTag":"series-poster"
                }
                """,
                for: request.url!
            )
        } with: {
            let item = try await makeServer().item("ep-1")
            XCTAssertEqual(item.parentThumbItemID, "s-100")
            XCTAssertEqual(item.parentThumbImageTag, "series-thumb")
            XCTAssertEqual(item.parentBackdropItemID, "s-100")
            XCTAssertEqual(item.parentBackdropImageTag, "fanart-1", "只取第一张 Backdrop")
            XCTAssertEqual(item.parentPrimaryImageItemID, "season-1")
            XCTAssertEqual(item.parentPrimaryImageTag, "season-poster")
            XCTAssertEqual(item.seriesPrimaryImageTag, "series-poster")
            // 官方默认口径：有父级 Thumb 时分集卡片用剧集横版剧照。
            XCTAssertEqual(
                item.homeStillImageChoice,
                StillImageChoice(itemID: "s-100", kind: .thumb, tag: "series-thumb")
            )
        }
    }

    func testAuthorizationHeaderFormat() {
        let header = makeServer().authorizationHeader
        let expected = ClientIdentity.mediaBrowserAuthorizationHeader(token: "tok-123")
        XCTAssertEqual(header, expected)
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains(#"Token="tok-123""#))
        XCTAssertTrue(header.contains("Client=\"OcPlayer\""))
        XCTAssertTrue(header.contains("DeviceId=\"\(ClientIdentity.deviceID)\""))
    }

    // MARK: - 章节

    func testChaptersMapsTicksToSecondsAndSequentialNames() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items/mv-1")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["fields"], "Chapters")
            return MockURLProtocol.ok(
                """
                {"Id":"mv-1","Chapters":[
                  {"Name":"开场","StartPositionTicks":0},
                  {"Name":"正片","StartPositionTicks":9000000000},
                  {"Name":"片尾","StartPositionTicks":108000000000}
                ]}
                """,
                for: request.url!
            )
        } with: {
            let chapters = try await makeServer().chapters(itemID: "mv-1")
            XCTAssertEqual(chapters.count, 3)
            XCTAssertEqual(chapters[0].name, "开场")
            XCTAssertEqual(chapters[0].startSeconds, 0)
            XCTAssertEqual(chapters[1].startSeconds, 900)
            XCTAssertEqual(chapters[2].startSeconds, 10800)
        }
    }

    func testChaptersEmptyWhenNone() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"Id":"mv-1"}"#, for: request.url!)
        } with: {
            let chapters = try await makeServer().chapters(itemID: "mv-1")
            XCTAssertTrue(chapters.isEmpty)
        }
    }

    func testMediaSegmentsFiltersIntroAndOutro() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/MediaSegments/mv-1")
            return MockURLProtocol.ok(
                """
                {"Items":[
                  {"Id":"s-1","ItemId":"mv-1","StartTicks":0,"EndTicks":9000000000,"Type":"Intro"},
                  {"Id":"s-2","ItemId":"mv-1","StartTicks":108000000000,"EndTicks":112500000000,"Type":"Outro"},
                  {"Id":"s-3","ItemId":"mv-1","StartTicks":1000000000,"EndTicks":2000000000,"Type":"Commercial"}
                ]}
                """,
                for: request.url!
            )
        } with: {
            let segments = try await makeServer().mediaSegments(itemID: "mv-1")
            XCTAssertEqual(segments.count, 2, "Commercial 应被过滤掉")
            XCTAssertEqual(segments[0].kind, .intro)
            XCTAssertEqual(segments[0].startSeconds, 0)
            XCTAssertEqual(segments[0].endSeconds, 900)
            XCTAssertEqual(segments[1].kind, .outro)
            XCTAssertEqual(segments[1].endSeconds, 11250)
        }
    }


    /// 按档案恢复：token 在 → 建出会话；token 不在 → nil（调用方回落登录流程）。
    func testResumeProfileUsesStoredToken() {
        let jellyfin = profile(id: "srv:jf", baseURL: "http://nas.local:8096")
        let emby = profile(id: "srv:em", baseURL: "http://nas.local:8097/emby", kind: .emby)
        store.save(jellyfin, makeCurrent: true)
        store.save(emby, makeCurrent: false)
        store.activate(jellyfin, token: "tok-jf")

        let resumed = JellyfinServer.resume(profile: jellyfin, from: store)
        XCTAssertEqual(resumed?.profile.id, "srv:jf")
        XCTAssertEqual(resumed?.accessToken, "tok-jf")

        XCTAssertNil(JellyfinServer.resume(profile: emby, from: store), "无 token 的档案 resume 必须返回 nil")
    }

    /// currentProfile 没 token 时，启动恢复回退到列表里第一个有 token 的档案，
    /// 而不是直接弹登录页无视另一台的有效会话。
    func testRestoreFallsBackToProfileWithTokenWhenCurrentHasNone() {
        let currentNoToken = profile(id: "srv:a")
        let otherWithToken = profile(id: "srv:b", baseURL: "http://nas.local:8098")
        store.save(currentNoToken, makeCurrent: true)
        store.save(otherWithToken, makeCurrent: false)
        store.activate(otherWithToken, token: "tok-b")
        // currentKey 仍指向 srv:a（activate(b) 会改指针，手动存回去）
        store.save(currentNoToken, makeCurrent: true)

        let restored = MediaServerFactory.restore(from: store)
        XCTAssertEqual(restored?.profile.id, "srv:b")
        XCTAssertEqual((restored as? JellyfinServer)?.accessToken, "tok-b")
    }

    func testRestorePrefersCurrentProfileWhenItHasToken() {
        let first = profile(id: "srv:first")
        let second = profile(id: "srv:second")
        store.activate(first, token: "tok-first")
        store.activate(second, token: "tok-second")
        // activate 已把 current 切到 second；再 save 回 first 且设为当前
        store.save(first, makeCurrent: true)

        XCTAssertEqual(MediaServerFactory.restore(from: store)?.profile.id, "srv:first")
    }

    private func profile(id: String, baseURL: String = "http://nas.local:8096",
                         kind: ServerKind = .jellyfin) -> ServerProfile {
        ServerProfile(id: id, serverName: "home-nas", baseURL: URL(string: baseURL)!,
                      userID: id.split(separator: ":").last.map(String.init) ?? id,
                      kind: kind)
    }

}


/// 浏览类请求的重试策略：此前 JellyfinKit **完全没有重试**，服务器半死（502/503）
/// 时用户只能看着首页转圈到超时。共享的 `RetryPolicy` 早就在 DiagnosticsKit 里。
final class JellyfinRetryPolicyTests: XCTestCase {

    // MARK: - 幂等判定

    /// 写操作**不得**重试：`markPlayed` / `markUnplayed` 重放会把一次用户操作变成两次。
    func testOnlyIdempotentMethodsAreRetried() {
        XCTAssertTrue(JellyfinServer.isIdempotent(.get))
        XCTAssertTrue(JellyfinServer.isIdempotent(.head))
        XCTAssertTrue(JellyfinServer.isIdempotent(.put))
        XCTAssertTrue(JellyfinServer.isIdempotent(.delete))
        XCTAssertFalse(JellyfinServer.isIdempotent(.post), "POST 通常是创建语义")
        XCTAssertFalse(JellyfinServer.isIdempotent(.patch))
        // 大小写不该影响判定（HTTPMethod 是字符串包装）。
        XCTAssertTrue(JellyfinServer.isIdempotent(HTTPMethod(rawValue: "get")))
    }

    // MARK: - 可重试判定

    func testTransportFailuresAreRetryable() {
        XCTAssertTrue(JellyfinServer.isRetryable(JellyfinError(.transport("连接中断"))))
        XCTAssertTrue(JellyfinServer.isRetryable(JellyfinError(.transport("超时"))))
    }

    func testServerErrorsAndRateLimitAreRetryable() {
        for status in [500, 502, 503, 504] {
            XCTAssertTrue(
                JellyfinServer.isRetryable(JellyfinError(.http(status: status))),
                "\(status) 应可重试")
        }
        XCTAssertTrue(JellyfinServer.isRetryable(JellyfinError(.http(status: 429))), "限流可重试")
    }

    /// 4xx（429 除外）是请求本身的问题，重试只会白撞三次。
    func testClientErrorsAreNotRetryable() {
        for status in [400, 401, 403, 404, 422] {
            XCTAssertFalse(
                JellyfinServer.isRetryable(JellyfinError(.http(status: status))),
                "\(status) 不该重试")
        }
    }

    /// 边界：499 不重试、500 重试。
    func testBoundaryBetweenClientAndServerErrors() {
        XCTAssertFalse(JellyfinServer.isRetryable(JellyfinError(.http(status: 499))))
        XCTAssertTrue(JellyfinServer.isRetryable(JellyfinError(.http(status: 500))))
    }

    /// 判据是「**名字解析不了 = 永久，解析得到但连不上 = 瞬态**」。
    ///
    /// 这条最初被我写反过：把 `.serverUnreachable` 一律当成"地址写错、不重试"。
    /// 实机日志证明那是错的——冷启动时网络未就绪，Jellyfin 五个请求（-1009）
    /// 全部不重试直接失败，而网络就绪后同样的请求 85–583 ms 全部成功。
    func testNameResolutionFailuresAreNotRetryable() {
        // -1003 / -1006：名字就是错的，重试无意义。
        XCTAssertFalse(JellyfinServer.isRetryable(
            JellyfinError(.serverUnreachable, underlying: URLError(.cannotFindHost))))
        XCTAssertFalse(JellyfinServer.isRetryable(
            JellyfinError(.serverUnreachable, underlying: URLError(.dnsLookupFailed))))
    }

    func testConnectLevelFailuresAreRetryable() {
        // -1004 / -1005：解析得到但连不上 → 服务在重启 / 中途断连，值得重试。
        XCTAssertTrue(JellyfinServer.isRetryable(
            JellyfinError(.serverUnreachable, underlying: URLError(.cannotConnectToHost))))
        XCTAssertTrue(JellyfinServer.isRetryable(
            JellyfinError(.serverUnreachable, underlying: URLError(.networkConnectionLost))))
    }

    /// 本机没网是最该重试的一类（等网络就绪就可能成功）。
    func testNoNetworkIsRetryable() {
        XCTAssertTrue(JellyfinServer.isRetryable(
            JellyfinError(.noNetwork, underlying: URLError(.notConnectedToInternet))))
    }

    /// 地址写错 / 未鉴权不重试。
    func testPermanentErrorsAreNotRetryable() {
        XCTAssertFalse(JellyfinServer.isRetryable(JellyfinError(.badServerURL)))
        XCTAssertFalse(JellyfinServer.isRetryable(JellyfinError(.unauthorized)))
    }

    /// 非 JellyfinError（例如裸 CancellationError）一律不重试。
    func testNonJellyfinErrorsAreNotRetryable() {
        XCTAssertFalse(JellyfinServer.isRetryable(CancellationError()))
        XCTAssertFalse(JellyfinServer.isRetryable(URLError(.timedOut)))
    }

    // MARK: - 预算

    func testRetryBudgets() {
        XCTAssertEqual(JellyfinServer.browseRetryPolicy.attempts, 3)
        XCTAssertEqual(JellyfinServer.noRetryPolicy.attempts, 1, "写操作 = 不重试")
    }
}

/// `send()` 的**端到端**重试行为（不只是 `isRetryable` 的判定）。
///
/// 关注点：`-1009 本机没网` 曾因归错类别而不重试，导致冷启动抢跑时首页与氛围背景
/// 的请求全部直接失败（实机日志 2026-09-30 五个请求同一毫秒全挂）。
/// 这里验证「失败一次后确实又发了一次，并且成功返回」。
final class JellyfinRetryBehaviourTests: XCTestCase {

    private var savedBrowse: RetryPolicy!
    private var savedNoRetry: RetryPolicy!

    override func setUp() {
        super.setUp()
        savedBrowse = JellyfinServer.browseRetryPolicy
        savedNoRetry = JellyfinServer.noRetryPolicy
        // 预算 2 + 退避近零：验证"重试发生了"而不必真等 0.5–1.5 秒。
        // ⚠️ `RetryPolicy` 第 1 次重试的等待是 `pow(base, 0) * jitter` = jitter，
        // **与 base 无关** —— 要缩的是 jitter，不是 base。
        JellyfinServer.browseRetryPolicy = RetryPolicy(attempts: 2, jitter: 0.001...0.002)
    }

    override func tearDown() {
        JellyfinServer.browseRetryPolicy = savedBrowse
        JellyfinServer.noRetryPolicy = savedNoRetry
        super.tearDown()
    }

    private func makeServer() -> JellyfinServer {
        let profile = ServerProfile(id: "srv:user", serverName: "home-nas",
                                    baseURL: URL(string: "http://nas.local:8096")!,
                                    userID: "user-9", userName: "jumusu", serverVersion: "10.9.11")
        let client = JellyfinServer.makeClient(
            baseURL: profile.baseURL, token: "tok-123",
            sessionConfiguration: TestSupport.mockedSessionConfiguration())
        return JellyfinServer(profile: profile, client: client)
    }

    /// 冷启动抢跑的真实形态：第一次 `-1009`，网络就绪后第二次成功。
    /// 修复前 `.serverUnreachable` 不可重试 → 第一次失败就直接抛给 UI。
    func testTransientNoNetworkIsRetriedAndThenSucceeds() async throws {
        let attempts = LockedCounter()
        try await TestSupport.withMock { request in
            if attempts.increment() == 1 {
                throw URLError(.notConnectedToInternet)
            }
            // `latestItems` 走 `/Items`，服务端返回的是信封（不是 Latest 的裸数组）。
            return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
        } with: {
            let items = try await makeServer().latestItems(limit: 5)
            XCTAssertTrue(items.isEmpty)
        }
        XCTAssertEqual(attempts.value, 2, "第一次失败后应再发一次")
    }

    /// 5xx 同样重试（服务器重启 / 网关抽风）。
    func testServerErrorIsRetriedAndThenSucceeds() async throws {
        let attempts = LockedCounter()
        try await TestSupport.withMock { request in
            if attempts.increment() == 1 {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 502, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                return (response, Data(#"{"detail":"Bad Gateway"}"#.utf8))
            }
            // 同上：`/Items` 的信封格式。
            return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
        } with: {
            _ = try await makeServer().latestItems(limit: 5)
        }
        XCTAssertEqual(attempts.value, 2)
    }

    /// 「名字解析不了」是永久错误：不该白撞第二次。
    func testNameResolutionFailureIsNotRetried() async throws {
        let attempts = LockedCounter()
        try await TestSupport.withMock { _ in
            _ = attempts.increment()
            throw URLError(.cannotFindHost)
        } with: {
            do {
                _ = try await makeServer().latestItems(limit: 5)
                XCTFail("应抛错")
            } catch let error as JellyfinError {
                guard case .serverUnreachable = error.kind else {
                    return XCTFail("应归 serverUnreachable，实际 \(error.kind)")
                }
            }
        }
        XCTAssertEqual(attempts.value, 1, "地址解析不了时重试只是让用户多等")
    }

    /// 预算是有限度的：一直失败不会无限重试。
    func testRetryStopsAtTheBudget() async throws {
        let attempts = LockedCounter()
        try await TestSupport.withMock { _ in
            _ = attempts.increment()
            throw URLError(.notConnectedToInternet)
        } with: {
            do {
                _ = try await makeServer().latestItems(limit: 5)
                XCTFail("应抛错")
            } catch let error as JellyfinError {
                guard case .noNetwork = error.kind else {
                    return XCTFail("应归 noNetwork，实际 \(error.kind)")
                }
            }
        }
        XCTAssertEqual(attempts.value, 2, "预算 2 = 首发 + 1 次重试")
    }
}

/// `@Sendable` mock 回调里记数用的锁盒子（Swift 6 不许捕获可变局部变量）。
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}
