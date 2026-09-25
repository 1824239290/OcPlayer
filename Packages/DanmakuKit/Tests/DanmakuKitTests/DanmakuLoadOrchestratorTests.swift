import DiagnosticsKit
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
            session: TestSupport.mockedSession(),
            // 零等待重试策略：编排层透传给网关客户端，重试用例不空等退避。
            retryPolicy: RetryPolicy(attempts: 3, base: 0, jitter: 0.0...0.0)
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
        XCTAssertEqual(outcome, .loaded(episodeID: 1001, commentCount: 2, title: "葬送的芙莉莲 · 第1话", introHint: nil))
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
        XCTAssertEqual(outcome, .loaded(episodeID: 2002, commentCount: 1, title: "旧番 · 第2话", introHint: nil))
    }

    func testOverlayRouteDoesNotBuildKernelJSON() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 2012, shiftSeconds: 0, animeTitle: "旧番", episodeTitle: "第 1 话"),
            cacheKey: context.cacheKey,
            revision: 0
        )
        await service.persistComments(
            [DanmakuComment(cid: 1, p: "1,1,16777215,1", m: "overlay")],
            for: 2012
        )
        playback.danmakuPayloadFormat = .overlay
        MockURLProtocol.handler = { _ in
            XCTFail("缓存命中不应请求网络")
            throw URLError(.badServerResponse)
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )

        XCTAssertEqual(outcome, .loaded(episodeID: 2012, commentCount: 1, title: "旧番 · 第 1 话", introHint: nil))
        XCTAssertEqual(playback.injectedEntries?.count, 1)
        XCTAssertNil(playback.injectedJSON)
    }

    func testKernelTrackRouteInjectsJSONWithoutOverlayEntries() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 2022, shiftSeconds: 0, animeTitle: "旧番", episodeTitle: "第 1 话"),
            cacheKey: context.cacheKey,
            revision: 0
        )
        await service.persistComments(
            [DanmakuComment(cid: 1, p: "1,1,16777215,1", m: "kernel")],
            for: 2022
        )
        playback.danmakuPayloadFormat = .kernelTrack
        MockURLProtocol.handler = { _ in
            XCTFail("缓存命中不应请求网络")
            throw URLError(.badServerResponse)
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )

        XCTAssertEqual(outcome, .loaded(episodeID: 2022, commentCount: 1, title: "旧番 · 第 1 话", introHint: nil))
        XCTAssertEqual(playback.injectedEntries, [])
        XCTAssertNotNil(playback.injectedJSON)
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
            case "/v1/search/episodes":
                // 干净的空搜索结果（旧 mock 这里返回二进制、靠旧版吞错兜底；
                // 分流后错误会走 failed，这里必须模拟网关真的返回空）。
                return TestSupport.response("{\"success\":true,\"errorCode\":0,\"animes\":[]}", url: request.url!)
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

    /// 网关全线失败（match + search 都 500）：必须报「失败可重试」，
    /// 不得谎报「未匹配到剧集」；请求层重试耗尽后短路剩余降级层。
    func testGatewayErrorsYieldFailedInsteadOfNoMatch() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let matchRequests = TestSupport.RequestCounter()
        let searchRequests = TestSupport.RequestCounter()
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/video.mp4":
                return makeRange206Response(fingerprint, url: request.url!)
            case "/v1/match":
                matchRequests.count += 1
                return TestSupport.response("{\"error\":\"boom\"}", status: 500, url: request.url!)
            default:
                searchRequests.count += 1
                return TestSupport.response("{\"error\":\"boom\"}", status: 500, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("网关错误应报失败，got \(outcome)")
        }
        XCTAssertEqual(message, "弹幕服务暂时不可用", "httpStatus(500) 应复用既有用户文案")
        XCTAssertNil(playback.injectedJSON, "失败路径不应注入弹幕")
        XCTAssertEqual(matchRequests.count, 3, "500 在可重试集：请求层耗尽全部尝试")
        XCTAssertEqual(searchRequests.count, 0, "网关故障应短路剩余降级层")
    }

    /// 可重试的网关故障（503）：请求层把 match 重试耗尽后短路剩余降级层，
    /// 不再连打必败的 search 请求。
    func testRetryableGatewayErrorRetriesThenShortCircuits() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let matchRequests = TestSupport.RequestCounter()
        let searchRequests = TestSupport.RequestCounter()
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/video.mp4":
                return makeRange206Response(fingerprint, url: request.url!)
            case "/v1/match":
                matchRequests.count += 1
                return TestSupport.response("{\"error\":\"boom\"}", status: 503, url: request.url!)
            default:
                searchRequests.count += 1
                return TestSupport.response("{\"error\":\"boom\"}", status: 503, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("网关错误应报失败，got \(outcome)")
        }
        XCTAssertEqual(message, "弹幕服务暂时不可用", "httpStatus(503) 应复用既有用户文案")
        XCTAssertNil(playback.injectedJSON, "失败路径不应注入弹幕")
        XCTAssertEqual(matchRequests.count, 3, "503 可重试：请求层耗尽全部尝试")
        XCTAssertEqual(searchRequests.count, 0, "重试耗尽后短路剩余降级层")
    }

    /// 混合结局：tier 1 干净返回无匹配、tier 3 搜索网络断 → 仍应报失败。
    func testMixedCleanAndErrorTiersYieldFailed() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let noMatchBody = """
        {"success":true,"errorCode":0,"resultCount":0,"isMatched":false,"matches":[]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(noMatchBody, url: request.url!)
            case "/video.mp4":
                return makeRange206Response(fingerprint, url: request.url!)
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("混合结局应报失败，got \(outcome)")
        }
        XCTAssertEqual(message, "弹幕网络请求失败", "URLError 应映射为网络失败文案")
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
            case "/v1/search/episodes":
                return TestSupport.response("{\"success\":true,\"errorCode\":0,\"animes\":[]}", url: request.url!)
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
        XCTAssertEqual(outcome, .empty(episodeID: 4004, title: "弹弹play", introHint: nil))
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

    func testInjectionUsesPlaybackUUIDNotCacheKey() async throws {
        // 回归：uuid 必须原样透传给播放器（真实 PlaybackRequest.id），
        // 不能从 cacheKey 派生——那会造成注入永远不匹配当前源。
        let configuration = makeConfiguration()
        let context = makeContext()
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 6006, shiftSeconds: 0, animeTitle: "透传", episodeTitle: "第6话"),
            cacheKey: context.cacheKey,
            revision: 0
        )
        let comments = [DanmakuComment(cid: 1, p: "1,1,16777215,1", m: "x")]
        await service.persistComments(comments, for: 6006)
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
        XCTAssertEqual(outcome, .loaded(episodeID: 6006, commentCount: 1, title: "透传 · 第6话", introHint: nil))
        XCTAssertEqual(playback.waitedUUIDs.last, context.uuid, "就绪等待与注入必须使用请求的 uuid")
    }

    func testWaitUntilReadyTimeoutFailsWithoutInjection() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 7007),
            cacheKey: context.cacheKey,
            revision: 0
        )
        let comments = [DanmakuComment(cid: 1, p: "1,1,16777215,1", m: "x")]
        await service.persistComments(comments, for: 7007)
        MockURLProtocol.handler = { _ in
            throw URLError(.badServerResponse)
        }
        defer { MockURLProtocol.handler = nil }
        // 假播放器就绪等待永远被取消（等价于 30s 超时），编排器应失败且不注入。
        playback.readyNeverResolves = true

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        guard case .failed(let message) = outcome else {
            return XCTFail("就绪超时应失败，got \(outcome)")
        }
        XCTAssertEqual(message, "视频未就绪，弹幕未装载")
        XCTAssertNil(playback.injectedJSON, "就绪超时不应注入")
    }

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

    // MARK: - 智能多级降级检索测试

    func testMatchFallbackToTitleSearchWhenHashFails() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let noMatchBody = """
        {"success":true,"errorCode":0,"resultCount":0,"isMatched":false,"matches":[]}
        """
        let searchBody = """
        {"success":true,"errorCode":0,"animes":[{"animeId":10,"animeTitle":"葬送的芙莉莲","type":"tvseries","episodes":[{"episodeId":5001,"episodeTitle":"第1话"}]}]}
        """
        let commentsBody = """
        {"count":1,"comments":[{"cid":1,"p":"1,1,16777215,1","m":"降级搜索弹幕"}]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(noMatchBody, url: request.url!)
            case "/v1/search/episodes":
                return TestSupport.response(searchBody, url: request.url!)
            case "/v1/comments/5001":
                return TestSupport.response(commentsBody, url: request.url!)
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
        XCTAssertEqual(outcome, .loaded(episodeID: 5001, commentCount: 1, title: "葬送的芙莉莲 · 第1话", introHint: nil))
    }

    func testMatchFallbackToTMDBIdSearch() async throws {
        let configuration = makeConfiguration()
        let context = DanmakuMatchContext(
            uuid: UUID(),
            cacheKey: "jellyfin:tmdb-test",
            allowsCachedMatchReuse: true,
            fileName: "02.mkv",
            fileSize: 64,
            durationSeconds: 1440,
            localFileURL: nil,
            remoteURL: URL(string: "https://media.example.com/video.mp4"),
            remoteHeaders: [:],
            animeTitle: "葬送的芙莉莲",
            episodeNumber: 2,
            seasonNumber: 1,
            tmdbID: 209867
        )
        let fingerprint = makeFingerprintData()
        let noMatchBody = """
        {"success":true,"errorCode":0,"resultCount":0,"isMatched":false,"matches":[]}
        """
        let tmdbSearchBody = """
        {"success":true,"errorCode":0,"animes":[{"animeId":10,"animeTitle":"葬送的芙莉莲","type":"tvseries","episodes":[{"episodeId":5002,"episodeTitle":"第2话"}]}]}
        """
        let commentsBody = """
        {"count":1,"comments":[{"cid":1,"p":"1,1,16777215,1","m":"TMDB命中弹幕"}]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(noMatchBody, url: request.url!)
            case "/v1/search/episodes":
                let items = TestSupport.queryItems(of: request)
                if items["tmdbId"] == "209867" {
                    return TestSupport.response(tmdbSearchBody, url: request.url!)
                }
                return TestSupport.response("{\"success\":true,\"animes\":[]}", url: request.url!)
            case "/v1/comments/5002":
                return TestSupport.response(commentsBody, url: request.url!)
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
        XCTAssertEqual(outcome, .loaded(episodeID: 5002, commentCount: 1, title: "葬送的芙莉莲 · 第2话", introHint: nil))
    }

    func testCandidateAcceptedWhenIsMatchedIsFalse() async throws {
        let configuration = makeConfiguration()
        let context = makeContext()
        let fingerprint = makeFingerprintData()
        let fuzzyMatchBody = """
        {"success":true,"errorCode":0,"resultCount":1,"isMatched":false,
         "matches":[{"episodeId":5003,"animeTitle":"葬送的芙莉莲","episodeTitle":"第1话","shift":0}]}
        """
        let commentsBody = """
        {"count":1,"comments":[{"cid":1,"p":"1,1,16777215,1","m":"模糊命中弹幕"}]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(fuzzyMatchBody, url: request.url!)
            case "/v1/comments/5003":
                return TestSupport.response(commentsBody, url: request.url!)
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
        XCTAssertEqual(outcome, .loaded(episodeID: 5003, commentCount: 1, title: "葬送的芙莉莲 · 第1话", introHint: nil))
    }

    func testFingerprintUnavailableFallbackToSearchSuccess() async throws {
        let configuration = makeConfiguration()
        let context = makeContext(
            cacheKey: "standalone:remote-no-range-fallback",
            allowsCachedMatchReuse: false,
            fileSize: 17 * 1024 * 1024
        )
        let data = makeFingerprintData()
        let searchBody = """
        {"success":true,"errorCode":0,"animes":[{"animeId":10,"animeTitle":"葬送的芙莉莲","type":"tvseries","episodes":[{"episodeId":5004,"episodeTitle":"第1话"}]}]}
        """
        let commentsBody = """
        {"count":1,"comments":[{"cid":1,"p":"1,1,16777215,1","m":"无指纹搜索命中"}]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/search/episodes":
                return TestSupport.response(searchBody, url: request.url!)
            case "/v1/comments/5004":
                return TestSupport.response(commentsBody, url: request.url!)
            default:
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/octet-stream",
                    ]
                )!
                return (response, data)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        XCTAssertEqual(outcome, .loaded(episodeID: 5004, commentCount: 1, title: "葬送的芙莉莲 · 第1话", introHint: nil))
    }

    // MARK: 跳过片头（AniSkip > 弹幕检测）

    func testAniSkipHintWinsOverDanmakuDetectionAndPersists() async throws {
        let configuration = makeConfiguration()
        let fingerprint = makeFingerprintData()
        // 弹幕里有报点（推导出 132s），AniSkip 也有精确区间（728.489s）——后者胜出。
        let matchBody = """
        {"success":true,"errorCode":0,"resultCount":1,"isMatched":true,
         "matches":[{"episodeId":2001,"animeTitle":"命运石之门","episodeTitle":"第1话"}]}
        """
        let commentsBody = """
        {"count":3,"comments":[
          {"cid":1,"p":"40.5,1,16777215,100","m":"跳伞02:12"},
          {"cid":2,"p":"44.2,1,16777215,100","m":"跳伞02:13"},
          {"cid":3,"p":"131.5,1,16777215,100","m":"空降成功"}
        ]}
        """
        let aniskipBody = """
        {"found":true,"results":[
          {"interval":{"startTime":638.489,"endTime":728.489},"skipType":"op","skipId":"x"},
          {"interval":{"startTime":1331.7,"endTime":1421.7},"skipType":"ed","skipId":"y"}
        ],"statusCode":200}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.host {
            case "gateway.example.com":
                switch request.url!.path {
                case "/v1/match": return TestSupport.response(matchBody, url: request.url!)
                case "/v1/comments/2001": return TestSupport.response(commentsBody, url: request.url!)
                default: return TestSupport.response("{}", status: 404, url: request.url!)
                }
            case "media.example.com":
                return makeRange206Response(fingerprint, url: request.url!)
            case "api.aniskip.com":
                return TestSupport.response(aniskipBody, url: request.url!)
            default:
                return TestSupport.response("{}", status: 404, url: request.url!)
            }
        }
        defer { MockURLProtocol.handler = nil }

        let context = DanmakuMatchContext(
            uuid: UUID(),
            cacheKey: "jellyfin:abcdef",
            allowsCachedMatchReuse: true,
            fileName: "命运石之门 01",
            fileSize: 64,
            durationSeconds: 1424,
            remoteURL: URL(string: "https://media.example.com/video.mp4"),
            animeTitle: "命运石之门",
            episodeNumber: 1,
            malID: 9253
        )
        let outcome = await orchestrator.runAutomatic(
            matchContext: context,
            configuration: configuration,
            playback: playback,
            revision: 1
        )
        XCTAssertEqual(outcome, .loaded(
            episodeID: 2001, commentCount: 3, title: "命运石之门 · 第1话",
            introHint: DanmakuIntroHint(startSeconds: 638.489, endSeconds: 728.489, evidenceCount: 1, source: .aniskip)))
        let persisted = await service.cachedIntroHint(for: 2001)
        XCTAssertEqual(persisted?.source, .aniskip)
    }

    func testCachedIntroHintWinsWithoutAniSkipRequest() async throws {
        let configuration = makeConfiguration()
        // 预置永久提示：缓存命中后 AniSkip/弹幕都不该被查询。
        let context = makeContext()
        let cached = DanmakuIntroHint(startSeconds: 0, endSeconds: 90, evidenceCount: 5)
        await orchestrator.service.persistIntroHint(cached, for: 3001)
        // 提示以 episodeID 为键，缓存匹配路径同样生效——预置映射直接命中。
        await orchestrator.service.remember(
            match: DanmakuEpisodeMatch(episodeID: 3001), cacheKey: context.cacheKey, revision: 1)
        await orchestrator.service.claimMatchRevision(cacheKey: context.cacheKey, revision: 1)

        MockURLProtocol.handler = { request in
            if request.url!.host == "api.aniskip.com" || request.url!.host == "graphql.anilist.co" {
                XCTFail("缓存命中不应查询 AniSkip/AniList")
            }
            switch request.url!.path {
            case "/v1/comments/3001":
                return TestSupport.response(
                    #"{"count":1,"comments":[{"cid":1,"p":"1,1,16777215,100","m":"你好"}]}"#,
                    url: request.url!)
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
        XCTAssertEqual(outcome, .loaded(
            episodeID: 3001, commentCount: 1, title: "弹弹play",
            introHint: cached))
    }

    // MARK: 类型硬门槛 / 特典目标

    /// 回归（用户实报）：中二病 S00E29 特典，弹弹play 的模糊/搜索候选里有同 IP 剧场版的
    /// S29 特典（「映画公開記念! 暗黒謝肉祭!」，弹幕为空）。剧场版与剧集是不同作品，
    /// 类型硬门槛必须让它出局——落到 noMatch 手动选，而不是错匹配。
    func testMovieCandidatesAreExcludedForSpecialTarget() async throws {
        let configuration = makeConfiguration()
        let context = DanmakuMatchContext(
            uuid: UUID(),
            cacheKey: "jellyfin:special-movie-gate",
            allowsCachedMatchReuse: true,
            fileName: "中二病也要谈恋爱! - S00E29 - 第 29 集",
            fileSize: 64,
            durationSeconds: 1417,
            localFileURL: nil,
            remoteURL: URL(string: "https://media.example.com/video.mp4"),
            remoteHeaders: [:],
            animeTitle: "中二病也要谈恋爱!",
            episodeNumber: 29,
            seasonNumber: 0,
            special: DanmakuSpecialTarget(index: 29, kinds: DanmakuSpecialKind.fallbackOrder)
        )
        let fingerprint = makeFingerprintData()
        let noMatchBody = """
        {"success":true,"errorCode":0,"resultCount":0,"isMatched":false,"matches":[]}
        """
        // 真实候选形态：剧场版第1话 + 同 IP 剧场版的 S29（打分本可以靠序号命中 +2000）
        let searchBody = """
        {"success":true,"errorCode":0,"animes":[
          {"animeId":13176,"animeTitle":"剧场版 中二病也要谈恋爱！ -Take On Me- ","type":"movie","typeDescription":"剧场版","episodes":[
            {"episodeId":131760001,"episodeTitle":"第1话 剧场版 中二病也要谈恋爱！ -Take On Me- "},
            {"episodeId":131769029,"episodeTitle":"S29 映画公開記念! 暗黒謝肉祭!"}]}]}
        """
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/match":
                return TestSupport.response(noMatchBody, url: request.url!)
            case "/v1/search/episodes":
                return TestSupport.response(searchBody, url: request.url!)
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
        XCTAssertEqual(outcome, .noMatch, "剧场版候选应被类型硬门槛排除，落 noMatch 而非错匹配")
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
    var danmakuPayloadFormat: DanmakuPayloadFormat = .both
    var injectedJSON: String?
    var injectedEntries: [DanmakuJSONParser.Entry]?
    var injectedOffset: Duration?
    var didClear = false
    /// 记录调用 waitUntilReady 时的 uuid，供断言（必须与请求 id 一致）。
    var waitedUUIDs: [UUID] = []
    /// 为 true 时就绪等待直接失败（等价于 30s 超时）。
    var readyNeverResolves = false

    func waitUntilReady(uuid: UUID, timeout: Duration) async -> Bool {
        waitedUUIDs.append(uuid)
        return !readyNeverResolves
    }

    func replaceDanmaku(
        uuid: UUID,
        entries: [DanmakuJSONParser.Entry],
        json: String?,
        name: String,
        offset: Duration
    ) throws -> Bool {
        injectedEntries = entries
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
