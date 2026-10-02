import CryptoKit
import XCTest
@testable import DanmakuKit

/// AniList GraphQL 请求体（`{"query":…,"variables":{"search"/"id":…}}`）的宽松解析。
struct GraphQLRequestBody: Decodable {
    let variables: [String: String]?

    /// 取出搜索词（Media(id:) 直查路径没有 search 变量）。
    static func searchVariable(of request: URLRequest) -> String? {
        guard let data = TestSupport.body(of: request) else { return nil }
        return try? JSONDecoder().decode(GraphQLRequestBody.self, from: data).variables?["search"]
    }
}

/// handler 闭包里收集搜索词用的装箱（Swift 6 严格并发下不裸捕可变局部变量）。
final class SearchRecorder: @unchecked Sendable {
    var list: [String] = []
}

/// v1 缓存键复算用（生产代码已升 v2，不再提供旧格式）。
func sha256Hex(_ raw: String) -> String {
    SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
}

final class AniSkipClientTests: XCTestCase {

    private func makeClient() -> AniSkipClient {
        AniSkipClient(
            userAgent: "OcPlayer-Test/0.1",
            session: TestSupport.mockedSession()
        )
    }

    func testSkipTimesParsesIntervals() async throws {
        let client = makeClient()
        let json = """
        {"found":true,"results":[
          {"interval":{"startTime":638.489,"endTime":728.489},"skipType":"op","skipId":"a"},
          {"interval":{"startTime":1331.7,"endTime":1421.7},"skipType":"ed","skipId":"b"},
          {"interval":{"startTime":0,"endTime":30},"skipType":"recap","skipId":"c"},
          {"interval":{"startTime":1,"endTime":2},"skipType":"brand-new-type","skipId":"d"}
        ],"message":"ok","statusCode":200}
        """
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.url?.path, "/v2/skip-times/9253/1")
            // types 是重复键，不能用去重的字典辅助读。
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let types = items.filter { $0.name == "types" }.compactMap(\.value)
            XCTAssertEqual(types, ["op", "ed", "mixed-op", "mixed-ed"])
            XCTAssertEqual(items.first { $0.name == "episodeLength" }?.value, "0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OcPlayer-Test/0.1")
            return TestSupport.response(json, url: request.url!)
        }) {
            let intervals = try await client.skipTimes(malID: 9253, episodeNumber: 1, episodeLengthSeconds: nil)
            XCTAssertEqual(intervals?.count, 3, "未知 skipType 容错跳过")
            XCTAssertEqual(intervals?.first?.type, .opening)
            XCTAssertEqual(intervals?.first?.startSeconds, 638.489)
            XCTAssertEqual(intervals?.first?.endSeconds, 728.489)
        }
    }

    func testKnownEpisodeLengthIsPassedThrough() async throws {
        let client = makeClient()
        try await TestSupport.withMock({ request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "episodeLength" }?.value, "1424", "已知时长透传，白赚服务端过滤校验")
            return TestSupport.response(#"{"found":false,"results":[],"statusCode":404}"#, url: request.url!)
        }) {
            let intervals = try await client.skipTimes(
                malID: 9253, episodeNumber: 1, episodeLengthSeconds: 1424)
            XCTAssertNil(intervals)
        }
    }

    func testNoDataReturnsNilInsteadOfThrowing() async throws {
        let client = makeClient()
        try await TestSupport.withMock({ request in
            return TestSupport.response(
                #"{"statusCode":404,"message":"No skip times found"}"#,
                status: 404, url: request.url!)
        }) {
            let intervals = try await client.skipTimes(malID: 9253, episodeNumber: 99, episodeLengthSeconds: nil)
            XCTAssertNil(intervals)
        }
    }

    func testInvalidParametersThrowWithoutNetwork() async {
        let client = makeClient()
        do {
            _ = try await client.skipTimes(malID: 0, episodeNumber: 1, episodeLengthSeconds: nil)
            XCTFail("应当抛错")
        } catch let error as AniSkipError {
            guard case .invalidRequest = error else { return XCTFail("错误类型不符: \(error)") }
        } catch {
            XCTFail("错误类型不符: \(error)")
        }
    }

    // MARK: 区间 → 提示

    func testIntervalsConvertToHint() {
        let hint = DanmakuIntroHint(aniskipIntervals: [
            AniSkipInterval(type: .recap, startSeconds: 0, endSeconds: 30),
            AniSkipInterval(type: .opening, startSeconds: 88.4, endSeconds: 178.9),
            AniSkipInterval(type: .ending, startSeconds: 1331, endSeconds: 1421),
        ])
        XCTAssertEqual(hint?.endSeconds, 178.9)
        XCTAssertEqual(hint?.startSeconds, 88.4)
        XCTAssertEqual(hint?.source, .aniskip)

        // 只有 ED / recap 构不成片头提示。
        XCTAssertNil(DanmakuIntroHint(aniskipIntervals: [
            AniSkipInterval(type: .ending, startSeconds: 1331, endSeconds: 1421),
        ]))
        // 异常区间按坏数据处理（错季匹配防护）。
        XCTAssertNil(DanmakuIntroHint(aniskipIntervals: [
            AniSkipInterval(type: .opening, startSeconds: 0, endSeconds: 5000),
        ]))
        XCTAssertNil(DanmakuIntroHint(aniskipIntervals: [
            AniSkipInterval(type: .opening, startSeconds: 180, endSeconds: 180.5),
        ]))
        // 冷开场集：OP 区间本身很短，但结束点绝对值可以很大（如命运石之门 638-728s）。
        let coldOpen = DanmakuIntroHint(aniskipIntervals: [
            AniSkipInterval(type: .opening, startSeconds: 638.489, endSeconds: 728.489),
        ])
        XCTAssertEqual(coldOpen?.startSeconds, 638.489)
        XCTAssertEqual(coldOpen?.endSeconds, 728.489)
    }
}

final class AniSkipIDResolverTests: XCTestCase {

    /// 可变时钟（类装箱，转义闭包捕获安全）。
    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeResolver(
        directory: URL,
        session: URLSession = TestSupport.mockedSession(),
        clock: ClockBox = ClockBox(Date(timeIntervalSince1970: 1_000_000))
    ) -> AniSkipIDResolver {
        AniSkipIDResolver(
            store: AniSkipIDStore(directory: directory),
            session: session,
            now: { [clock] in clock.now }
        )
    }

    func testDirectMalIDBypassesNetwork() async {
        let resolver = makeResolver(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        )
        let identity = AniSkipAnimeIdentity(malID: 9253, title: "命运石之门")
        let ids = await resolver.resolve(for: identity)
        XCTAssertEqual(ids.malID, 9253)
    }

    func testSearchResolvesFirstResultWithMalID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = makeResolver(directory: directory)

        let identity = AniSkipAnimeIdentity(title: "僕は友達が少ない", seasonNumber: 1)
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.url?.host, "graphql.anilist.co")
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":null},{"id":2,"idMal":10719},{"id":3,"idMal":99}]}}}"#,
                url: request.url!)
        }) {
            // 取首个带 idMal 的条目。
            let ids = await resolver.resolve(for: identity)
            XCTAssertEqual(ids.malID, 10719)
        }
        // 同身份再次解析走缓存，不再打网络。
        try await TestSupport.withMock({ _ in
            XCTFail("缓存命中不应发起网络请求")
            throw URLError(.unsupportedURL)
        }) {
            let cached = await resolver.resolve(for: identity)
            XCTAssertEqual(cached.malID, 10719)
        }
    }

    func testNegativeCacheExpiresAfterSevenDays() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let resolver = makeResolver(directory: directory, clock: clock)
        let identity = AniSkipAnimeIdentity(title: "冷门番")
        let counter = TestSupport.RequestCounter()

        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(#"{"data":{"Page":{"media":[]}}}"#, url: request.url!)
        }) {
            let first = await resolver.resolve(for: identity)
            XCTAssertTrue(first.isEmpty)
            let second = await resolver.resolve(for: identity)
            XCTAssertTrue(second.isEmpty, "负缓存 7 天内不重试")
        }
        XCTAssertEqual(counter.count, 1)

        // 8 天后负缓存过期，允许重试。
        clock.now = Date(timeIntervalSince1970: 1_000_000 + 8 * 24 * 3600)
        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":42}]}}}"#, url: request.url!)
        }) {
            let retried = await resolver.resolve(for: identity)
            XCTAssertEqual(retried.malID, 42)
        }
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: 多候选搜索（v2）

    /// 主标题（弹弹play 简体中文）搜空后，备选标题（原生标题）命中——2026 夏番
    /// 实测场景：中文标题在 AniList 零召回，整条 AniSkip 路径曾卡死在这里。
    func testAlternativeTitleUsedWhenPrimaryMisses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = makeResolver(directory: directory)

        let identity = AniSkipAnimeIdentity(
            title: "二十世纪电气目录",
            alternativeTitles: ["二十世紀電氣目録 -ユーレカ・エヴリカ-"],
            seasonNumber: 1)
        let searches = SearchRecorder()
        try await TestSupport.withMock({ request in
            if let search = GraphQLRequestBody.searchVariable(of: request) {
                searches.list.append(search)
            }
            if searches.list.count == 1 {
                return TestSupport.response(#"{"data":{"Page":{"media":[]}}}"#, url: request.url!)
            }
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":103303,"idMal":62856,"title":{"native":"二十世紀電氣目録 -ユーレカ・エヴリカ-"}}]}}}"#,
                url: request.url!)
        }) {
            let ids = await resolver.resolve(for: identity)
            XCTAssertEqual(ids.malID, 62856)
        }
        XCTAssertEqual(searches.list, ["二十世纪电气目录", "二十世紀電氣目録 -ユーレカ・エヴリカ-"])
    }

    /// 客户端匹配：第一个带 idMal 的条目是无关作品时，精确命中标题的条目优先。
    func testExactTitleMatchBeatsFirstResultWithMalID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = makeResolver(directory: directory)

        let identity = AniSkipAnimeIdentity(title: "きみが死ぬまで恋をしたい")
        try await TestSupport.withMock({ request in
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":111,"title":{"native":"別の作品"}},{"id":2,"idMal":null,"title":{"native":"きみが死ぬまで恋をしたい"}},{"id":3,"idMal":61126,"title":{"native":"きみが死ぬまで恋をしたい"}}]}}}"#,
                url: request.url!)
        }) {
            // idMal 为空的条目不参与匹配；精确命中排在 111 之后也选它。
            let ids = await resolver.resolve(for: identity)
            XCTAssertEqual(ids.malID, 61126)
        }
    }

    /// 简体中文标题常不在 AniList 的标题字段里，但在 synonyms 里——同样算精确命中。
    func testSynonymCountsAsExactMatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = makeResolver(directory: directory)

        let identity = AniSkipAnimeIdentity(title: "我的朋友很少")
        try await TestSupport.withMock({ request in
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":null,"title":{"native":"僕は友達が少ない"}},{"id":2,"idMal":10719,"title":{"native":"僕は友達が少ない"},"synonyms":["我的朋友很少"]}]}}}"#,
                url: request.url!)
        }) {
            let ids = await resolver.resolve(for: identity)
            XCTAssertEqual(ids.malID, 10719)
        }
    }

    /// 原生标题带副标题装饰（「…目録 -ユーレカ・エヴリカ-」）时，包含匹配兜住。
    func testContainmentMatchesDecoratedNativeTitle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = makeResolver(directory: directory)

        let identity = AniSkipAnimeIdentity(title: "二十世紀電氣目録")
        try await TestSupport.withMock({ _ in
            TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":62856,"title":{"native":"二十世紀電氣目録 -ユーレカ・エヴリカ-"}}]}}}"#,
                url: URL(string: "https://graphql.anilist.co")!)
        }) {
            let ids = await resolver.resolve(for: identity)
            XCTAssertEqual(ids.malID, 62856)
        }
    }

    /// 全部候选落空才写负缓存；负缓存期内不重试（含备选标题）。
    func testNegativeCacheOnlyAfterAllCandidatesFail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let resolver = makeResolver(directory: directory, clock: clock)
        let identity = AniSkipAnimeIdentity(
            title: "与你相恋到生命尽头",
            alternativeTitles: ["きみが死ぬまで恋をしたい"])
        let counter = TestSupport.RequestCounter()

        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(#"{"data":{"Page":{"media":[]}}}"#, url: request.url!)
        }) {
            let first = await resolver.resolve(for: identity)
            XCTAssertTrue(first.isEmpty)
            let second = await resolver.resolve(for: identity)
            XCTAssertTrue(second.isEmpty, "负缓存 7 天内不重试")
        }
        XCTAssertEqual(counter.count, 2, "两个候选各查一次")
    }

    /// 「重新匹配」语义：forceRefresh 绕过负缓存全新解析，命中后写回正缓存。
    func testForceRefreshBypassesNegativeCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolver = makeResolver(directory: directory)
        let identity = AniSkipAnimeIdentity(title: "冷门番")
        let counter = TestSupport.RequestCounter()

        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(#"{"data":{"Page":{"media":[]}}}"#, url: request.url!)
        }) {
            let first = await resolver.resolve(for: identity)
            XCTAssertTrue(first.isEmpty)
            let forced = await resolver.resolve(for: identity, forceRefresh: true)
            XCTAssertTrue(forced.isEmpty, "仍然搜不中")
        }
        XCTAssertEqual(counter.count, 2, "forceRefresh 忽略负缓存再次发起搜索")

        // AniList 后来收录了：forceRefresh 重解析能拿到并写回正缓存。
        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":42}]}}}"#, url: request.url!)
        }) {
            let retried = await resolver.resolve(for: identity, forceRefresh: true)
            XCTAssertEqual(retried.malID, 42)
        }
        try await TestSupport.withMock({ _ in
            XCTFail("正缓存命中不应发起网络请求")
            throw URLError(.unsupportedURL)
        }) {
            let cached = await resolver.resolve(for: identity)
            XCTAssertEqual(cached.malID, 42)
        }
    }

    /// forceRefresh 同样绕过正缓存（旧正缓存可能就是错季错番的结果）。
    func testForceRefreshBypassesPositiveCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolver = makeResolver(directory: directory)
        let identity = AniSkipAnimeIdentity(title: "某番")
        let counter = TestSupport.RequestCounter()

        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":7}]}}}"#, url: request.url!)
        }) {
            let first = await resolver.resolve(for: identity)
            XCTAssertEqual(first.malID, 7)
            let forced = await resolver.resolve(for: identity, forceRefresh: true)
            XCTAssertEqual(forced.malID, 7)
        }
        XCTAssertEqual(counter.count, 2, "forceRefresh 对正缓存也重新解析")
    }

    /// v2 键升版：v1 时代写下的负缓存（键格式相同、raw 无 v2 前缀）不再拦截。
    func testLegacyNegativeCacheRecordIsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let store = AniSkipIDStore(directory: directory)
        // 按 v1 键格式（raw 无 v2 前缀）预置一条负缓存。
        let legacyKey = sha256Hex("-|二十世纪电气目录|1|-")
        await store.setRecord(AniSkipIDRecord(malID: nil, resolvedAt: clock.now), for: legacyKey)
        let resolver = AniSkipIDResolver(
            store: store, session: TestSupport.mockedSession(),
            now: { [clock] in clock.now })

        let identity = AniSkipAnimeIdentity(title: "二十世纪电气目录", seasonNumber: 1)
        let counter = TestSupport.RequestCounter()
        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":62856}]}}}"#, url: request.url!)
        }) {
            let ids = await resolver.resolve(for: identity)
            XCTAssertEqual(ids.malID, 62856, "v1 负缓存不该拦截 v2 解析")
        }
        XCTAssertEqual(counter.count, 1)
    }

    /// searchTitles：归一形态去重滤空，主标题在前。
    func testSearchTitlesDedupeAndOrder() {
        let identity = AniSkipAnimeIdentity(
            title: "Re：从零开始的异世界生活 第四季",
            alternativeTitles: ["Re:从零开始的异世界生活 第四季", "  ", "Re:ゼロから始める異世界生活 4th season"])
        XCTAssertEqual(
            identity.searchTitles,
            ["Re：从零开始的异世界生活 第四季", "Re:ゼロから始める異世界生活 4th season"])
    }
}

/// `aniskip-ids.json` 的读缓存语义（review-20260914 P3-9）。
final class AniSkipIDStoreTests: XCTestCase {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-store-\(UUID().uuidString)", isDirectory: true)
    }

    func testCorruptedFileReadsAsEmptyAndStaysWritable() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("aniskip-ids.json")
        try Data("这不是 JSON".utf8).write(to: file)

        let store = AniSkipIDStore(directory: directory)
        let key = "s1|e1"
        let missing = await store.record(for: key)
        XCTAssertNil(missing, "损坏文件按空处理")

        // 损坏帧之后仍可写穿：整体覆盖成合法内容，新实例读得回来。
        let record = AniSkipIDRecord(malID: 9253, resolvedAt: Date(timeIntervalSince1970: 1_000_000))
        await store.setRecord(record, for: key)

        let reopened = AniSkipIDStore(directory: directory)
        let readBack = await reopened.record(for: key)
        XCTAssertEqual(readBack, record)
    }

    func testMissingFileReadsAsEmptyAndStaysWritable() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AniSkipIDStore(directory: directory)
        let key = "s2|e3"
        let missing = await store.record(for: key)
        XCTAssertNil(missing)

        let record = AniSkipIDRecord(malID: nil, resolvedAt: Date(timeIntervalSince1970: 2_000_000))
        await store.setRecord(record, for: key)
        let readBack = await store.record(for: key)
        XCTAssertEqual(readBack, record)
    }

    func testWritesSurviveAcrossInstances() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "s3|e9"

        let store = AniSkipIDStore(directory: directory)
        let first = AniSkipIDRecord(malID: 1, resolvedAt: Date(timeIntervalSince1970: 3_000_000))
        await store.setRecord(first, for: key)

        let second = AniSkipIDRecord(malID: 2, resolvedAt: Date(timeIntervalSince1970: 3_000_100))
        await store.setRecord(second, for: "s3|e10")

        let reopened = AniSkipIDStore(directory: directory)
        let readFirst = await reopened.record(for: key)
        let readSecond = await reopened.record(for: "s3|e10")
        XCTAssertEqual(readFirst, first, "后写入不能丢掉先前的键")
        XCTAssertEqual(readSecond, second)
    }
}
