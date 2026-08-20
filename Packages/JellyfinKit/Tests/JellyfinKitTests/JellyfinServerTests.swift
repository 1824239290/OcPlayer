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
            XCTAssertEqual(query["fields"], "People,Genres,Overview")
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

    func testLibraryBrowseLoadsEveryPage() async throws {        try await TestSupport.withMock { request in
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

    func testAuthorizationHeaderFormat() {
        let header = makeServer().authorizationHeader
        let expected = ClientIdentity.mediaBrowserAuthorizationHeader(token: "tok-123")
        XCTAssertEqual(header, expected)
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains(#"Token="tok-123""#))
        XCTAssertTrue(header.contains("Client=\"OcPlayer\""))
        XCTAssertTrue(header.contains("DeviceId=\"\(ClientIdentity.deviceID)\""))
    }
}
