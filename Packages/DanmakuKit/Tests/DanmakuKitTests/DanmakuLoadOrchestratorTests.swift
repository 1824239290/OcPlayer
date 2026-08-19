import XCTest
@testable import DanmakuKit

/// 编排层测试：把「匹配 → 缓存 → 装载」全链路跑进一个可注入的假播放器。
/// 竞态防护（revision 代次）在这里有直接断言。
///
/// 并发说明：本类标 @MainActor（编排器与假播放器都主线程隔离）。
/// mock handler 闭包只捕获 Sendable 局部常量、不捕获 self，直接赋值
/// `MockURLProtocol.handler` 而非 `withMock` 的 body 闭包，规避 Swift 6
/// 严格模式对「发送非 Sendable 闭包」的检查。
@MainActor
final class DanmakuLoadOrchestratorTests: XCTestCase {

    private var cache: DanmakuCache!
    private var service: DanmakuService!
    private var orchestrator: DanmakuLoadOrchestrator!
    private var playback: FakePlaybackHost!

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DanmakuOrchestratorTests-\(UUID().uuidString)", isDirectory: true)
        cache = DanmakuCache(directory: directory)
        service = DanmakuService(cache: cache)
        orchestrator = DanmakuLoadOrchestrator(
            service: service,
            session: TestSupport.mockedSession()
        )
        playback = FakePlaybackHost()
    }

    override func tearDown() async throws {
        await cache.purge()
        playback = nil
        orchestrator = nil
        service = nil
        cache = nil
    }

    // MARK: 工具

    private func makeContext(
        cacheKey: String = "jellyfin:abcdef",
        allowsCachedMatchReuse: Bool = true,
        fileSize: Int64 = 64
    ) -> DanmakuMatchContext {
        DanmakuMatchContext(
            uuid: UUID(),
            cacheKey: cacheKey,
            allowsCachedMatchReuse: allowsCachedMatchReuse,
            fileName: "葬送的芙莉莲 01",
            fileSize: fileSize,
            durationSeconds: 1440,
            localFileURL: nil,
            remoteURL: URL(string: "https://media.example.com/video.mp4"),
            remoteHeaders: ["Authorization": "Bearer x"]
        )
    }

    private func makeConfiguration() -> DandanplayConfiguration {
        DandanplayConfiguration(
            baseURL: URL(string: "https://gateway.example.com")!,
            apiKey: "test-key",
            userAgent: "OcPlay/test (macOS; arm64)"
        )
    }

    // MARK: 全链路

    func testFullPipelineHashThenMatchThenLoad() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let matchBody = """
        {"success":true,"errorCode":0,"resultCount":1,"isMatched":true,
         "matches":[{"episodeId":1001,"animeTitle":"葬送的芙莉莲","episodeTitle":"第1话","shift":2}]}
        """
        let commentsBody = """
        {"count":2,"comments":[
          {"cid":1,"p":"0.5,1,16777215,100","m":"你好"},
          {"cid":2,"p":"2.0,5,16711680,100","m":"顶部"}
        ]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(matchBody, url: request.url!)
            case "/v1/comments/1001":
                return TestSupport.response(commentsBody, url: request.url!)
            case "/video.mp4":
                return makeRange206Response(fingerprint, url: request.url!)
            default:
                return TestSupport.response("{}", status: 404, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        XCTAssertEqual(outcome, .loaded(episodeID: 1001, commentCount: 2, title: "葬送的芙莉莲 · 第1话"))
        try assertInjectedJSON(commentCount: 2, firstContent: "你好", firstTime: 0.5)
        XCTAssertEqual(playback.injectedOffset, .seconds(2))
        let cached = await service.cachedMatch(for: context.cacheKey)
        XCTAssertNotNil(cached)
    }

    // MARK: 缓存命中

    func testCachedMatchReuseSkipsHashAndGateway() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 2002, shiftSeconds: 0, animeTitle: "旧番", episodeTitle: "第2话"),
            cacheKey: context.cacheKey,
            revision: 0
        )
        // 预置正文缓存 → 匹配与正文都命中本地，网络在测试中完全不可达。
        let comments = [DanmakuComment(cid: 1, p: "1,1,16777215,1", m: "缓存弹幕")]
        await service.persistComments(comments, for: 2002)
        // 任何网关请求都视为测试失败（缓存的语义就是零请求）。
        MockURLProtocol.handler = { _ in
            throw URLError(.badServerResponse)
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        XCTAssertEqual(outcome, .loaded(episodeID: 2002, commentCount: 1, title: "旧番 · 第2话"))
    }

    func testNoMatchOutcome() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let body = """
        {"success":true,"errorCode":0,"resultCount":0,"isMatched":false,"matches":[]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(body, url: request.url!)
            default:
                return makeRange206Response(fingerprint, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        XCTAssertEqual(outcome, .noMatch)
        XCTAssertNil(playback.injectedJSON)
    }

    func testForceRematchClearsRememberedMatch() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 3003),
            cacheKey: context.cacheKey,
            revision: 0
        )
        let noMatchBody = """
        {"success":true,"errorCode":0,"resultCount":0,"isMatched":false,"matches":[]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(noMatchBody, url: request.url!)
            default:
                return makeRange206Response(fingerprint, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 2,
            forceRematch: true
        )
        XCTAssertEqual(outcome, .noMatch)
        let cached = await service.cachedMatch(for: context.cacheKey)
        XCTAssertNil(cached, "forceRematch 未命中时应清除已记住的映射")
        XCTAssertTrue(playback.didClear, "forceRematch 应先清掉旧弹幕")
    }

    // MARK: 空弹幕 / 指纹不可用

    func testEmptyPayloadBecomesEmptyOutcome() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let matchBody = """
        {"success":true,"errorCode":0,"resultCount":1,"isMatched":true,
         "matches":[{"episodeId":4004}]}
        """
        let emptyBody = """
        {"count":0,"comments":[]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(matchBody, url: request.url!)
            case "/v1/comments/4004":
                return TestSupport.response(emptyBody, url: request.url!)
            default:
                return makeRange206Response(fingerprint, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        XCTAssertEqual(outcome, .empty(episodeID: 4004, title: "弹弹play"))
    }

    func testFingerprintUnavailableFailsWithManualSuggestion() async throws {
        let configuration = makeConfiguration()
        let context = makeContext(
            cacheKey: "standalone:remote-no-range",
            allowsCachedMatchReuse: false,
            fileSize: 17 * 1024 * 1024
        )
        let data = makeFingerprintData()
        // 服务器忽略 Range 返回 200 且文件大于 16 MiB 上限 → 指纹不可用。
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/octet-stream",
                ]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(message, "无法读取媒体指纹，请手动选择弹幕")
    }

    // MARK: 竞态 / 取消

    func testStaleRevisionCannotInjectAfterSwitch() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        // 新任务已 claim 更高的 revision；旧任务（revision 1）即使拿到匹配结果，
        // 写入与注入都必须被 revision 屏障挡掉。
        await service.claimMatchRevision(cacheKey: context.cacheKey, revision: 2)
        let matchBody = """
        {"success":true,"errorCode":0,"resultCount":1,"isMatched":true,
         "matches":[{"episodeId":5005}]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(matchBody, url: request.url!)
            default:
                return makeRange206Response(fingerprint, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        guard case .failed = outcome else {
            return XCTFail("过期代次应失败而非装载，got \(outcome)")
        }
        XCTAssertNil(playback.injectedJSON, "过期代次不应注入弹幕")
    }

    func testCancellationPreventsInjection() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        // 只捕获 Sendable 局部值，避免把 XCTestCase 自身带入 Task。
        let orch = orchestrator!
        let pb = playback!
        let task = Task { await orch.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: pb,
            revision: 1
        ) }
        task.cancel()
        _ = await task.value
        XCTAssertNil(pb.injectedJSON, "取消后不应注入弹幕")
    }

    // MARK: 辅助

    private func assertInjectedJSON(commentCount: Int, firstContent: String, firstTime: Double) throws {
        let data = try XCTUnwrap(playback.injectedJSON?.data(using: .utf8), "应注入弹幕 JSON")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "注入 JSON 应为对象"
        )
        let comments = try XCTUnwrap(object["comments"] as? [[String: Any]], "缺少 comments 数组")
        XCTAssertEqual(comments.count, commentCount)
        let first = comments[0]
        XCTAssertEqual(first["content"] as? String, firstContent)
        XCTAssertEqual(first["time"] as? Double, firstTime)
    }
}

/// 假播放器：记录注入内容与调用序列，并把每个动作当作「当前代次有效」。
@MainActor
private final class FakePlaybackHost: DanmakuPlaybackHosting {
    var injectedJSON: String?
    var injectedOffset: Duration?
    var didClear = false

    func replaceDanmaku(uuid: UUID, json: String, name: String, offset: Duration) throws -> Bool {
        injectedJSON = json
        injectedOffset = offset
        return true
    }

    func clearDanmaku(uuid: UUID) throws -> Bool {
        didClear = true
        return true
    }
}

// MARK: - 文件级辅助（非隔离，供 @Sendable mock 闭包调用）

private func makeFingerprintData() -> Data {
    // 必须与 makeContext 的 fileSize（64）一致，206 截断校验按该值比对。
    Data(repeating: 0xAB, count: 64)
}

private func makeRange206Response(_ data: Data, url: URL) -> (HTTPURLResponse, Data) {
    let headers = [
        "Content-Type": "application/octet-stream",
        "Content-Range": "bytes 0-\(data.count - 1)/\(data.count)",
    ]
    let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: headers)!
    return (response, data)
}
