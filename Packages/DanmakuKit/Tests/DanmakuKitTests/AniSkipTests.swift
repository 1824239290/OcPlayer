import XCTest
@testable import DanmakuKit

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
        let malID = await resolver.malID(for: identity)
        XCTAssertEqual(malID, 9253)
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
            let malID = await resolver.malID(for: identity)
            XCTAssertEqual(malID, 10719)
        }
        // 同身份再次解析走缓存，不再打网络。
        try await TestSupport.withMock({ _ in
            XCTFail("缓存命中不应发起网络请求")
            throw URLError(.unsupportedURL)
        }) {
            let cached = await resolver.malID(for: identity)
            XCTAssertEqual(cached, 10719)
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
            let first = await resolver.malID(for: identity)
            XCTAssertNil(first)
            let second = await resolver.malID(for: identity)
            XCTAssertNil(second, "负缓存 7 天内不重试")
        }
        XCTAssertEqual(counter.count, 1)

        // 8 天后负缓存过期，允许重试。
        clock.now = Date(timeIntervalSince1970: 1_000_000 + 8 * 24 * 3600)
        try await TestSupport.withMock({ request in
            counter.count += 1
            return TestSupport.response(
                #"{"data":{"Page":{"media":[{"id":1,"idMal":42}]}}}"#, url: request.url!)
        }) {
            let retried = await resolver.malID(for: identity)
            XCTAssertEqual(retried, 42)
        }
        XCTAssertEqual(counter.count, 2)
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
