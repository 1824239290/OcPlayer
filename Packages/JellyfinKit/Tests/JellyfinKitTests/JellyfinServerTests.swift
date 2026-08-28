import CoreModel
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

    // MARK: - 地址归一化

    func testNormalizeServerURL() throws {
        XCTAssertEqual(try JellyfinServer.normalizeServerURL("192.168.1.10:8096").absoluteString,
                       "http://192.168.1.10:8096")
        XCTAssertEqual(try JellyfinServer.normalizeServerURL(" https://nas.local/jellyfin/ ").absoluteString,
                       "https://nas.local/jellyfin")
        // 「localhost」这种不带端口的也行
        XCTAssertEqual(try JellyfinServer.normalizeServerURL("localhost").absoluteString,
                       "http://localhost")
    }

    func testNormalizeServerURLRespectsPreferredScheme() throws {
        // 没手写前缀:用 preferredScheme 补。
        XCTAssertEqual(
            try JellyfinServer.normalizeServerURL("nas.local:8096", preferredScheme: .https).absoluteString,
            "https://nas.local:8096")
        XCTAssertEqual(
            try JellyfinServer.normalizeServerURL("192.168.1.10:8096", preferredScheme: .http).absoluteString,
            "http://192.168.1.10:8096")
        // 手写前缀始终优先,preferredScheme 不能覆盖。
        XCTAssertEqual(
            try JellyfinServer.normalizeServerURL("http://nas.local", preferredScheme: .https).absoluteString,
            "http://nas.local")
        XCTAssertEqual(
            try JellyfinServer.normalizeServerURL("https://nas.local", preferredScheme: .http).absoluteString,
            "https://nas.local")
        // nil 回退原本的 http 默认,保证旧行为不变。
        XCTAssertEqual(
            try JellyfinServer.normalizeServerURL("192.168.1.10:8096", preferredScheme: nil).absoluteString,
            "http://192.168.1.10:8096")
    }

    func testNormalizeServerURLRejectsGarbage() {
        XCTAssertThrowsError(try JellyfinServer.normalizeServerURL("not a url"))
        XCTAssertThrowsError(try JellyfinServer.normalizeServerURL("ftp://x/"))
        XCTAssertThrowsError(try JellyfinServer.normalizeServerURL(""))
    }

    // MARK: - 登录全流程（mock 服务器）

    func testStartLoginProbesPublicSystemInfo() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/System/Info/Public")
            return MockURLProtocol.ok(
                """
                {"ServerName":"home-nas","Version":"10.9.11","Id":"srv-1","OperatingSystem":"Linux"}
                """,
                for: request.url!
            )
        } with: {
            let session = try await JellyfinServer.startLogin(urlString: "192.168.1.10:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(session.serverName, "home-nas")
            XCTAssertEqual(session.baseURL.absoluteString, "http://192.168.1.10:8096")
        }
    }

    func testStartLoginSurfacesUnreachableServer() async throws {
        try await TestSupport.withMock { _ in
            throw URLError(.cannotConnectToHost)
        } with: {
            do {
                _ = try await JellyfinServer.startLogin(urlString: "192.168.1.10:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
                XCTFail("应该抛错")
            } catch let error as JellyfinError {
                guard case .serverUnreachable = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
            }
        }
    }

    /// 连不上类错误（DNS / 拒绝连接 / 断网）给「检查地址」话术；超时等其它传输错误带细节。
    func testTransportErrorClassification() {
        let unreachable: [URLError.Code] = [
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
        ]
        for code in unreachable {
            guard case .serverUnreachable = JellyfinError.wrap(URLError(code)).kind else {
                return XCTFail("\(code) 应归为 serverUnreachable")
            }
        }
        guard case .transport = JellyfinError.wrap(URLError(.timedOut)).kind else {
            return XCTFail("timedOut 应归为 transport")
        }
        guard case .transport = JellyfinError.wrap(URLError(.networkConnectionLost)).kind else {
            return XCTFail("networkConnectionLost 应归为 transport")
        }
    }

    func testPasswordSignInFinishPersistsProfileAndToken() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(#"{"ServerName":"home-nas","Version":"10.9.11","Id":"srv-1"}"#, for: request.url!)
            case "/Users/AuthenticateByName":
                return MockURLProtocol.ok(
                    """
                    {"AccessToken":"tok-123","ServerId":"srv-1",
                     "User":{"Id":"user-9","Name":"jumusu","ServerId":"srv-1"}}
                    """,
                    for: request.url!
                )
            default:
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await JellyfinServer.startLogin(urlString: "http://nas.local:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            let result = try await session.signIn(username: "jumusu", password: "hunter2")
            XCTAssertEqual(result.token, "tok-123")

            let server = try session.finish(result, store: store)
            XCTAssertEqual(server.profile.id, "srv-1:user-9")
            XCTAssertEqual(server.profile.userID, "user-9")
            XCTAssertEqual(server.profile.userName, "jumusu")
            XCTAssertEqual(server.accessToken, "tok-123")

            // 落盘：档案和 token 通过各自的存储抽象保存
            XCTAssertEqual(store.currentProfile?.id, "srv-1:user-9")
            XCTAssertEqual(store.token(for: server.profile), "tok-123")
        }
    }

    func testSignInWithWrongPasswordMapsToUnauthorized() async throws {
        try await TestSupport.withMock { request in
            if request.url?.path == "/System/Info/Public" {
                return MockURLProtocol.ok(#"{"ServerName":"nas","Version":"10.9.11","Id":"srv-1"}"#, for: request.url!)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        } with: {
            do {
                let session = try await JellyfinServer.startLogin(urlString: "http://nas.local", sessionConfiguration: TestSupport.mockedSessionConfiguration())
                _ = try await session.signIn(username: "x", password: "bad")
                XCTFail("401 应该抛错")
            } catch let error as JellyfinError {
                guard case .unauthorized = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
                XCTAssertNotNil(error.errorDescription)
            }
        }
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

    // MARK: - 多服务器恢复

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

        let restored = JellyfinServer(restoringFrom: store)
        XCTAssertEqual(restored?.profile.id, "srv:b")
        XCTAssertEqual(restored?.accessToken, "tok-b")
    }

    func testRestorePrefersCurrentProfileWhenItHasToken() {
        let first = profile(id: "srv:first")
        let second = profile(id: "srv:second")
        store.activate(first, token: "tok-first")
        store.activate(second, token: "tok-second")
        // activate 已把 current 切到 second；再 save 回 first 且设为当前
        store.save(first, makeCurrent: true)

        XCTAssertEqual(JellyfinServer(restoringFrom: store)?.profile.id, "srv:first")
    }

    private func profile(id: String, baseURL: String = "http://nas.local:8096",
                         kind: ServerKind = .jellyfin) -> ServerProfile {
        ServerProfile(id: id, serverName: "home-nas", baseURL: URL(string: baseURL)!,
                      userID: id.split(separator: ":").last.map(String.init) ?? id,
                      kind: kind)
    }

    // MARK: - Emby 适配

    /// 探活返回 ProductName="Emby Server" → 识别为 Emby：QC 关闭、baseURL 带 /emby、落盘 kind。
    func testStartLoginDetectsEmbyAndAppendsAPIPrefix() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(
                    #"{"ServerName":"emby-nas","Version":"4.8.0.42","Id":"emby-1","ProductName":"Emby Server"}"#,
                    for: request.url!
                )
            // 登录请求应打到带 /emby 前缀的地址
            case "/emby/Users/AuthenticateByName":
                return MockURLProtocol.ok(
                    #"{"AccessToken":"tok-emby","ServerId":"emby-1","User":{"Id":"user-e","Name":"jumusu"}}"#,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await JellyfinServer.startLogin(urlString: "192.168.1.10:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(session.kind, .emby)
            XCTAssertFalse(session.supportsQuickConnect, "Emby 没有 Quick Connect")
            XCTAssertEqual(session.baseURL.absoluteString, "http://192.168.1.10:8096/emby")

            // 密码登录 → finish 落盘 kind 与带前缀的 baseURL
            let result = try await session.signIn(username: "jumusu", password: "hunter2")
            XCTAssertEqual(result.token, "tok-emby")
            let server = try session.finish(result, store: store)
            XCTAssertEqual(server.profile.kind, .emby)
            XCTAssertEqual(server.profile.baseURL.absoluteString, "http://192.168.1.10:8096/emby")
        }
    }

    func testStartLoginKeepsJellyfinKindAndRawBaseURL() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/System/Info/Public")
            return MockURLProtocol.ok(
                #"{"ServerName":"jf-nas","Version":"10.9.11","Id":"srv-1"}"#,
                for: request.url!
            )
        } with: {
            let session = try await JellyfinServer.startLogin(urlString: "192.168.1.10:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(session.kind, .jellyfin)
            XCTAssertTrue(session.supportsQuickConnect)
            XCTAssertEqual(session.baseURL.absoluteString, "http://192.168.1.10:8096")
        }
    }

    func testDetectKindByProductNameAndVersion() {
        XCTAssertEqual(JellyfinServer.detectKind(info: .init(productName: "Emby Server", version: "4.8.0.42")), .emby)
        XCTAssertEqual(JellyfinServer.detectKind(info: .init(productName: nil, version: "4.7.2")), .emby, "无 ProductName 时按 4.x 主版本兜底")
        XCTAssertEqual(JellyfinServer.detectKind(info: .init(productName: "Jellyfin Server", version: "10.9.11")), .jellyfin)
        XCTAssertEqual(JellyfinServer.detectKind(info: .init(productName: nil, version: nil)), .jellyfin)
    }

    func testEmbyAPIBaseURLAppendsPrefixOnce() throws {
        XCTAssertEqual(JellyfinServer.embyAPIBaseURL(from: URL(string: "http://nas.local:8096")!).absoluteString,
                       "http://nas.local:8096/emby")
        // 已带 /emby（用户手写或反代子路径）不重复追加
        XCTAssertEqual(JellyfinServer.embyAPIBaseURL(from: URL(string: "http://nas.local:8096/emby")!).absoluteString,
                       "http://nas.local:8096/emby")
        XCTAssertEqual(JellyfinServer.embyAPIBaseURL(from: URL(string: "https://media.example.com/emby/")!).absoluteString,
                       "https://media.example.com/emby")
        // 已有其它子路径时追加到末尾
        XCTAssertEqual(JellyfinServer.embyAPIBaseURL(from: URL(string: "https://host/media")!).absoluteString,
                       "https://host/media/emby")
    }

    /// Emby 走老式路由：媒体库 `/Users/{id}/Views`、继续观看 `/Users/{id}/Items/Resume`。
    func testEmbyRoutesUseLegacyPaths() async throws {
        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", userName: "jumusu",
                                        serverVersion: "4.8.0.42", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            switch request.url?.path {
            // client baseURL 带 /emby，Get 拼 URL 保留子路径
            case "/emby/Users/user-e/Views":
                return MockURLProtocol.ok(
                    #"{"Items":[{"Id":"lib-1","Name":"电影","CollectionType":"movies"}],"TotalRecordCount":1}"#,
                    for: request.url!
                )
            case "/emby/Users/user-e/Items/Resume":
                return MockURLProtocol.ok(
                    #"{"Items":[{"Id":"m-1","Name":"沙丘","Type":"Movie"}],"TotalRecordCount":1}"#,
                    for: request.url!
                )
            default:
                XCTFail("Emby 不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let views = try await server.userViews()
            XCTAssertEqual(views.map(\.id), ["lib-1"])

            let resume = try await server.resumeItems()
            XCTAssertEqual(resume.map(\.id), ["m-1"])
        }
    }

    /// 真实 Emby 4.10 登录成功响应带 SDK 强类型解不了的字段（UserPolicy 变体等），
    /// 曾炸出 "The data couldn't be read because it is missing"。宽松解码只抽
    /// AccessToken / User.Id / User.Name，其余字段无论形状一律忽略。
    func testParseLoginResponseToleratesEmbyExtraFields() throws {
        let embyShaped = """
        {"User":{"Name":"jumusu","ServerName":"BBemby","Id":"e2b1longid",
          "HasPassword":true,"HasConfiguredPassword":true,"EnableAutoLogin":false,
          "LastLoginDate":"2026-08-27T06:00:00Z","LastActivityDate":"2026-08-27T05:59:00Z",
          "Policy":{"IsAdministrator":true,"EnableContentDeletion":true,
            "AuthenticationProviderId":"Emby.Server.Implementations.Library.DefaultAuthenticationProvider",
            "PasswordResetProviderId":"Default","InvalidLoginAttemptCount":3,
            "RemoteClientBitrateLimit":0,"EnableAllFolders":true,"EnabledFolders":[]},
          "Configuration":{"SubtitleMode":"Default","DisplayMissingEpisodes":false}},
         "SessionInfo":{"Id":"sess-1","UserId":"e2b1longid","Client":"Emby Web",
           "LastActivityDate":"2026-08-27T06:00:00Z","Capabilities":{}},
         "AccessToken":"embytoken123","ServerId":"02b4c457"}
        """.data(using: .utf8)!
        let result = try LoginSession.parseLoginResponse(embyShaped)
        XCTAssertEqual(result.token, "embytoken123")
        XCTAssertEqual(result.userID, "e2b1longid")
        XCTAssertEqual(result.userName, "jumusu")
    }

    /// 缺 token / 缺 User.Id 的成功响应不能当作登录成功。
    func testParseLoginResponseRejectsIncompletePayload() {
        XCTAssertThrowsError(try LoginSession.parseLoginResponse(#"{"SessionInfo":{}}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try LoginSession.parseLoginResponse(#"{"AccessToken":"t"}"#.data(using: .utf8)!))
        // 非对象响应（纯文本错误体出现在 2xx 之外的路径上）也不许崩成 other
        XCTAssertThrowsError(try LoginSession.parseLoginResponse("用户名或密码无效".data(using: .utf8)!))
    }

    /// 宽松解码走真实请求链路：mock 返回带 Emby 杂字段的响应，signIn 照样出结果。
    func testSignInWorksWithEmbyShapedSuccessResponse() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(
                    #"{"ServerName":"emby-nas","Version":"4.8.0.42","Id":"emby-1","ProductName":"Emby Server"}"#,
                    for: request.url!
                )
            case "/emby/Users/AuthenticateByName":
                let body = """
                {"User":{"Name":"jumusu","Id":"user-e","Policy":{"IsAdministrator":true,"Odd":{"nested":[1,2,{"x":null}]}}},
                 "AccessToken":"tok-loose","ServerId":"emby-1"}
                """
                return MockURLProtocol.ok(body, for: request.url!)
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await JellyfinServer.startLogin(urlString: "http://nas.local:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            let result = try await session.signIn(username: "jumusu", password: "hunter2")
            XCTAssertEqual(result.token, "tok-loose")
            XCTAssertEqual(result.userID, "user-e")
        }
    }

    /// Emby 登录密码错误回 400（老版本）：归成 unauthorized 提示而不是裸 HTTP 400。
    func testEmbyPasswordSignInMaps400ToUnauthorized() async throws {
        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/System/Info/Public":
                return MockURLProtocol.ok(
                    #"{"ServerName":"emby-nas","Version":"4.7.2","Id":"emby-1","ProductName":"Emby Server"}"#,
                    for: request.url!
                )
            case "/emby/Users/AuthenticateByName":
                let response = HTTPURLResponse(url: request.url!, statusCode: 400,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"Invalid user or password entered."}"#.utf8))
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let session = try await JellyfinServer.startLogin(urlString: "http://nas.local:8096", sessionConfiguration: TestSupport.mockedSessionConfiguration())
            do {
                _ = try await session.signIn(username: "x", password: "bad")
                XCTFail("400 应该抛错")
            } catch let error as JellyfinError {
                guard case .unauthorized = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
            }
        }
    }

    /// Emby 4.10 的 Views 返回 SDK `CollectionType` 枚举外的值（如 "mixed"），
    /// 强类型解码曾整包炸成 "The data couldn't be read"。sanitizer 洗掉未知值后
    /// 正常出媒体库，已知值（含大小写变体）不受影响。
    func testUserViewsToleratesUnknownCollectionTypes() async throws {
        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Users/user-e/Views")
            return MockURLProtocol.ok(
                """
                {"Items":[
                  {"Id":"lib-1","Name":"电影","CollectionType":"movies"},
                  {"Id":"lib-2","Name":"混合库","CollectionType":"mixed"},
                  {"Id":"lib-3","Name":"合集","CollectionType":"BoxSets"},
                  {"Id":"lib-4","Name":"文件夹","CollectionType":null,"Type":"CollectionFolder"}
                ],"TotalRecordCount":4}
                """,
                for: request.url!
            )
        } with: {
            let views = try await server.userViews()
            // mixed 被洗掉归 unknown → 过滤；CollectionFolder 压成 Folder → folders 也过滤
            XCTAssertEqual(views.map(\.name), ["电影", "合集"])
        }
    }

    /// 回归：宽松解码的裸 JSONDecoder 没有 SDK 的 ISO8601 日期配置，响应里
    /// 带 DateCreated 等日期字段时炸 typeMismatch，两台服务器首页/媒体库全挂。
    func testLooseDecodeHandlesDatesAndKeylessUserData() async throws {        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/emby/Users/user-e/Views":
                return MockURLProtocol.ok(
                    """
                    {"Items":[
                      {"Id":"lib-1","Name":"电影","CollectionType":"movies",
                       "DateCreated":"2026-08-01T12:34:56.0000000Z",
                       "UserData":{"IsFavorite":false,"PlaybackPositionTicks":0}}
                    ],"TotalRecordCount":1}
                    """,
                    for: request.url!
                )
            case "/emby/Users/user-e/Items/Latest":
                return MockURLProtocol.ok(
                    """
                    [{"Id":"m-1","Name":"新电影","Type":"Movie",
                      "DateCreated":"2026-08-20T08:00:00Z",
                      "UserData":{"PlayedPercentage":12.5}}]
                    """,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let views = try await server.userViews()
            XCTAssertEqual(views.map(\.name), ["电影"])

            let latest = try await server.latestItems()
            XCTAssertEqual(latest.map(\.id), ["m-1"])
        }
    }

    /// Emby 的「最近添加」必须走老式 `/Users/{id}/Items/Latest`（新式实测 404），
    /// 返回裸数组；Type 未知值（如 CollectionFolder）洗成 Folder 后正常解码。
    func testLatestItemsUsesLegacyRouteOnEmby() async throws {
        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Users/user-e/Items/Latest")
            return MockURLProtocol.ok(
                """
                [{"Id":"m-1","Name":"新电影","Type":"Movie","ProductionYear":2026},
                 {"Id":"lib-9","Name":"神秘库","Type":"CollectionFolder"}]
                """,
                for: request.url!
            )
        } with: {
            let items = try await server.latestItems()
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].name, "新电影")
            XCTAssertEqual(items[0].kind, .movie)
            XCTAssertEqual(items[1].kind, .folder, "未知 Type 压成 Folder → 域模型 .folder")
        }
    }

    /// Emby 没有 `/Items/{id}` 新式路由（实测 404），详情走 `/Users/{uid}/Items/{id}`。
    func testEmbyDetailUsesLegacyRoute() async throws {
        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/emby/Users/user-e/Items/abc":
                let query = TestSupport.queryItems(of: request)
                XCTAssertEqual(query["fields"], "People,Genres,Overview,Chapters")
                return MockURLProtocol.ok(
                    """
                    {"Id":"abc","Name":"沙丘 2","Type":"Movie",
                     "People":[{"Id":"p-1","Name":"提莫西","Role":"Paul","Type":"Actor"}]}
                    """,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let item = try await server.item("abc")
            XCTAssertEqual(item.name, "沙丘 2")
            XCTAssertEqual(item.cast.first?.name, "提莫西")
        }
    }

    /// 回归（Emby 真机实测）：MediaSources[].Type 报 "Folder"（SDK 只有
    /// Default/Grouping/Placeholder）炸详情与 PlaybackInfo；GenreItems[].Id
    /// 是数字（Jellyfin 是字符串）炸 typeMismatch。
    func testSanitizeMediaSourceTypeAndNumericGenreIDs() async throws {
        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/emby/Users/user-e/Items/abc":
                return MockURLProtocol.ok(
                    """
                    {"Id":"abc","Name":"与剧","Type":"Series",
                     "Genres":["动作","科幻"],
                     "GenreItems":[{"Id":28,"Name":"动作"},{"Id":9527,"Name":"科幻"}],
                     "Studios":[{"Id":100,"Name":"MAPPA"}],
                     "MediaSources":[{"Id":"src-1","Type":"Folder",
                       "MediaStreams":[{"Type":"Video","Index":0}]}]}
                    """,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            // 修复前：GenreItems 的数字 Id 炸 typeMismatch 整包失败；
            // 修复后：数字 Id 字符串化，解码通过、genres 正常映射。
            let item = try await server.item("abc")
            XCTAssertEqual(item.genres, ["动作", "科幻"])
        }
    }

    /// 回归（Emby 真机实测）：详情接口请求 `fields=Chapters`，顶层 BaseItemDto
    /// 自己就带 `MediaStreams`。旧 sanitizer 靠「有 MediaStreams」判定是
    /// MediaSourceInfo，把顶层 `Type:"Episode"` 洗成 `"Default"`——SDK 的
    /// `BaseItemKind` 没有 Default（那是 MediaSourceType 的值），整包炸成
    /// "Cannot initialize BaseItemKind from invalid String value Default"，
    /// 章节列表每次都拉取失败只剩保底。修复后顶层 kind 保留为 episode，
    /// 同时 MediaSources[] 里的 Folder 仍正确洗成 Default。
    func testEmbyDetailTopLevelKindNotSanitizedAway() async throws {
        let embyProfile = ServerProfile(id: "emby-1:user-e", serverName: "emby-nas",
                                        baseURL: URL(string: "http://nas.local:8096/emby")!,
                                        userID: "user-e", kind: .emby)
        let server = JellyfinServer(profile: embyProfile, client: JellyfinServer.makeClient(baseURL: embyProfile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        try await TestSupport.withMock { request in
            switch request.url?.path {
            case "/emby/Users/user-e/Items/ep-1":
                // 顶层 Type=Episode + 顶层 MediaStreams（fields=Chapters 带回来），
                // MediaSources[] 里 Type=Folder（Emby 直连源常见）。
                return MockURLProtocol.ok(
                    """
                    {"Id":"ep-1","Name":"第 1 集","Type":"Episode",
                     "ParentIndexNumber":1,"IndexNumber":1,
                     "MediaStreams":[{"Type":"Video","Index":0},
                                      {"Type":"Subtitle","Index":1}],
                     "MediaSources":[{"Id":"src-1","Type":"Folder",
                       "MediaStreams":[{"Type":"Video","Index":0}]}],
                     "Chapters":[{"StartPositionTicks":0,"Name":"章一"}]}
                    """,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(request.url?.path ?? "?")")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let item = try await server.item("ep-1")
            // 顶层 kind 必须仍是 episode（旧实现被洗成 Default → .other）。
            XCTAssertEqual(item.kind, .episode, "顶层 Type 不应被 MediaSource 规则洗掉")
            XCTAssertEqual(item.seasonNumber, 1)
            XCTAssertEqual(item.episodeNumber, 1)

            // chapters() 走同一详情接口，修复前直接抛解码错误。
            let chapters = try await server.chapters(itemID: "ep-1")
            XCTAssertEqual(chapters.count, 1, "章节列表应正常解码，不再只剩保底")
            XCTAssertEqual(chapters.first?.name, "章一")
        }
    }
}
