import CoreModel
import XCTest
@testable import JellyfinKit

/// Emby 实现（`EmbyServer`）的离线测试：老式路由 + 宽松 DTO 的值域容忍度。
///
/// 这些用例替代了原先那批「洗白层」用例 —— 换掉强类型解码后，脏枚举值不再需要
/// 被改写，只需要**不影响解码**。所以断言从「值被洗成了什么」变成「响应仍能解出
/// 域模型，且真值没丢」。
final class EmbyServerTests: XCTestCase {

    private static let baseURL = "http://nas.local:8096/emby"

    private func makeServer() -> EmbyServer {
        let profile = ServerProfile(
            id: "emby-1:user-e",
            serverName: "emby-nas",
            baseURL: URL(string: Self.baseURL)!,
            userID: "user-e",
            userName: "jumusu",
            serverVersion: "4.8.0.42",
            kind: .emby
        )
        // profileID 与生产一致地传进去：已登录会话的 401 要发鉴权失效通知。
        return EmbyServer(
            profile: profile,
            session: EmbySession(
                baseURL: profile.baseURL,
                accessToken: "tok",
                profileID: profile.id,
                sessionConfiguration: TestSupport.mockedSessionConfiguration()
            )
        )
    }

    // MARK: - 老式路由

    func testUserViewsUsesLegacyRouteAndFiltersUnknownCollections() async throws {
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
            let views = try await makeServer().userViews()
            // mixed 认不出 → unknown → 过滤；无 CollectionType 的也过滤。
            // "BoxSets" 是大小写变体，归一后是已知类型，必须留下。
            XCTAssertEqual(views.map(\.name), ["电影", "合集"])
        }
    }

    func testLatestItemsUsesLegacyRouteAndBareArray() async throws {
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
            let items = try await makeServer().latestItems(limit: 24)
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].name, "新电影")
            XCTAssertEqual(items[0].kind, .movie)
            XCTAssertEqual(items[1].kind, .folder, "CollectionFolder 归到 .folder，而不是炸解码")
        }
    }

    func testResumeItemsUsesLegacyRoute() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Users/user-e/Items/Resume")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"m-1","Name":"沙丘","Type":"Movie"}],"TotalRecordCount":1}"#,
                for: request.url!
            )
        } with: {
            let items = try await makeServer().resumeItems()
            XCTAssertEqual(items.map(\.id), ["m-1"])
        }
    }

    func testDetailUsesLegacyRouteAndMapsCast() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Users/user-e/Items/abc")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["fields"], "People,Genres,Overview,Chapters")
            return MockURLProtocol.ok(
                """
                {"Id":"abc","Name":"沙丘 2","Type":"Movie",
                 "People":[{"Id":"p-1","Name":"提莫西","Role":"Paul","Type":"Actor"}]}
                """,
                for: request.url!
            )
        } with: {
            let item = try await makeServer().item("abc")
            XCTAssertEqual(item.name, "沙丘 2")
            XCTAssertEqual(item.cast.first?.name, "提莫西")
            XCTAssertEqual(item.cast.first?.kind, "Actor")
        }
    }

    func testMarkPlayedAndUnplayedUseLegacyRoutes() async throws {
        let methods = LockedStrings()
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Users/user-e/PlayedItems/ep-9")
            XCTAssertEqual(TestSupport.queryItems(of: request)["userId"], "user-e")
            methods.append(request.httpMethod ?? "?")
            return MockURLProtocol.ok(
                #"{"Played":true,"PlaybackPositionTicks":0,"PlayedPercentage":100}"#,
                for: request.url!
            )
        } with: {
            let server = makeServer()
            let played = try await server.markPlayed(itemID: "ep-9")
            XCTAssertTrue(played.played)
            XCTAssertEqual(played.percentage, 1.0, "PlayedPercentage 100 → 域模型 1.0")
            _ = try await server.markUnplayed(itemID: "ep-9")
        }
        XCTAssertEqual(methods.items, ["POST", "DELETE"])
    }

    // MARK: - 宽松值域：脏枚举不影响解码

    /// Emby 把杜比视界写进粗粒度 `VideoRange`（"DolbyVision"），细粒度
    /// `VideoRangeType` 是 "DOVIWithEL"。旧实现靠洗白把 VideoRange 归一成 HDR 才解得开；
    /// 现在不建枚举，两个值都原样收下，**杜比判定靠 VideoRangeType，真值一字不动**。
    func testDolbyVisionSourceKeepsPlaybackInfoAndDolbyDetection() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Items/mv-1/PlaybackInfo")
            return MockURLProtocol.ok(
                """
                {"PlaySessionId":"ps-1","MediaSources":[
                  {"Id":"src-1","Name":"终结者.mkv","Container":"mkv",
                   "SupportsDirectPlay":true,"RunTimeTicks":6000000000,
                   "MediaStreams":[
                     {"Type":"Video","Index":0,"Codec":"hevc",
                      "VideoRange":"DolbyVision","VideoRangeType":"DOVIWithEL"},
                     {"Type":"Audio","Index":1,"Codec":"truehd"}
                   ]}
                ]}
                """,
                for: request.url!
            )
        } with: {
            let info = try await makeServer().playbackInfo(itemID: "mv-1")
            XCTAssertEqual(info.playSessionID, "ps-1")
            let source = try XCTUnwrap(info.preferredSource)
            XCTAssertEqual(source.videoRangeType, "DOVIWithEL", "细粒度值必须原样透传")

            let context = info.sessionContext(itemID: "mv-1", selectedSource: source)
            XCTAssertTrue(context.isDolbyVision, "杜比判定不能失效")
            XCTAssertEqual(context.deliveryMethod, .directPlay)
        }
    }

    /// Emby 给 MKV 内嵌字体报 `MediaStreams[].Type = "Attachment"`（SDK 的
    /// MediaStreamType 没有这个 case，旧实现整包炸）。不建枚举后它只是不匹配
    /// 音视频/字幕分支，被自然忽略，附件流不参与映射。
    func testAttachmentStreamTypeIsIgnoredNotFatal() async throws {
        try await TestSupport.withMock { request in
            // mediaFileInfo 走 `GET /Items?ids=`，响应是 QueryResult 信封。
            return MockURLProtocol.ok(
                """
                {"Items":[{
                  "Id":"item-yuru","Name":"少女终末旅行 S01E06.mkv","Type":"Episode",
                  "ParentIndexNumber":1,"IndexNumber":6,
                  "MediaSources":[
                    {"Id":"ms-yuru","Name":"少女终末旅行 S01E06.mkv","Type":"Folder",
                     "Container":"mkv",
                     "MediaStreams":[
                       {"Type":"Video","Index":0,"Codec":"h264"},
                       {"Type":"Audio","Index":1,"Codec":"aac"},
                       {"Type":"Attachment","Index":2,"Codec":"ttf","FileName":"FOT-Rodin.ttf"}
                     ]}
                  ]}],"TotalRecordCount":1}
                """,
                for: request.url!
            )
        } with: {
            let info = try await makeServer().mediaFileInfo(itemID: "item-yuru")
            let fileInfo = try XCTUnwrap(info)
            XCTAssertEqual(fileInfo.video?.codec, "h264")
            XCTAssertEqual(fileInfo.audioTracks.count, 1)
            XCTAssertTrue(fileInfo.subtitleTracks.isEmpty, "Attachment 不是字幕，不该混进来")
        }
    }

    /// `Type` 这个键名在多个结构里语义不同：顶层是条目类型、`MediaStreams[]` 里是
    /// 流类型。旧洗白层曾把顶层 `Type:"Episode"` 误洗成 `"Default"`，导致详情与
    /// 章节列表全挂。这里锁住顶层 kind 不被流规则污染。
    func testTopLevelKindSurvivesStreamTypeHandling() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Users/user-e/Items/ep-1")
            return MockURLProtocol.ok(
                """
                {"Id":"ep-1","Name":"第 1 集","Type":"Episode",
                 "ParentIndexNumber":1,"IndexNumber":1,
                 "MediaStreams":[{"Type":"Video","Index":0},{"Type":"Subtitle","Index":1}],
                 "MediaSources":[{"Id":"src-1","Name":"剧 S01E01.mkv","Type":"Folder",
                   "MediaStreams":[{"Type":"Video","Index":0}]}],
                 "Chapters":[{"StartPositionTicks":0,"Name":"章一"}]}
                """,
                for: request.url!
            )
        } with: {
            let server = makeServer()
            let item = try await server.item("ep-1")
            XCTAssertEqual(item.kind, .episode, "顶层 Type 必须是 episode")
            XCTAssertEqual(item.seasonNumber, 1)
            XCTAssertEqual(item.episodeNumber, 1)

            let chapters = try await server.chapters(itemID: "ep-1")
            XCTAssertEqual(chapters.map(\.name), ["章一"])
        }
    }

    /// 一批 Emby 侧的真实脏数据一次过：SDK 枚举外的 `LockedFields`、缺 `Key` 的
    /// `UserData`、数字形态的 `GenreItems[].Id`、日期串、`CollectionFolder` 类型。
    /// 这些字段要么本层不消费、要么收成宽松类型，所以一条都不该影响解码。
    func testDirtyFieldsDoNotBreakDecoding() async throws {
        try await TestSupport.withMock { request in
            return MockURLProtocol.ok(
                """
                {"Id":"m-1","Name":"电影一","Type":"Movie","ProductionYear":2026,
                 "DateCreated":"2026-08-01T12:34:56.0000000Z",
                 "LockedFields":["SortName","Overview"],
                 "Genres":["动作","科幻"],
                 "GenreItems":[{"Id":28,"Name":"动作"},{"Id":9527,"Name":"科幻"}],
                 "Studios":[{"Id":100,"Name":"MAPPA"}],
                 "UserData":{"Played":true,"PlayedPercentage":37.5,"PlaybackPositionTicks":18000000000},
                 "ProviderIds":{"Tmdb":"603"}
                }
                """,
                for: request.url!
            )
        } with: {
            let item = try await makeServer().item("m-1")
            XCTAssertEqual(item.kind, .movie)
            XCTAssertEqual(item.year, 2026)
            XCTAssertEqual(item.genres, ["动作", "科幻"])
            XCTAssertEqual(item.tmdbID, "603")
            let state = try XCTUnwrap(item.playState)
            XCTAssertTrue(state.played)
            XCTAssertEqual(state.percentage, 0.375)
            XCTAssertEqual(state.positionSeconds, 1800)
        }
    }

    // MARK: - 片头片尾：从章节 marker 翻译

    /// Emby 没有 `/MediaSegments` 接口（那是 Jellyfin 插件提供的），但它把片头 /
    /// 片尾标成了章节 marker。这里验证三种 marker 被翻译成与 Jellyfin 同形的 segment。
    func testMediaSegmentsTranslateChapterMarkers() async throws {
        try await TestSupport.withMock { request in
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["fields"], "Chapters")
            return MockURLProtocol.ok(
                """
                {"Id":"ep-1","RunTimeTicks":14400000000,
                 "Chapters":[
                   {"StartPositionTicks":0,"MarkerType":"IntroStart"},
                   {"StartPositionTicks":900000000,"MarkerType":"IntroEnd"},
                   {"StartPositionTicks":12000000000,"MarkerType":"CreditsStart"}
                 ]}
                """,
                for: request.url!
            )
        } with: {
            let segments = try await makeServer().mediaSegments(itemID: "ep-1")
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments[0].kind, .intro)
            XCTAssertEqual(segments[0].startSeconds, 0)
            XCTAssertEqual(segments[0].endSeconds, 90)
            // 片尾没有结束 marker，跑到条目结束（14400 ticks = 1440s）。
            XCTAssertEqual(segments[1].kind, .outro)
            XCTAssertEqual(segments[1].startSeconds, 1200)
            XCTAssertEqual(segments[1].endSeconds, 1440)
        }
    }

    /// 很多集只有起始 marker 没有结束 marker：下一个章节的起点就是片头交接给正片的
    /// 位置，用它顶替。后面没有章节的保持无界，不猜长度。
    func testMediaSegmentsInferMissingIntroEndFromNextChapter() async throws {
        try await TestSupport.withMock { request in
            return MockURLProtocol.ok(
                """
                {"Id":"ep-2","RunTimeTicks":14400000000,
                 "Chapters":[
                   {"StartPositionTicks":0,"MarkerType":"IntroStart"},
                   {"StartPositionTicks":950000000,"MarkerType":0}
                 ]}
                """,
                for: request.url!
            )
        } with: {
            let segments = try await makeServer().mediaSegments(itemID: "ep-2")
            XCTAssertEqual(segments.count, 1)
            XCTAssertEqual(segments[0].kind, .intro)
            XCTAssertEqual(segments[0].endSeconds, 95, "缺 IntroEnd 时取下一个章节起点")
        }
    }

    /// marker 也可以发数字下标（顺序即 Emby 枚举声明顺序：chapter/introStart/introEnd/creditsStart）。
    func testMediaSegmentsAcceptNumericMarkerIndex() async throws {
        try await TestSupport.withMock { request in
            return MockURLProtocol.ok(
                """
                {"Id":"ep-3","RunTimeTicks":1000000000,
                 "Chapters":[{"StartPositionTicks":0,"MarkerType":1},
                             {"StartPositionTicks":50000000,"MarkerType":2}]}
                """,
                for: request.url!
            )
        } with: {
            let segments = try await makeServer().mediaSegments(itemID: "ep-3")
            XCTAssertEqual(segments.count, 1)
            XCTAssertEqual(segments[0].kind, .intro)
            XCTAssertEqual(segments[0].endSeconds, 5)
        }
    }

    func testMediaSegmentsEmptyWithoutMarkers() async throws {
        try await TestSupport.withMock { request in
            return MockURLProtocol.ok(
                """
                {"Id":"ep-4","RunTimeTicks":14400000000,
                 "Chapters":[{"StartPositionTicks":0,"Name":"章一"},
                             {"StartPositionTicks":6000000000,"Name":"章二"}]}
                """,
                for: request.url!
            )
        } with: {
            let segments = try await makeServer().mediaSegments(itemID: "ep-4")
            XCTAssertTrue(segments.isEmpty, "只有普通章节、没有 marker 时不该瞎猜")
        }
    }

    // MARK: - 「接下来看」：Emby 4.10 的逐剧扫描兜底

    /// Emby 4.10 对不带 series 范围的 Next Up 恒返回空。这里验证空结果会触发
    /// 逐剧扫描：先取最近看过的剧，再逐部问 scoped NextUp。
    func testNextUpFallsBackToPerSeriesSweepWhenUnscopedIsEmpty() async throws {
        try await TestSupport.withMock { request in
            let path = request.url?.path ?? "?"
            let query = TestSupport.queryItems(of: request)
            switch path {
            case "/emby/Shows/NextUp":
                if let seriesID = query["seriesId"] {
                    // 限定到某部剧时服务端才答得出来。
                    return MockURLProtocol.ok(
                        #"{"Items":[{"Id":"ep-\#(seriesID)","Name":"下一集","Type":"Episode","SeriesId":"\#(seriesID)"}]}"#,
                        for: request.url!
                    )
                }
                return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
            case "/emby/Items":
                XCTAssertEqual(query["filters"], "IsPlayed")
                XCTAssertEqual(query["includeItemTypes"], "Episode")
                return MockURLProtocol.ok(
                    """
                    {"Items":[
                      {"Id":"e1","Type":"Episode","SeriesId":"s-1"},
                      {"Id":"e2","Type":"Episode","SeriesId":"s-1"},
                      {"Id":"e3","Type":"Episode","SeriesId":"s-2"}
                    ],"TotalRecordCount":3}
                    """,
                    for: request.url!
                )
            default:
                XCTFail("不该打到 \(path)")
                throw URLError(.unsupportedURL)
            }
        } with: {
            let items = try await makeServer().nextUp()
            // 去重后按最近看过的顺序逐剧取一条。
            XCTAssertEqual(items.map(\.id), ["ep-s-1", "ep-s-2"])
        }
    }

    /// 服务器**已经慢**的时候不扫。扫描是 1 + N 条额外请求，在一台 warm 都要
    /// 3–9 秒的公网服务器上只会把首页拖得更死 —— 这一行拿不到内容是可接受的降级，
    /// 把整页拖住不是。这里用 mock 里的真实睡眠把无范围那次拖过阈值。
    func testNextUpSkipsSweepWhenServerIsAlreadySlow() async throws {
        try await TestSupport.withMock { request in
            let path = request.url?.path ?? "?"
            // 无范围那次故意慢过阈值；此后**任何**请求都是意外的（扫描不该发生）。
            if path == "/emby/Shows/NextUp",
               TestSupport.queryItems(of: request)["seriesId"] == nil {
                Thread.sleep(forTimeInterval: 1.6)
                return MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
            }
            XCTFail("服务器已慢时不该再发扫描请求：\(path)")
            throw URLError(.unsupportedURL)
        } with: {
            let items = try await makeServer().nextUp()
            XCTAssertTrue(items.isEmpty, "慢服务器上降级为空，而不是把首页拖住")
        }
    }

    /// 非空结果不该触发扫描（省掉 25 次额外请求）。
    func testNextUpSkipsSweepWhenUnscopedReturnsItems() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Shows/NextUp")
            XCTAssertNil(TestSupport.queryItems(of: request)["seriesId"])
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"ep-1","Name":"下一集","Type":"Episode"}]}"#,
                for: request.url!
            )
        } with: {
            let items = try await makeServer().nextUp()
            XCTAssertEqual(items.map(\.id), ["ep-1"])
        }
    }

    // MARK: - 鉴权失效通知

    /// 已登录会话收到 401 → 发通知把 UI 拉回重登流程（与 Jellyfin 侧同口径）。
    func testAuthenticatedSessionPostsNotificationOn401() async throws {
        let posted = LockedStrings()
        let observer = NotificationCenter.default.addObserver(
            forName: MediaServerAuthentication.authenticationRequired,
            object: nil,
            queue: nil
        ) { note in
            posted.append(note.object as? String ?? "?")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await TestSupport.withMock { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        } with: {
            _ = try? await makeServer().userViews()
        }

        XCTAssertEqual(posted.items, ["emby-1:user-e"])
    }

    /// 匿名会话（探活 / 登录阶段）的 401 是密码错误，**不能**发通知 ——
    /// 发了会把用户从登录页踢回登录页。
    func testAnonymousLoginSessionDoesNotPostNotificationOn401() async throws {
        let posted = LockedStrings()
        let observer = NotificationCenter.default.addObserver(
            forName: MediaServerAuthentication.authenticationRequired,
            object: nil,
            queue: nil
        ) { note in
            posted.append(note.object as? String ?? "?")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let session = EmbyLoginSession(
            baseURL: URL(string: Self.baseURL)!,
            info: EmbyPublicSystemInfoDTO(
                id: "emby-1", serverName: "emby-nas",
                version: "4.8.0.42", productName: "Emby Server"
            ),
            session: EmbySession(
                baseURL: URL(string: Self.baseURL)!,
                accessToken: nil,
                sessionConfiguration: TestSupport.mockedSessionConfiguration()
            )
        )

        try await TestSupport.withMock { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        } with: {
            do {
                _ = try await session.signIn(username: "x", password: "bad")
                XCTFail("401 应该抛错")
            } catch let error as JellyfinError {
                guard case .unauthorized = error.kind else {
                    return XCTFail("错误类型不对：\(error.kind)")
                }
            }
        }

        XCTAssertTrue(posted.items.isEmpty, "登录阶段的 401 不该发鉴权失效通知")
    }

    // MARK: - 排序 / 筛选 / 地址 / 认证头

    func testItemsPagePassesSortAndWatchState() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/Items")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["sortBy"], "DateCreated,SortName")
            XCTAssertEqual(query["sortOrder"], "Descending,Ascending")
            XCTAssertEqual(query["filters"], "IsUnplayed")
            XCTAssertEqual(query["includeItemTypes"], "Movie,Series")
            XCTAssertEqual(query["parentId"], "lib-1")
            XCTAssertEqual(query["enableTotalRecordCount"], "true")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"m-1","Name":"沙丘","Type":"Movie"}],"TotalRecordCount":1}"#,
                for: request.url!
            )
        } with: {
            let page = try await makeServer().itemsPage(
                parentID: "lib-1",
                kinds: [.movie, .series],
                recursive: true,
                startIndex: 0,
                limit: 100,
                sort: MediaItemsSort(field: .dateAdded, ascending: false),
                watchState: .unwatched
            )
            XCTAssertEqual(page.items.map(\.id), ["m-1"])
            XCTAssertEqual(page.totalRecordCount, 1)
        }
    }

    func testStreamAndImageURLsCarryNoToken() throws {
        let server = makeServer()
        let stream = try server.streamURL(itemID: "mv-1", mediaSourceID: "src-1", playSessionID: "ps-1")
        XCTAssertTrue(stream.hasPrefix("\(Self.baseURL)/Videos/mv-1/stream?"))
        XCTAssertTrue(stream.contains("Static=true"))
        XCTAssertTrue(stream.contains("mediaSourceId=src-1"))
        XCTAssertFalse(stream.lowercased().contains("token"))
        XCTAssertFalse(stream.lowercased().contains("api_key"))

        let image = try server.imageURL(itemID: "mv-1", type: .backdrop, maxWidth: 800, tag: "t1")
        XCTAssertEqual(image.path, "/emby/Items/mv-1/Images/Backdrop")
        XCTAssertTrue(image.query?.contains("maxWidth=800") == true)
        XCTAssertTrue(image.query?.contains("tag=t1") == true)
        XCTAssertFalse(image.absoluteString.lowercased().contains("token"))
    }

    /// Emby 用 `Emby` scheme，Jellyfin 用 `MediaBrowser` —— 两家唯一的分叉点。
    func testAuthorizationHeaderUsesEmbyScheme() {
        let header = makeServer().authorizationHeader
        XCTAssertTrue(header.hasPrefix("Emby Client=\"OcPlayer\""), header)
        XCTAssertTrue(header.contains("Token=\"tok\""))
    }

    /// Emby 收到不认识的 `Fields` 名字会拒掉**整个请求**，所以只属于 Jellyfin 的
    /// 字段名必须在发出前摘掉。
    func testFieldsWhitelistDropsJellyfinOnlyNames() {
        XCTAssertEqual(embySafeFields("People,Genres,ItemCounts,Overview"),
                       "People,Genres,Overview")
        XCTAssertEqual(embySafeFields("Chapters"), "Chapters")
        XCTAssertNil(embySafeFields("ItemCounts"), "摘空了就整个不发这个参数")
        XCTAssertNil(embySafeFields(nil))
    }
}

/// 测试辅助：并发安全的字符串记录。
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }
}
