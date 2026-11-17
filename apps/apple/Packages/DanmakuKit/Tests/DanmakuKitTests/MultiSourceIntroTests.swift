import XCTest
@testable import DanmakuKit

/// 多源跳过片头（AniSkip ∥ anime-skip ∥ TheIntroDB）、兄弟集聚合与手动跳过
/// 学习的单元测试。客户端走 MockURLProtocol,纯函数直测。
@MainActor
final class MultiSourceIntroTests: XCTestCase {

    // MARK: 多源选优

    private func interval(
        _ source: DanmakuIntroHintSource, _ start: Double?, _ end: Double
    ) -> DanmakuLoadOrchestrator.SkipSourceInterval {
        .init(source: source, start: start, end: end)
    }

    func testAgreementTakesMedianAndVotes() {
        let best = DanmakuLoadOrchestrator.selectBestInterval([
            interval(.aniskip, 50, 140),
            interval(.animeSkip, 48, 142),
            interval(.theIntroDB, 90, 200),
        ])
        // aniskip 140 与 animeSkip 142 同簇（±10s）→ 中位 141,两票;
        // theIntroDB 200 单票。来源取簇内优先级最高者 aniskip。
        XCTAssertEqual(best?.end, 141)
        XCTAssertEqual(best?.votes, 2)
        XCTAssertEqual(best?.source, .aniskip)
        XCTAssertEqual(best?.start, 49)
    }

    func testDisagreementFallsBackToHighestPrioritySource() {
        let best = DanmakuLoadOrchestrator.selectBestInterval([
            interval(.theIntroDB, 80, 180),
            interval(.animeSkip, 40, 300),
        ])
        // 两簇各一票 → 优先级 animeSkip(4) > theIntroDB(2)。
        XCTAssertEqual(best?.source, .animeSkip)
        XCTAssertEqual(best?.end, 300)
        XCTAssertEqual(best?.votes, 1)
    }

    func testEmptyIntervalsReturnNil() {
        XCTAssertNil(DanmakuLoadOrchestrator.selectBestInterval([]))
    }

    // MARK: anime-skip 区间重建

    private func animeSkipEpisode(
        season: String?, number: String?, _ stamps: [(Double, String)]
    ) -> AnimeSkipClient.Response.Episode {
        .init(
            season: season, number: number,
            timestamps: stamps.map { .init(at: $0.0, type: .init(name: $0.1)) })
    }

    func testAnimeSkipIntervalReconstruction() {
        // 无职转生 S1E3 实测形态:Recap → Canon → Intro → Mixed Intro → Canon。
        let episodes = [
            animeSkipEpisode(season: "1", number: "3", [
                (4.891, "Recap"), (23.891, "Canon"), (36, "Intro"),
                (132.91, "Mixed Intro"), (221.49, "Canon"), (1329.09, "Title Card"),
            ]),
        ]
        let interval = AnimeSkipClient.introInterval(
            from: episodes, seasonNumber: 1, episodeNumber: 3)
        // 第一个 Intro 类起点 36 → 下一时间戳 132.91。
        XCTAssertEqual(interval?.startSeconds, 36)
        XCTAssertEqual(interval?.endSeconds, 132.91)
    }

    func testAnimeSkipSeasonAndNumberMatching() {
        let episodes = [
            animeSkipEpisode(season: "2", number: "3", [(0, "Canon"), (90, "Intro"), (180, "Canon")]),
            animeSkipEpisode(season: "1", number: "3", [(0, "Canon"), (80, "Intro"), (170, "Canon")]),
        ]
        let interval = AnimeSkipClient.introInterval(
            from: episodes, seasonNumber: 1, episodeNumber: 3)
        XCTAssertEqual(interval?.startSeconds, 80)
        // 集号匹配优先、无季号命中时退首个。
        let fallback = AnimeSkipClient.introInterval(
            from: episodes, seasonNumber: 9, episodeNumber: 3)
        XCTAssertEqual(fallback?.startSeconds, 90)
    }

    func testAnimeSkipFullPathViaMock() async throws {
        let client = AnimeSkipClient(clientID: "test-client", session: TestSupport.mockedSession())
        let body = """
        {"data":{"findShowsByExternalId":[{"episodes":[
            {"season":"1","number":"3","timestamps":[
                {"at":0,"type":{"name":"Canon"}},
                {"at":80,"type":{"name":"Intro"}},
                {"at":170,"type":{"name":"Canon"}}]}
        ]}]}}
        """
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.anime-skip.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), "test-client")
            return TestSupport.response(body, url: request.url!)
        }
        defer { MockURLProtocol.handler = nil }
        let interval = try await client.introInterval(
            anilistID: 108465, seasonNumber: 1, episodeNumber: 3)
        XCTAssertEqual(interval?.startSeconds, 80)
        XCTAssertEqual(interval?.endSeconds, 170)
    }

    // MARK: TheIntroDB

    func testTheIntroDBParsesIntroSegments() async throws {
        let client = TheIntroDBClient(session: TestSupport.mockedSession())
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.theintrodb.org")
            XCTAssertEqual(request.url?.path, "/v3/media")
            let items = TestSupport.queryItems(of: request)
            XCTAssertEqual(items["tmdb_id"], "241535")
            XCTAssertEqual(items["season"], "1")
            XCTAssertEqual(items["episode"], "3")
            return TestSupport.response(
                #"{"intro":[{"start_ms":437388,"end_ms":537777}]}"#,
                url: request.url!)
        }
        defer { MockURLProtocol.handler = nil }
        let interval = try await client.introInterval(
            tmdbID: 241535, seasonNumber: 1, episodeNumber: 3)
        XCTAssertEqual(interval?.startSeconds, 437.388)
        XCTAssertEqual(interval?.endSeconds, 537.777)
    }

    func testTheIntroDBMissingIntroReturnsNil() async throws {
        let client = TheIntroDBClient(session: TestSupport.mockedSession())
        MockURLProtocol.handler = { request in
            TestSupport.response(#"{"credits":[{"start_ms":1,"end_ms":2}]}"#, url: request.url!)
        }
        defer { MockURLProtocol.handler = nil }
        let interval = try await client.introInterval(tmdbID: 1, seasonNumber: 1, episodeNumber: 1)
        XCTAssertNil(interval)
    }

    func testTheIntroDBNotFoundThrows() async {
        let client = TheIntroDBClient(session: TestSupport.mockedSession())
        MockURLProtocol.handler = { request in
            TestSupport.response(#"{"error":"media not found"}"#, status: 404, url: request.url!)
        }
        defer { MockURLProtocol.handler = nil }
        do {
            _ = try await client.introInterval(tmdbID: 1, seasonNumber: 1, episodeNumber: 1)
            XCTFail("404 应当抛错")
        } catch {
            // 预期路径:编排层按 debug 日志降级。
        }
    }

    // MARK: 解析器:anilist-only 命中是正缓存而非负缓存

    func testAnilistOnlyHitIsPositiveCached() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-aniskip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = AniSkipIDResolver(
            store: AniSkipIDStore(directory: directory),
            session: TestSupport.mockedSession(),
            now: { Date(timeIntervalSince1970: 1_000_000) })
        let identity = AniSkipAnimeIdentity(
            anilistID: 187260, title: "与你相恋到生命尽头", seasonNumber: 1)

        // AniList 条目有 id 无 idMal(部分条目如此):aniskip 查不了,anime-skip 能用。
        MockURLProtocol.handler = { request in
            TestSupport.response(
                #"{"data":{"Media":{"id":187260,"idMal":null}}}"#, url: request.url!)
        }
        defer { MockURLProtocol.handler = nil }
        let ids = await resolver.resolve(for: identity)
        XCTAssertNil(ids.malID)
        XCTAssertEqual(ids.anilistID, 187260)
        XCTAssertFalse(ids.isEmpty, "anilist-only 不是解析失败,不该进负缓存")

        // 第二次解析走正缓存,不再打网络(命中即 XCTFail)。
        MockURLProtocol.handler = { _ in
            XCTFail("正缓存命中不应发起网络请求")
            throw URLError(.unsupportedURL)
        }
        let cached = await resolver.resolve(for: identity)
        XCTAssertEqual(cached.anilistID, 187260)
    }

    // MARK: 兄弟集提示聚合

    func testSiblingHintsOnlyReturnDanmakuSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-sibling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DanmakuCache(directory: directory)
        let service = DanmakuService(cache: cache)

        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 84190003, animeID: 8419),
            cacheKey: "k1", revision: 1)
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 84190004, animeID: 8419),
            cacheKey: "k2", revision: 1)
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 142360009, animeID: 14236),
            cacheKey: "k3", revision: 1)
        await service.persistIntroHint(
            DanmakuIntroHint(startSeconds: 52, endSeconds: 142, evidenceCount: 3, source: .danmaku),
            for: 84190003)
        await service.persistIntroHint(
            DanmakuIntroHint(startSeconds: 50, endSeconds: 144, evidenceCount: 3, source: .aniskip),
            for: 84190004)

        let hints = await service.siblingIntroHints(animeID: 8419, excluding: 84190005)
        // 84190004 是 aniskip 源,不参与聚合。
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.first?.source, .danmaku)
        // 位段推导回退:旧记录无 animeID 时按 episodeID/10000 分组。
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 84190006),
            cacheKey: "k4", revision: 1)
        let derived = await service.siblingIntroHints(animeID: 8419, excluding: 84190003)
        XCTAssertEqual(derived.count, 0, "84190006 无提示、84190004 非 danmaku 源")
    }

    @MainActor
    func testSiblingAggregatedHintRequiresConsensus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-sibling-orch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DanmakuCache(directory: directory)
        let service = DanmakuService(cache: cache)
        let orchestrator = DanmakuLoadOrchestrator(service: service, session: TestSupport.mockedSession())

        // 8419 的两集提示一致(142/143)→ 采纳中位。
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 84190003, animeID: 8419),
            cacheKey: "s1", revision: 1)
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 84190004, animeID: 8419),
            cacheKey: "s2", revision: 1)
        await service.persistIntroHint(
            DanmakuIntroHint(startSeconds: 52, endSeconds: 142, evidenceCount: 2, source: .danmaku),
            for: 84190003)
        await service.persistIntroHint(
            DanmakuIntroHint(startSeconds: 51, endSeconds: 143, evidenceCount: 2, source: .danmaku),
            for: 84190004)
        let consensus = await orchestrator.siblingAggregatedHint(
            match: DanmakuEpisodeMatch(episodeID: 84190005, animeID: 8419))
        XCTAssertEqual(consensus?.endSeconds, 142.5)
        XCTAssertEqual(consensus?.evidenceCount, 2)
        XCTAssertEqual(consensus?.startSeconds, 51.5)

        // 离散(败犬型:各集 OP 位置不同)→ 不采纳。
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 183170003, animeID: 18317),
            cacheKey: "s3", revision: 1)
        await service.remember(
            match: DanmakuEpisodeMatch(episodeID: 183170006, animeID: 18317),
            cacheKey: "s4", revision: 1)
        await service.persistIntroHint(
            DanmakuIntroHint(startSeconds: nil, endSeconds: 259, evidenceCount: 2, source: .danmaku),
            for: 183170003)
        await service.persistIntroHint(
            DanmakuIntroHint(startSeconds: nil, endSeconds: 209, evidenceCount: 2, source: .danmaku),
            for: 183170006)
        let scattered = await orchestrator.siblingAggregatedHint(
            match: DanmakuEpisodeMatch(episodeID: 183170009, animeID: 18317))
        XCTAssertNil(scattered, "兄弟集落点离散(变量 OP)不该套用")
    }

    // MARK: 手动跳过学习

    private func seekEvent(_ episodeID: Int64, _ position: Double) -> IntroSeekEvent {
        .init(episodeID: episodeID, position: position, at: Date(timeIntervalSince1970: 1_000_000))
    }

    func testCrossEpisodeConsensusRequiresDistinctEpisodes() {
        // 同一集反复跳不算跨集证据。
        XCTAssertNil(IntroLearningStore.crossEpisodeConsensus(of: [
            seekEvent(1, 142), seekEvent(1, 143), seekEvent(1, 141),
        ]))
        // 两个不同集聚在同一落点 → 共识。
        let consensus = IntroLearningStore.crossEpisodeConsensus(of: [
            seekEvent(1, 141), seekEvent(2, 143), seekEvent(3, 500),
        ])
        XCTAssertEqual(consensus?.end, 142)
        XCTAssertEqual(consensus?.episodeCount, 2)
        // 离散(变量 OP)→ nil。
        XCTAssertNil(IntroLearningStore.crossEpisodeConsensus(of: [
            seekEvent(1, 259), seekEvent(2, 209),
        ]))
        // 落点超出学习窗口（片头结束点不会 <30s）。
        XCTAssertNil(IntroLearningStore.crossEpisodeConsensus(of: [
            seekEvent(1, 20), seekEvent(2, 21),
        ]))
    }

    func testLearningStorePersistsAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-learn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = IntroLearningStore(directory: directory)
        await store.record(animeID: 8419, event: seekEvent(84190003, 142))
        await store.record(animeID: 8419, event: seekEvent(84190004, 143))
        let hint = await store.consensusHint(forAnime: 8419)
        XCTAssertEqual(hint?.endSeconds, 142.5)
        let notPromotedYet = await store.promotedHint(forAnime: 8419)
        XCTAssertNil(notPromotedYet, "只记录不晋升")

        await store.promote(
            animeID: 8419,
            hint: DanmakuIntroHint(startSeconds: nil, endSeconds: 142.5, evidenceCount: 2, source: .learned))

        let reopened = IntroLearningStore(directory: directory)
        let promoted = await reopened.promotedHint(forAnime: 8419)
        XCTAssertEqual(promoted?.endSeconds, 142.5)
        XCTAssertEqual(promoted?.source, .learned)
        let otherAnime = await reopened.promotedHint(forAnime: 14236)
        XCTAssertNil(otherAnime, "按 anime 隔离")
    }
}
