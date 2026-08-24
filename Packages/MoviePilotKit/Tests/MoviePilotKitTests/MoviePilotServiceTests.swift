import XCTest
@testable import MoviePilotKit

/// 搜索 / 下载 API 的离线测试：重点盯「原始 JSON 无损回传」。
final class MoviePilotServiceTests: XCTestCase {

    private var store: MoviePilotStore!
    private var client: MoviePilotAPIClient!

    override func setUp() {
        super.setUp()
        Self.streamAttempts = 0
        store = MoviePilotStore(defaults: TestSupport.isolatedDefaults())
        client = MoviePilotAPIClient(
            store: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()
        )
        store.updateCredentials(
            serverURLString: "http://192.168.1.10:3000",
            username: "admin",
            password: "secret"
        )
        store.accessToken = "jwt-1"
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// @Sendable 回调里收集文案用的锁盒子（Swift 6 不许捕获可变局部变量）。
    private final class TextCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ text: String) {
            lock.lock()
            items.append(text)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    func testSearchMediaDecodesTypedFields() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertEqual(url.path, "/api/v1/media/search")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "title", value: "葬送的芙莉莲")))
            return MockURLProtocol.response(
                #"""
                [
                  {"media_source":"bangumi","type":"电视剧","title":"葬送的芙莉莲",
                   "year":"2023","media_id":"bangumi:400602","bangumi_id":400602,
                   "vote_average":8.8,"poster_path":"/xk.jpg","overview":"魔法…"}
                ]
                """#,
                status: 200, for: url)
        }

        let results = try await client.searchMedia(title: "葬送的芙莉莲")
        XCTAssertEqual(results.count, 1)
        let media = results[0]
        XCTAssertEqual(media.title, "葬送的芙莉莲")
        XCTAssertEqual(media.mediaId, "bangumi:400602")
        XCTAssertEqual(media.bangumiId, 400602)
        XCTAssertEqual(media.voteAverage, 8.8)
        XCTAssertEqual(media.mediaSource, "bangumi")
        // 相对海报路径按 TMDB 规则补齐。
        XCTAssertEqual(media.posterURL?.absoluteString, "https://image.tmdb.org/t-p/w500/xk.jpg")
    }

    /// SSE 帧体：一行一个事件（与真实服务端一致，事件 JSON 不换行）。
    private static func sseBody(_ events: [String]) -> Data {
        Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }

    private static func streamResponse(_ body: Data, for url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, body)
    }

    func testStreamSearchParsesAppendAndDone() async throws {
        let torrentA: [String: Any] = [
            "site_name": "萝莉", "title": "Frieren.S01.1080p",
            "enclosure": "https://t/a.torrent", "size": 8_589_934_592,
            "seeders": 42, "downloadvolumefactor": 0, "volume_factor": "免费",
            "labels": ["精选", "中字"],
        ]
        let torrentB: [String: Any] = [
            "site_name": "馒头", "title": "Frieren.S01.720p",
            "enclosure": "https://t/b.torrent", "size": 2_147_483_648,
            "seeders": 7, "downloadvolumefactor": 1, "volume_factor": "普通",
        ]
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertEqual(url.path, "/api/v1/search/title/stream")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // sites 必须逗号分隔（服务端 _parse_site_list 只认逗号）。
            XCTAssertTrue(query.contains(URLQueryItem(name: "sites", value: "1,3")))
            let body = Self.sseBody([
                #"{"type":"append","stage":"searching","text":"开始搜索，共 31 个站点","finished":0,"total":31,"items":[]}"#,
                #"{"type":"append","text":"已完成 3 / 31","finished":3,"total":31,"total_items":1,"items":[{"torrent_info":\#(Self.json(torrentA))}],"meta_info":{}}"#,
                #"{"type":"done","text":"搜索完成","finished":31,"total":31,"total_items":2,"items":[{"torrent_info":\#(Self.json(torrentB))}]}"#,
            ])
            return Self.streamResponse(body, for: url)
        }

        let progressTexts = TextCollector()
        let torrents = try await client.searchTorrentsByTitleStream(
            keyword: "frieren",
            sites: [1, 3]
        ) { _, progress in
            progressTexts.append(progress.text ?? "")
        }

        XCTAssertEqual(torrents.count, 2, "append×1 + done 补 1 条")
        XCTAssertEqual(torrents[0].siteName, "萝莉")
        XCTAssertEqual(torrents[0].labels, ["精选", "中字"])
        XCTAssertTrue(torrents[0].isFree, "downloadvolumefactor=0 / volume_factor=免费 双信号")
        XCTAssertFalse(torrents[1].isFree)
        XCTAssertTrue(progressTexts.all.contains { $0.contains("3 / 31") }, "进度回调要有服务端文案")
    }

    func testStreamSearchReloginsOn401AndRetries() async throws {
        store.accessToken = "expired-jwt"
        let torrent: [String: Any] = [
            "site_name": "站点A", "title": "T",
            "enclosure": "https://t/1.torrent", "seeders": 1,
        ]
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/search/title/stream":
                // 第一次 cookie 过期，重登后重放成功。
                if request.value(forHTTPHeaderField: "Authorization") == nil && Self.streamAttempts == 0 {
                    Self.streamAttempts += 1
                    return MockURLProtocol.response(
                        #"{"detail":"Not authenticated"}"#, status: 401, for: url)
                }
                let body = Self.sseBody([
                    #"{"type":"done","text":"完成","items":[{"torrent_info":\#(Self.json(torrent))}]}"#,
                ])
                return Self.streamResponse(body, for: url)
            case "/api/v1/login/access-token":
                return MockURLProtocol.response(
                    #"{"access_token":"jwt-2","token_type":"bearer"}"#, status: 200, for: url)
            default:
                XCTFail("意外请求：\(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        let torrents = try await client.searchTorrentsByTitleStream(keyword: "k")
        XCTAssertEqual(torrents.count, 1)
        XCTAssertEqual(Self.streamAttempts, 1, "401 后必须重登并重试一次")
    }

    private nonisolated(unsafe) static var streamAttempts = 0

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    func testSitesListDecodesThroughEnvelope() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertTrue(url.absoluteString.hasSuffix("/api/v1/site/"))
            return MockURLProtocol.response(
                #"""
                {"success":true,"message":"","data":[
                  {"id":1,"name":"站点A","domain":"a.example.com","is_active":true},
                  {"id":2,"name":"站点B","domain":"b.example.com","is_active":false}
                ]}
                """#,
                status: 200, for: url)
        }
        let sites = try await client.sites()
        XCTAssertEqual(sites.count, 2)
        XCTAssertEqual(sites[0].name, "站点A")
        XCTAssertTrue(sites[0].isActive)
        XCTAssertFalse(sites[1].isActive)
    }

    func testAddDownloadEchoesRawObjectsVerbatim() async throws {
        // 带服务端才认识的字段（downloadvolumefactor / pri_order），验证原样回传。
        let mediaRaw: [String: JSONValue] = [
            "media_id": .string("tmdb:12345"),
            "media_source": .string("tmdb"),
            "type": .string("电影"),
            "title": .string("测试电影"),
            "tmdb_info": .object(["id": .number(12345), "original_title": .string("Test")]),
        ]
        let torrentRaw: [String: JSONValue] = [
            "site": .number(1),
            "site_name": .string("站点A"),
            "title": .string("Movie.2024.2160p"),
            "enclosure": .string("https://t/1.torrent"),
            "size": .number(42_000_000_000),
            "downloadvolumefactor": .number(0),
            "pri_order": .number(1),
        ]
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            // 注意：新版 Foundation 的 URL.path 会剥掉末尾斜杠，断言用 absoluteString
            // （FastAPI 的 /download/ 路由靠 307 重定向也能兜，但首发就该对）。
            XCTAssertEqual(url.absoluteString, "http://192.168.1.10:3000/api/v1/download/")
            XCTAssertEqual(request.httpMethod, "POST")
            guard let bodyData = TestSupport.body(of: request),
                  let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let mediaIn = body["media_in"] as? [String: Any],
                  let torrentIn = body["torrent_in"] as? [String: Any]
            else {
                XCTFail("下载请求体不完整")
                throw URLError(.badURL)
            }
            // snake_case key 原样保留（没被 convertFromSnakeCase 污染）。
            XCTAssertEqual(mediaIn["media_id"] as? String, "tmdb:12345")
            XCTAssertEqual((torrentIn["downloadvolumefactor"] as? Double), 0)
            XCTAssertEqual((torrentIn["pri_order"] as? Double), 1)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-1")
            return MockURLProtocol.response(
                #"{"success":true,"message":"添加成功","data":{"download_id":"abc"}}"#,
                status: 200, for: url)
        }

        try await client.addDownload(
            media: MPMediaInfo(raw: mediaRaw),
            torrent: MPTorrent(raw: torrentRaw)
        )
    }

    func testAddDownloadServerRefusalThrowsWithMessage() async throws {
        let media = MPMediaInfo(raw: ["media_id": .string("tmdb:1")])
        let torrent = MPTorrent(raw: ["enclosure": .string("https://t/1.torrent")])
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return MockURLProtocol.response(
                #"{"success":false,"message":"下载器未就绪"}"#, status: 200, for: url)
        }
        do {
            try await client.addDownload(media: media, torrent: torrent)
            XCTFail("应该抛错")
        } catch let error as MoviePilotError {
            XCTAssertTrue("\(error)".contains("下载器未就绪"), "服务端 message 要透出：\(error)")
        }
    }

    func testSearchMediaHandlesAutoEnvelope() async throws {
        // v3 ResponseAPIRouter 把列表也包进 {success, data}；剥壳后照常解析。
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return MockURLProtocol.response(
                #"""
                {"success":true,"message":"","data":[
                  {"media_source":"tmdb","type":"电影","title":"测试电影",
                   "year":"2024","media_id":"tmdb:42","tmdb_id":42}
                ]}
                """#,
                status: 200, for: url)
        }
        let results = try await client.searchMedia(title: "测试")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "测试电影")
        XCTAssertEqual(results[0].mediaId, "tmdb:42")
    }

    func testDownloadingTasksDecode() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertTrue(url.absoluteString.hasSuffix("/api/v1/download/"),
                          "末尾斜杠不能丢：\(url.absoluteString)")
            return MockURLProtocol.response(
                #"""
                [{"hash":"abc123","name":"Show.S01","site_name":"站点A","size":10737418240,
                  "progress":42.0,"state":"downloading","dlspeed":"12.3 MB/s","left_time":"8分钟",
                  "media":{"title":"败犬女主太多了！","type":"电视剧"}}]
                """#,
                status: 200, for: url)
        }
        let tasks = try await client.downloadingTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].hash, "abc123")
        // progress 是 0–100 百分数：42 → 0.42。
        XCTAssertEqual(tasks[0].progressFraction, 0.42, accuracy: 0.001)
        XCTAssertEqual(tasks[0].dlspeed, "12.3 MB/s")
        XCTAssertEqual(tasks[0].leftTime, "8分钟")
        XCTAssertEqual(tasks[0].mediaTitle, "败犬女主太多了！")
        XCTAssertFalse(tasks[0].isPaused)
    }

    func testDownloadControlHitsRightPaths() async throws {
        let expectations: [(String, String)] = [
            ("start", "/api/v1/download/start/abc123"),
            ("stop", "/api/v1/download/stop/abc123"),
            ("delete", "/api/v1/download/abc123"),
        ]
        for (action, expectedPath) in expectations {
            MockURLProtocol.handler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                XCTAssertEqual(url.path, expectedPath)
                XCTAssertEqual(
                    request.httpMethod ?? "GET", action == "delete" ? "DELETE" : "GET")
                return MockURLProtocol.response(
                    #"{"success":true,"message":""}"#, status: 200, for: url)
            }
            switch action {
            case "start": try await client.startDownload(hash: "abc123")
            case "stop": try await client.stopDownload(hash: "abc123")
            default: try await client.removeDownload(hash: "abc123")
            }
        }
    }

    func testSubscribesDecodesTypedFields() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertTrue(url.absoluteString.hasSuffix("/api/v1/subscribe/"))
            return MockURLProtocol.response(
                #"""
                {"success":true,"message":"","data":[
                  {
                    "id": 101,
                    "name": "葬送的芙莉莲",
                    "type": "电视剧",
                    "year": "2023",
                    "season": 1,
                    "total_episode": 28,
                    "lack_episode": 0,
                    "poster": "https://image.tmdb.org/t-p/w500/xk.jpg",
                    "vote_average": 8.9,
                    "state": "R"
                  },
                  {
                    "id": 102,
                    "name": "奥本海默",
                    "type": "电影",
                    "year": "2023",
                    "total_episode": 0,
                    "lack_episode": 0,
                    "poster_path": "/oppenheimer.jpg",
                    "vote_average": 8.1,
                    "state": "O"
                  }
                ]}
                """#,
                status: 200, for: url)
        }

        let subscribes = try await client.subscribes()
        XCTAssertEqual(subscribes.count, 2)

        let tv = subscribes[0]
        XCTAssertEqual(tv.subscribeId, 101)
        XCTAssertEqual(tv.name, "葬送的芙莉莲")
        XCTAssertTrue(tv.isTV)
        XCTAssertFalse(tv.isMovie)
        XCTAssertEqual(tv.season, 1)
        XCTAssertEqual(tv.totalEpisode, 28)
        XCTAssertEqual(tv.lackEpisode, 0)
        XCTAssertEqual(tv.stateText, "追更中")
        XCTAssertEqual(tv.posterURL?.absoluteString, "https://image.tmdb.org/t-p/w500/xk.jpg")

        let movie = subscribes[1]
        XCTAssertEqual(movie.subscribeId, 102)
        XCTAssertEqual(movie.name, "奥本海默")
        XCTAssertTrue(movie.isMovie)
        XCTAssertFalse(movie.isTV)
        XCTAssertEqual(movie.stateText, "已完成")
        XCTAssertEqual(movie.posterURL?.absoluteString, "https://image.tmdb.org/t-p/w500/oppenheimer.jpg")
    }

    func testAddSubscribeSendsValidBody() async throws {
        let mediaRaw: [String: JSONValue] = [
            "title": .string("间谍过家家"),
            "type": .string("电视剧"),
            "year": .string("2022"),
            "tmdb_id": .number(120089),
            "poster_path": .string("/spy.jpg"),
            "overview": .string("间谍日常…"),
        ]
        let media = MPMediaInfo(raw: mediaRaw)

        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertTrue(url.absoluteString.hasSuffix("/api/v1/subscribe/"))
            XCTAssertEqual(request.httpMethod, "POST")
            guard let bodyData = TestSupport.body(of: request),
                  let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            else {
                XCTFail("请求体解析失败")
                throw URLError(.badURL)
            }
            XCTAssertEqual(body["name"] as? String, "间谍过家家")
            XCTAssertEqual(body["type"] as? String, "电视剧")
            XCTAssertEqual((body["tmdbid"] as? Double), 120089)
            XCTAssertEqual(body["poster"] as? String, "https://image.tmdb.org/t-p/w500/spy.jpg")
            return MockURLProtocol.response(
                #"{"success":true,"message":"订阅成功"}"#,
                status: 200, for: url)
        }

        try await client.addSubscribe(media: media, season: 1)
    }

    func testDeleteAndRefreshSubscribes() async throws {
        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/v1/subscribe/101" {
                XCTAssertEqual(request.httpMethod, "DELETE")
                return MockURLProtocol.response(
                    #"{"success":true,"message":"删除成功"}"#,
                    status: 200, for: url)
            } else if url.path == "/api/v1/subscribe/refresh" {
                XCTAssertEqual(request.httpMethod, "GET")
                return MockURLProtocol.response(
                    #"{"success":true,"message":"已触发刷新"}"#,
                    status: 200, for: url)
            } else if url.path == "/api/v1/subscribe/search" {
                XCTAssertEqual(request.httpMethod, "GET")
                return MockURLProtocol.response(
                    #"{"success":true,"message":"已触发搜索"}"#,
                    status: 200, for: url)
            }
            XCTFail("未知路径：\(url.path)")
            throw URLError(.badURL)
        }

        try await client.deleteSubscribe(id: 101)
        try await client.refreshSubscribes()
        try await client.searchSubscribes()
    }

    func testUpdateSubscribeSendsValidBody() async throws {
        let subRaw: [String: JSONValue] = [
            "id": .number(101),
            "name": .string("葬送的芙莉莲"),
            "type": .string("电视剧"),
            "season": .number(1),
            "total_episode": .number(28),
            "lack_episode": .number(2),
            "keyword": .string("Frieren"),
            "include": .string("1080p, HEVC"),
            "exclude": .string("CAM"),
            "state": .string("R"),
        ]
        let subscribe = MPSubscribe(raw: subRaw)

        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertTrue(url.absoluteString.hasSuffix("/api/v1/subscribe/"))
            XCTAssertEqual(request.httpMethod, "PUT")
            guard let bodyData = TestSupport.body(of: request),
                  let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            else {
                XCTFail("请求体解析失败")
                throw URLError(.badURL)
            }
            XCTAssertEqual(body["name"] as? String, "葬送的芙莉莲")
            XCTAssertEqual(body["keyword"] as? String, "Frieren")
            XCTAssertEqual(body["include"] as? String, "1080p, HEVC")
            XCTAssertEqual((body["id"] as? Double), 101)
            return MockURLProtocol.response(
                #"{"success":true,"message":"更新成功"}"#,
                status: 200, for: url)
        }

        try await client.updateSubscribe(subscribe: subscribe)
    }
}
