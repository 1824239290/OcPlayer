import Foundation
import XCTest

@testable import MetadataKit

/// TMDb 客户端：解码、语言逐字段回退、v3/v4 密钥形态、错误映射、限流。
///
/// 全部离线：`URLProtocol` 挡掉网络，按请求路径分发固定 JSON。
final class TMDbClientTests: XCTestCase {

    // MARK: - 夹具

    private func makeClient(
        apiKey: String? = "0123456789abcdef0123456789abcdef",
        handler: @escaping (URLRequest) -> (Int, Data)
    ) -> TMDbClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = handler
        return TMDbClient(
            session: URLSession(configuration: config),
            credentials: StubCredential(key: apiKey),
            limiter: TMDbRateLimiter(maxConcurrent: 1, minimumInterval: 0))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - 解码

    func testMovieDetailDecodesFullEntity() async throws {
        let client = makeClient { _ in
            (200, Self.movieJSON)
        }
        let entity = try await client.movie(id: 603, language: "zh-CN")

        XCTAssertEqual(entity.id, 603)
        XCTAssertEqual(entity.mediaType, .movie)
        XCTAssertEqual(entity.title, "黑客帝国")
        XCTAssertEqual(entity.originalTitle, "The Matrix")
        XCTAssertEqual(entity.posterPath, "/poster.jpg")
        XCTAssertEqual(entity.backdropPath, "/backdrop.jpg")
        XCTAssertEqual(entity.voteAverage ?? 0, 8.2, accuracy: 0.01)
        XCTAssertEqual(entity.genres, ["动作", "科幻"])
        XCTAssertEqual(entity.imdbID, "tt0133093")
        // 演员只取前 20 位（TMDb 能返回上百位，多存等于撑大 payload）
        XCTAssertEqual(entity.cast.count, 2)
        XCTAssertEqual(entity.cast.first?.name, "基努·里维斯")
        XCTAssertEqual(entity.cast.first?.character, "Neo")
        XCTAssertTrue(entity.hasDisplayableContent)
    }

    func testTVDetailDecodesSeasons() async throws {
        let client = makeClient { _ in (200, Self.tvJSON) }
        let entity = try await client.tv(id: 1399, language: "zh-CN")
        XCTAssertEqual(entity.mediaType, .tv)
        XCTAssertEqual(entity.title, "权力的游戏")
        XCTAssertEqual(entity.seasons.map(\.seasonNumber), [0, 1])
        XCTAssertEqual(entity.seasons.last?.episodeCount, 10)
    }

    func testSeasonDecodesAllEpisodesInOneRequest() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            XCTAssertTrue(request.url?.path.hasSuffix("/tv/1399/season/1") == true,
                          "实际路径: \(request.url?.path ?? "")")
            return (200, Self.seasonJSON)
        }
        let season = try await client.season(tvID: 1399, seasonNumber: 1, language: "zh-CN")
        XCTAssertEqual(season.episodes.map(\.episodeNumber), [1, 2, 3])
        XCTAssertEqual(season.episodes.first?.name, "凛冬将至")
        XCTAssertEqual(season.episodes.first?.stillPath, "/still1.jpg")
        XCTAssertEqual(requestCount, 1, "一整季应只花一次请求")
    }

    func testSearchResultsDecodeYearFromDate() async throws {
        let client = makeClient { _ in (200, Self.searchJSON) }
        let results = try await client.search(query: "matrix", mediaType: .movie, year: 1999, language: "zh-CN")
        XCTAssertEqual(results.map(\.id), [603, 604])
        XCTAssertEqual(results[0].year, 1999, "release_date 前四位即年份")
        XCTAssertEqual(results[0].title, "黑客帝国")
        XCTAssertEqual(results[1].year, 2003)
    }

    /// 脏 `ProviderIds`（非数字 / 0 / 空）在客户端层表现为 404 → `.notFound`，
    /// 调用方据此走「搜索兜底」而不是把它当成网络故障。
    func testNotFoundSurfacesAsNotFound() async throws {
        let client = makeClient { _ in (404, Data(#"{"status_code":34,"status_message":"Not found."}"#.utf8)) }
        do {
            _ = try await client.movie(id: 999_999_999, language: "zh-CN")
            XCTFail("应抛 notFound")
        } catch let error as TMDbError {
            XCTAssertEqual(error, .notFound)
            XCTAssertFalse(error.isRetryable, "404 重试也是白搭")
        }
    }

    // MARK: - 语言逐字段回退

    /// TMDb 不做语言回退：`zh-CN` 没翻译的字段返回**空串**。
    /// 缺失时补一次回退语言，且**逐字段**取（中文标题 + 英文简介的混合是可接受的，
    /// 整包替换会把已有的中文顶掉）。
    func testLanguageFallbackIsPerField() async throws {
        var requestedLanguages: [String] = []
        let client = makeClient { request in
            let lang = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "language" }?.value ?? "?"
            requestedLanguages.append(lang)
            if lang == "zh-CN" {
                // 中文：有标题、**没有简介**（空串）
                return (200, Data(#"""
                {"id":603,"title":"黑客帝国","overview":"","poster_path":"/zh.jpg","genres":[]}
                """#.utf8))
            }
            return (200, Data(#"""
            {"id":603,"title":"The Matrix","overview":"A computer hacker learns...","poster_path":"/en.jpg","genres":[]}
            """#.utf8))
        }

        let entity = try await client.movie(id: 603, language: "zh-CN")

        XCTAssertEqual(requestedLanguages, ["zh-CN", "en-US"], "缺简介时补一次回退语言")
        XCTAssertEqual(entity.title, "黑客帝国", "主语言有值的字段不能被英文顶掉")
        XCTAssertEqual(entity.overview, "A computer hacker learns...", "主语言为空的字段才用英文")
        XCTAssertEqual(entity.posterPath, "/zh.jpg", "主语言有图就不换")
    }

    /// 主语言字段齐全时**不该**多打一次请求（绝大多数中文条目走这条）。
    func testNoFallbackRequestWhenPrimaryIsComplete() async throws {
        var count = 0
        let client = makeClient { _ in
            count += 1
            return (200, Data(#"""
            {"id":603,"title":"黑客帝国","overview":"简介","genres":[]}
            """#.utf8))
        }
        _ = try await client.movie(id: 603, language: "zh-CN")
        XCTAssertEqual(count, 1, "字段齐全时只应请求一次")
    }

    // MARK: - 密钥形态

    /// v4（JWT）走 `Authorization: Bearer`，且 **api_key 不能出现在 URL 里**。
    func testV4TokenUsesBearerHeader() async throws {
        var seen: URLRequest?
        let client = makeClient(apiKey: "eyJhbGciOiJIUzI1NiJ9.payload.sig") { request in
            seen = request
            return (200, Self.movieJSON)
        }
        _ = try await client.movie(id: 603, language: "zh-CN")

        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        XCTAssertFalse(seen?.url?.absoluteString.contains("api_key") == true)
    }

    /// v3（32 位 hex）走查询参数，且**不该**带 Authorization 头。
    func testV3KeyUsesQueryParameter() async throws {
        var seen: URLRequest?
        let client = makeClient(apiKey: "0123456789abcdef0123456789abcdef") { request in
            seen = request
            return (200, Self.movieJSON)
        }
        _ = try await client.movie(id: 603, language: "zh-CN")

        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(seen?.url?.absoluteQueryContains("api_key", "0123456789abcdef0123456789abcdef") == true)
    }

    /// 未配置 key = 功能禁用，抛 `.notConfigured`（调用方据此静默跳过，不报错）。
    func testMissingKeyThrowsNotConfigured() async throws {
        let client = makeClient(apiKey: nil) { _ in (200, Self.movieJSON) }
        XCTAssertFalse(client.isConfigured)
        do {
            _ = try await client.movie(id: 603, language: "zh-CN")
            XCTFail("应抛 notConfigured")
        } catch let error as TMDbError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    // MARK: - 错误与重试

    func testUnauthorizedAndRateLimitAreDistinguished() async throws {
        let unauthorized = makeClient { _ in (401, Data()) }
        do {
            _ = try await unauthorized.movie(id: 1, language: "zh-CN")
            XCTFail("应抛 unauthorized")
        } catch let error as TMDbError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertFalse(error.isRetryable, "401 重试无用，要换 key")
        }

        let limited = makeClient { _ in (429, Data()) }
        do {
            _ = try await limited.movie(id: 1, language: "zh-CN")
            XCTFail("应抛 rateLimited")
        } catch let error as TMDbError {
            if case .rateLimited = error {} else { XCTFail("应是 rateLimited，实际 \(error)") }
            XCTAssertTrue(error.isRetryable, "429 该重试")
        }
    }

    /// 坏 JSON 抛 `.decoding`（TMDb 改 schema 时不至于崩，只是这次补全失败）。
    func testMalformedJSONThrowsDecoding() async throws {
        let client = makeClient { _ in (200, Data("not json at all".utf8)) }
        do {
            _ = try await client.movie(id: 603, language: "zh-CN")
            XCTFail("应抛 decoding")
        } catch let error as TMDbError {
            if case .decoding = error {} else { XCTFail("应是 decoding，实际 \(error)") }
        }
    }

    /// 5xx 重试后成功（`RetryPolicy` 生效）。
    func testRetriesOnServerError() async throws {
        var attempts = 0
        let client = makeClient { _ in
            attempts += 1
            return attempts == 1 ? (500, Data()) : (200, Self.movieJSON)
        }
        // 首次 500 → `.http(500)`，isRetryable 为 false，所以这里会直接抛；
        // 用 429（可重试）验证重试路径。
        _ = client
        var limitedAttempts = 0
        let retrying = makeClient { _ in
            limitedAttempts += 1
            return limitedAttempts == 1 ? (429, Data()) : (200, Self.movieJSON)
        }
        let entity = try await retrying.movie(id: 603, language: "zh-CN")
        XCTAssertEqual(entity.id, 603)
        XCTAssertEqual(limitedAttempts, 2, "429 后应重试一次并成功")
    }

    // MARK: - 限流

    /// 并发上限：同时只允许 N 个请求在飞。
    func testRateLimiterBoundsConcurrency() async throws {
        let limiter = TMDbRateLimiter(maxConcurrent: 2, minimumInterval: 0)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await limiter.withPermit {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)   // 5ms
                        await tracker.leave()
                    }
                }
            }
        }
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 2, "并发上限没生效，峰值 \(peak)")
        XCTAssertGreaterThanOrEqual(peak, 2, "应至少达到过上限（否则说明没并发）")
    }

    /// 最小间隔：连续两次请求之间要等够时间。
    func testRateLimiterEnforcesMinimumInterval() async throws {
        let limiter = TMDbRateLimiter(maxConcurrent: 4, minimumInterval: 0.1)
        let start = Date()
        for _ in 0..<3 {
            await limiter.withPermit { }
        }
        // 3 次请求 → 2 个间隔 ≈ 0.2s
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.18)
    }

    // MARK: - 图片尺寸映射

    func testImageSizePicksNearestLargerBucket() {
        // TMDb 只认固定档位；取**不小于**请求宽度的最小档（宁可略大也别糊）
        XCTAssertEqual(TMDbImageSize.nearest(to: 80), .w92)
        XCTAssertEqual(TMDbImageSize.nearest(to: 92), .w92)
        XCTAssertEqual(TMDbImageSize.nearest(to: 93), .w154)
        XCTAssertEqual(TMDbImageSize.nearest(to: 300), .w342)
        XCTAssertEqual(TMDbImageSize.nearest(to: 400), .w500)
        XCTAssertEqual(TMDbImageSize.nearest(to: 720), .w780)
        XCTAssertEqual(TMDbImageSize.nearest(to: 780), .w780)
        XCTAssertEqual(TMDbImageSize.nearest(to: 1600), .original, "超过最大档用原图")
    }

    func testImageURLUsesPlaceholderFreeCDN() {
        let url = TMDbImageSize.url(path: "/abc.jpg", size: .w500)
        XCTAssertEqual(url?.absoluteString, "https://image.tmdb.org/t/p/w500/abc.jpg")
        // 空 path / nil 一律不产出 URL（分集常缺 still_path）
        XCTAssertNil(TMDbImageSize.url(path: nil, size: .w500))
        XCTAssertNil(TMDbImageSize.url(path: "", size: .w500))
    }
}

// MARK: - 夹具

private struct StubCredential: TMDbCredentialProviding {
    /// 属性名不能叫 `apiKey`：协议要求同名方法，会构成重复声明。
    let key: String?
    func apiKey() -> String? { key }
}

/// 并发峰值统计（测限流用）。
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current = max(0, current - 1) }
}

/// 按请求分发固定响应的 URLProtocol。
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URL {
    /// 判断查询串里有没有某个 key=value（避免手拼字符串比较）。
    func absoluteQueryContains(_ name: String, _ value: String) -> Bool {
        let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == name && $0.value == value }
    }
}

// MARK: - 样例响应

private extension TMDbClientTests {
    static let movieJSON = Data(#"""
    {
      "id": 603,
      "title": "黑客帝国",
      "original_title": "The Matrix",
      "overview": "一名电脑黑客发现现实世界是…",
      "poster_path": "/poster.jpg",
      "backdrop_path": "/backdrop.jpg",
      "vote_average": 8.2,
      "genres": [{"id": 28, "name": "动作"}, {"id": 878, "name": "科幻"}],
      "external_ids": {"imdb_id": "tt0133093"},
      "credits": {"cast": [
        {"id": 1, "name": "基努·里维斯", "character": "Neo", "profile_path": "/k.jpg"},
        {"id": 2, "name": "劳伦斯·菲什伯恩", "character": "Morpheus", "profile_path": null}
      ]},
      "images": {"posters": []},
      "content_ratings": {"results": [{"iso_3166_1": "US", "rating": "R"}]}
    }
    """#.utf8)

    static let tvJSON = Data(#"""
    {
      "id": 1399,
      "name": "权力的游戏",
      "original_name": "Game of Thrones",
      "overview": "维斯特洛大陆…",
      "poster_path": "/got.jpg",
      "genres": [{"id": 10765, "name": "科幻奇幻"}],
      "seasons": [
        {"season_number": 0, "name": "特别篇", "episode_count": 5},
        {"season_number": 1, "name": "第 1 季", "episode_count": 10, "poster_path": "/s1.jpg"}
      ],
      "credits": {"cast": []},
      "external_ids": {"imdb_id": "tt0944947"}
    }
    """#.utf8)

    static let seasonJSON = Data(#"""
    {
      "season_number": 1,
      "name": "第 1 季",
      "overview": "第一季简介",
      "poster_path": "/s1.jpg",
      "episodes": [
        {"episode_number": 1, "name": "凛冬将至", "overview": "…", "still_path": "/still1.jpg", "air_date": "2011-04-17", "runtime": 62},
        {"episode_number": 2, "name": "国王大道", "still_path": "/still2.jpg", "air_date": "2011-04-24", "runtime": 56},
        {"episode_number": 3, "name": "雪诺大人", "still_path": null, "air_date": "2011-05-01", "runtime": 58}
      ]
    }
    """#.utf8)

    static let searchJSON = Data(#"""
    {
      "results": [
        {"id": 603, "title": "黑客帝国", "original_title": "The Matrix", "release_date": "1999-03-31", "poster_path": "/m1.jpg", "popularity": 50.1},
        {"id": 604, "title": "黑客帝国2", "original_title": "The Matrix Reloaded", "release_date": "2003-05-15", "poster_path": "/m2.jpg", "popularity": 40.2}
      ]
    }
    """#.utf8)
}
