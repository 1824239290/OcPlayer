import Foundation
import Testing

@testable import BangumiKit

struct BangumiKitTests {
    @Test func collectionTypeMapping() {
        #expect(BangumiCollectionType(1) == .wish)
        #expect(BangumiCollectionType(3) == .doing)
        #expect(BangumiCollectionType(99) == .none)
        #expect(BangumiCollectionType.allTypes().count == 5)
    }

    /// 收藏分页查询参数必须真正拼进 URL——此前只组了 queryItems 没挂上去，
    /// 导致 since 增量同步失效、offset 恒 0（收藏超过默认页大小的部分永远拉不到）。
    @Test func collectionsURLCarriesPagingQuery() {
        let url = BangumiCollectionService.collectionsURL(
            type: .doing, subjectType: .anime, since: 12345, limit: 50, offset: 200)
        #expect(url.path().hasSuffix("p1/collections/subjects"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        #expect(value("since") == "12345")
        #expect(value("limit") == "50")
        #expect(value("offset") == "200")
        #expect(value("type") == String(BangumiCollectionType.doing.rawValue))
        #expect(value("subjectType") == String(BangumiSubjectType.anime.rawValue))
    }

    /// 图床地址重写：相对路径原样放行（此前会被强加 scheme 成坏 URL），
    /// http → https，`//` 协议相对地址补 https。
    @Test func imageURLStringRewritesAndPreserves() {
        #expect(BangumiURL.imageURLString(from: "/pic/x.jpg") == "/pic/x.jpg")
        #expect(BangumiURL.imageURLString(from: "pic/x.jpg") == "pic/x.jpg")
        #expect(
            BangumiURL.imageURLString(from: "//lain.bgm.tv/pic/cover/l/xx.jpg")
                == "https://lain.bgm.tv/pic/cover/l/xx.jpg")
        #expect(
            BangumiURL.imageURLString(from: "http://lain.bgm.tv/pic/cover/l/xx.jpg")
                == "https://lain.bgm.tv/pic/cover/l/xx.jpg")
        #expect(
            BangumiURL.imageURLString(from: "https://lain.bgm.tv/pic/cover/l/xx.jpg")
                == "https://lain.bgm.tv/pic/cover/l/xx.jpg")
    }

    @Test func episodeSortDisplay() {
        let episode = BangumiFixture.episode(id: 1, subjectID: 1, sort: 12.5)
        #expect(episode.sortDisplay == "12.5")
        #expect(BangumiFixture.episode(id: 2, subjectID: 1, sort: 3).sortDisplay == "03")
    }

    @Test func progressFraction() {
        let progress = BangumiProgressSubject(
            subject: BangumiFixture.subject(id: 1, eps: 10, epStatus: 4), episodes: [])
        #expect(progress.progressText == "4 / 10")
        #expect(progress.progressFraction == 0.4)
    }

    /// 章节还没同步下来时，不能因为「找不到下一集」就判成看完。
    @Test func notFinishedWhileEpisodesAreMissing() {
        let waiting = BangumiProgressSubject(
            subject: BangumiFixture.subject(id: 1, eps: 12, epStatus: 3), episodes: [])
        #expect(waiting.hasEpisodeData == false)
        #expect(waiting.nextEpisode == nil)
        #expect(waiting.isFinished == false)

        let finished = BangumiProgressSubject(
            subject: BangumiFixture.subject(id: 2, eps: 12, epStatus: 12),
            episodes: [BangumiFixture.episode(id: 1, subjectID: 2, sort: 1, status: .collect)])
        #expect(finished.isFinished)
    }

    /// 播放结束自动标记前的条目状态推进决策：未收藏/想看/搁置/抛弃推成「在看」，
    /// 「在看」不动，「看过」不回退（完结条目不该被重看一集拨回去）。
    @Test func targetWatchingStateOnlyAdvancesNonDoing() {
        #expect(BangumiEpisodeRepository.targetWatchingState(for: nil) == .doing)
        #expect(BangumiEpisodeRepository.targetWatchingState(for: .none) == .doing)
        #expect(BangumiEpisodeRepository.targetWatchingState(for: .wish) == .doing)
        #expect(BangumiEpisodeRepository.targetWatchingState(for: .onHold) == .doing)
        #expect(BangumiEpisodeRepository.targetWatchingState(for: .dropped) == .doing)
        #expect(BangumiEpisodeRepository.targetWatchingState(for: .doing) == nil)
        #expect(BangumiEpisodeRepository.targetWatchingState(for: .collect) == nil)
    }

    /// 标「看过」前要按单集 id 反查条目 id 做在看推进；本地缺集时返回 nil 不拦截标集。
    @Test func subjectIDOfEpisodeResolvesAndMisses() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 7, eps: 2, epStatus: 0))
        try await db.saveEpisodes(
            subjectId: 7,
            items: [BangumiFixture.episode(id: 71, subjectID: 7, sort: 1)])
        #expect(try await db.subjectID(ofEpisode: 71) == 7)
        #expect(try await db.subjectID(ofEpisode: 999) == nil)
    }

    // MARK: - OAuth state（CSRF 防护）

    /// 授权 URL 由网关拼，客户端只传 state：必须随机且每次授权轮换（防重放）。
    @Test func oauthURLIncludesStateAndRotates() async throws {
        let log = OAuthRequestLog()
        let client = BangumiGatewayFixture.client(log: log)
        let url1 = try await client.buildOAuthURL()
        let url2 = try await client.buildOAuthURL()

        func state(of url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "state" }?
                .value
        }
        let state1 = state(of: url1)
        let state2 = state(of: url2)
        #expect(state1 != nil && !state1!.isEmpty, "授权 URL 必须带 state")
        #expect(state1 != state2, "每次授权 state 必须轮换：\(state1 ?? "nil") vs \(state2 ?? "nil")")
        // 发给网关的 state 必须与授权 URL 里的一致（网关原样回填）。
        #expect(log.requests.compactMap(\.stateQuery) == [state1, state2])
        #expect(log.requests.allSatisfy { $0.path == "/v1/bangumi/oauth/authorize" })
    }

    /// state 不匹配的回调必须在发网络请求前被拒绝（CSRF 兜底）。
    @Test func oauthExchangeRejectsMismatchedState() async throws {
        let log = OAuthRequestLog()
        let client = BangumiGatewayFixture.client(log: log)
        _ = try await client.buildOAuthURL()
        let requestsBeforeExchange = log.requests.count
        do {
            _ = try await client.exchangeForAccessToken(
                code: "forged-code", state: "forged-state")
            Issue.record("state 不匹配应该抛错")
        } catch let error as BangumiError {
            #expect(error.userMessage.contains("授权校验失败"))
        } catch {
            Issue.record("应该是 BangumiError：\(error)")
        }
        #expect(log.requests.count == requestsBeforeExchange, "state 不匹配不该发出换 token 请求")
    }

    /// 换 token 只发 code：`client_secret` 只在网关侧，客户端请求里不得出现。
    @Test func oauthExchangeSendsCodeOnlyAndStoresCredentials() async throws {
        let log = OAuthRequestLog()
        let suite = "BangumiGatewayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BangumiStore(defaults: defaults)
        let client = BangumiGatewayFixture.client(log: log, store: store)
        let url = try await client.buildOAuthURL()
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value

        _ = try await client.exchangeForAccessToken(code: "auth-code", state: state ?? "")

        let exchange = try #require(log.requests.last)
        #expect(exchange.path == "/v1/bangumi/oauth/token")
        #expect(exchange.bodyKeys == ["code"], "换 token 只带 code，实测：\(exchange.bodyKeys)")
        #expect(exchange.apiKey == BangumiGatewayFixture.apiKey)
        #expect(exchange.userAgent?.hasPrefix("OcPlay/") == true, "网关要求 OcPlay/ 前缀 UA")
        #expect(store.auth?.accessToken == "access-1")
        #expect(store.auth?.refreshToken == "refresh-1")
    }

    /// 网关的 403 靠 `error.code` 区分原因：`request()` 曾经在 403 分支丢掉响应体，
    /// 于是 SCOPE_REQUIRED / UA 缺失都退化成笼统的「请求被拒绝」。
    @Test func gatewayForbiddenCodesMapToTheirOwnMessages() async throws {
        for (code, expected) in [
            ("SCOPE_REQUIRED", "bgm:oauth"),
            ("OCPLAY_USER_AGENT_REQUIRED", "请求标识"),
            ("GATEWAY_NOT_CONFIGURED", "尚未配置 Bangumi 登录"),
        ] {
            let client = BangumiGatewayFixture.client(
                log: OAuthRequestLog(),
                responder: { _ in
                    (403, #"{"success":false,"error":{"code":"\#(code)","message":"x"}}"#)
                })
            do {
                _ = try await client.buildOAuthURL()
                Issue.record("\(code) 不该成功")
            } catch let error as BangumiError {
                #expect(error.userMessage.contains(expected), "\(code) → \(error.userMessage)")
            }
        }

        // 非网关信封的 403（bgm.tv 自己的 403）仍走笼统文案，别把 body 当原因解析。
        let client = BangumiGatewayFixture.client(
            log: OAuthRequestLog(), responder: { _ in (403, "<html>Forbidden</html>") })
        do {
            _ = try await client.buildOAuthURL()
            Issue.record("403 不该成功")
        } catch let error as BangumiError {
            #expect(error.userMessage == "请求被拒绝，请检查权限")
        }
    }

    /// 网关透传 Bangumi 的 refresh 响应：没带新 refresh_token 时沿用旧值
    /// （Bangumi 只在轮换时返回），别把凭证存成空串。
    @Test func tokenResponseWithoutRefreshTokenKeepsPrevious() {
        let rotated = BangumiAuth(
            response: BangumiTokenResponse(
                accessToken: "a1", expiresIn: 3600, refreshToken: "r1"))
        let reused = BangumiAuth(
            response: BangumiTokenResponse(accessToken: "a2"),
            fallbackRefreshToken: rotated.refreshToken)
        #expect(reused.refreshToken == "r1")
        #expect(reused.accessToken == "a2")
        // 上游没给 expires_in 时按默认有效期兜底，不能当成「立刻过期」。
        #expect(reused.isExpired() == false)
    }
}

// MARK: - 本地库

struct BangumiDatabaseTests {
    /// 窗口以「下一条未看本篇」为中心。
    @Test func progressWindowCentersOnNextUnwatched() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 100, eps: 12, epStatus: 5))
        try await db.saveEpisodes(
            subjectId: 100,
            items: (1...12).map {
                BangumiFixture.episode(
                    id: $0, subjectID: 100, sort: Float($0),
                    status: $0 <= 5 ? .collect : BangumiEpisodeCollectionType.none)
            })

        let subject = try await db.fetchProgressSubject(subjectId: 100, episodeWindowSize: 5)
        let sorts = try #require(subject?.episodes.map(\.sort))
        // 下一条未看是 6，窗口 5 → 前 2 后 2
        #expect(sorts == [4, 5, 6, 7, 8])
        #expect(subject?.nextEpisode?.sort == 6)
        #expect(subject?.isFinished == false)
    }

    /// 全看完时退回末尾若干集。
    @Test func progressWindowFallsBackToTail() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 101, eps: 6, epStatus: 6))
        try await db.saveEpisodes(
            subjectId: 101,
            items: (1...6).map {
                BangumiFixture.episode(id: $0, subjectID: 101, sort: Float($0), status: .collect)
            })

        let subject = try await db.fetchProgressSubject(subjectId: 101, episodeWindowSize: 3)
        #expect(subject?.episodes.map(\.sort) == [4, 5, 6])
        #expect(subject?.nextEpisode == nil)
        #expect(subject?.isFinished == true)
    }

    /// 开头就没看过时窗口不越界。
    @Test func progressWindowClampsAtHead() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 102, eps: 4, epStatus: 0))
        try await db.saveEpisodes(
            subjectId: 102,
            items: (1...4).map { BangumiFixture.episode(id: $0, subjectID: 102, sort: Float($0)) })

        let subject = try await db.fetchProgressSubject(subjectId: 102, episodeWindowSize: 3)
        #expect(subject?.episodes.map(\.sort) == [1, 2, 3])
    }

    /// 单集标记后已看数按「实际标为看过的本篇数」重算。
    @Test func markEpisodeRecountsWatched() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 200, eps: 5, epStatus: 0))
        try await db.saveEpisodes(
            subjectId: 200,
            items: (1...5).map { BangumiFixture.episode(id: $0, subjectID: 200, sort: Float($0)) })

        try await db.updateEpisodeCollection(episodeId: 3, type: .collect)
        var stored = try await db.subject(id: 200)
        #expect(stored?.interest?.epStatus == 1)

        try await db.updateEpisodeCollection(episodeId: 1, type: .collect)
        stored = try await db.subject(id: 200)
        #expect(stored?.interest?.epStatus == 2)

        // 撤销要减回去
        try await db.updateEpisodeCollection(episodeId: 3, type: BangumiEpisodeCollectionType.none)
        stored = try await db.subject(id: 200)
        #expect(stored?.interest?.epStatus == 1)
    }

    /// 「看到此集」不能抹掉更靠后已经标过的集。
    @Test func batchMarkKeepsLaterCollectedEpisodes() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 201, eps: 10, epStatus: 1))
        try await db.saveEpisodes(
            subjectId: 201,
            items: (1...10).map {
                BangumiFixture.episode(
                    id: $0, subjectID: 201, sort: Float($0),
                    status: $0 == 10 ? .collect : BangumiEpisodeCollectionType.none)
            })

        // 看到第 3 集 → 1/2/3 标上，第 10 集本来标过要保留 → 共 4 集
        try await db.updateEpisodeCollection(episodeId: 3, type: .collect, batch: true)
        let stored = try await db.subject(id: 201)
        #expect(stored?.interest?.epStatus == 4)

        let episodes = try await db.fetchEpisodes(subjectId: 201, main: true)
        let collected = episodes.filter { $0.collectionTypeEnum == .collect }.map(\.sort)
        #expect(collected == [1, 2, 3, 10])
    }

    /// 特典不计入本篇已看数。
    @Test func markingSpecialDoesNotChangeWatchedCount() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 202, eps: 2, epStatus: 0))
        try await db.saveEpisodes(
            subjectId: 202,
            items: [
                BangumiFixture.episode(id: 1, subjectID: 202, sort: 1),
                BangumiFixture.episode(id: 2, subjectID: 202, sort: 1, type: .sp),
            ])

        try await db.updateEpisodeCollection(episodeId: 2, type: .collect)
        let stored = try await db.subject(id: 202)
        #expect(stored?.interest?.epStatus == 0)
    }

    /// 整页的章节窗口现在是一条 `IN (...)` 批量取回、在内存里按 subject 分组切的，
    /// 所以要盯住「每个条目各拿到自己的窗口」——分组串了的话单条目查询是看不出来的。
    @Test func pagedProgressWindowsStayPerSubject() async throws {
        let db = try BangumiFixture.makeDatabase()
        // 三部进度各不相同的番，collectedAt 递减以固定分页顺序。
        try await db.saveSubject(
            BangumiFixture.subject(id: 600, eps: 12, epStatus: 5, collectedAt: 300))
        try await db.saveEpisodes(
            subjectId: 600,
            items: (1...12).map {
                BangumiFixture.episode(
                    id: 6_000 + $0, subjectID: 600, sort: Float($0),
                    status: $0 <= 5 ? .collect : BangumiEpisodeCollectionType.none)
            })
        // 全看完 → 退回末尾
        try await db.saveSubject(
            BangumiFixture.subject(id: 601, eps: 4, epStatus: 4, collectedAt: 200))
        try await db.saveEpisodes(
            subjectId: 601,
            items: (1...4).map {
                BangumiFixture.episode(
                    id: 6_100 + $0, subjectID: 601, sort: Float($0), status: .collect)
            })
        // 一集没看 → 窗口贴头
        try await db.saveSubject(
            BangumiFixture.subject(id: 602, eps: 8, epStatus: 0, collectedAt: 100))
        try await db.saveEpisodes(
            subjectId: 602,
            items: (1...8).map {
                BangumiFixture.episode(id: 6_200 + $0, subjectID: 602, sort: Float($0))
            })

        let page = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 20, offset: 0)

        #expect(page.total == 3)
        #expect(page.data.map(\.subject.id) == [600, 601, 602])
        #expect(page.data[0].episodes.map(\.sort) == [4, 5, 6, 7, 8])
        #expect(page.data[1].episodes.map(\.sort) == [1, 2, 3, 4])
        #expect(page.data[2].episodes.map(\.sort) == [1, 2, 3, 4, 5])
        // 批量路径不能和单条目路径分叉，章节也必须都属于自己。
        for item in page.data {
            let single = try await db.fetchProgressSubject(
                subjectId: item.subject.id, episodeWindowSize: 5)
            #expect(single?.episodes.map(\.sort) == item.episodes.map(\.sort))
            #expect(item.episodes.allSatisfy { $0.subjectID == item.subject.id })
        }
    }

    /// 分页的 offset / limit 要真的切页，且 total 报全量
    /// （进度页原来只取第一页就把 total 丢了，攒到 100 条以上是静默截断）。
    @Test func pagedProgressRespectsOffsetAndLimit() async throws {
        let db = try BangumiFixture.makeDatabase()
        for index in 0..<5 {
            try await db.saveSubject(
                BangumiFixture.subject(
                    id: 700 + index, eps: 12, epStatus: 0, collectedAt: 500 - index))
        }

        let first = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 2, offset: 0)
        #expect(first.total == 5)
        #expect(first.data.map(\.subject.id) == [700, 701])

        let second = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 2, offset: 2)
        #expect(second.total == 5)
        #expect(second.data.map(\.subject.id) == [702, 703])

        let tail = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 2, offset: 4)
        #expect(tail.data.map(\.subject.id) == [704])
    }

    /// 本地搜索要能搜中文名（原来只搜 name 和恒空的 alias）。
    @Test func progressSearchMatchesChineseName() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(
            BangumiFixture.subject(
                id: 300, eps: 13, epStatus: 0,
                name: "Violet Evergarden", nameCN: "紫罗兰永恒花园"))
        try await db.saveSubject(
            BangumiFixture.subject(id: 301, eps: 12, epStatus: 0, name: "Steins;Gate", nameCN: "命运石之门"))

        let byChinese = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "紫罗兰",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(byChinese.data.map(\.subject.id) == [300])

        let byOriginal = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "steins",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(byOriginal.data.map(\.subject.id) == [301])
    }

    /// 放送时间排序：新番在前，无日期的垫底。
    @Test func airTimeSortOrdersByAirDate() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(
            BangumiFixture.subject(id: 400, eps: 12, epStatus: 0, collectedAt: 300, airDate: "2024-01-07"))
        try await db.saveSubject(
            BangumiFixture.subject(id: 401, eps: 12, epStatus: 0, collectedAt: 200, airDate: "2026-04-05"))
        try await db.saveSubject(
            BangumiFixture.subject(id: 402, eps: 12, epStatus: 0, collectedAt: 100, airDate: ""))

        let byAir = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .airTime, search: "",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(byAir.data.map(\.subject.id) == [401, 400, 402])
        #expect(byAir.total == 3)

        let byCollected = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(byCollected.data.map(\.subject.id) == [400, 401, 402])
    }

    /// 章节补齐只挑「在看 + 章节不全」的条目。
    @Test func missingEpisodesQuerySelectsIncompleteDoingSubjects() async throws {
        let db = try BangumiFixture.makeDatabase()
        // 章节一条都没有 → 要补
        try await db.saveSubject(BangumiFixture.subject(id: 500, eps: 12, epStatus: 0))
        // 章节齐了 → 不补
        try await db.saveSubject(BangumiFixture.subject(id: 501, eps: 2, epStatus: 0))
        try await db.saveEpisodes(
            subjectId: 501,
            items: (1...2).map { BangumiFixture.episode(id: 5010 + $0, subjectID: 501, sort: Float($0)) })
        // 章节不全 → 要补（但刚同步过，受重试间隔节流，见下面的断言）
        try await db.saveSubject(BangumiFixture.subject(id: 502, eps: 12, epStatus: 0))
        try await db.saveEpisodes(
            subjectId: 502, items: [BangumiFixture.episode(id: 5020, subjectID: 502, sort: 1)])
        // 不是「在看」 → 不补
        try await db.saveSubject(
            BangumiFixture.subject(id: 503, eps: 12, epStatus: 0, collectionType: .wish))
        // 不是动画/三次元 → 不补
        try await db.saveSubject(
            BangumiFixture.subject(id: 504, eps: 12, epStatus: 0, subjectType: .game))

        // 默认间隔下，只有「从没拉过」的 500 入选：502 刚拉过，等间隔到了再说。
        let ids = try await db.fetchSubjectIDsMissingEpisodes()
        #expect(Set(ids) == [500])
        // 不节流时，章节不全的 502 也该排进来。
        let unthrottled = try await db.fetchSubjectIDsMissingEpisodes(retryInterval: 0)
        #expect(Set(unthrottled) == [500, 502])
    }

    /// 总集数未知（eps = 0）时，只要一条章节都没有就该补。
    @Test func missingEpisodesQueryHandlesUnknownTotal() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 600, eps: 0, epStatus: 0))
        var missing = try await db.fetchSubjectIDsMissingEpisodes()
        #expect(missing == [600])

        try await db.saveEpisodes(
            subjectId: 600, items: [BangumiFixture.episode(id: 6000, subjectID: 600, sort: 1)])
        missing = try await db.fetchSubjectIDsMissingEpisodes()
        #expect(missing.isEmpty)
    }

    /// 拉过之后短期内不再重拉：`eps` 元数据比实际登记集数大的条目（远端只有 12 集但
    /// eps 写 13），补齐判据永远不满足，靠同步时间戳把重复请求挡住。
    @Test func missingEpisodesQueryThrottlesRetryAfterSync() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 610, eps: 13, epStatus: 0))
        #expect(try await db.fetchSubjectIDsMissingEpisodes() == [610])

        // 远端只给得出 12 集，落库后仍然「不满」。
        try await db.saveEpisodes(
            subjectId: 610,
            items: (1...12).map { BangumiFixture.episode(id: 6100 + $0, subjectID: 610, sort: Float($0)) })
        #expect(try await db.fetchSubjectIDsMissingEpisodes().isEmpty)

        // 过了重试间隔才会再排进来。
        let stale = try await db.fetchSubjectIDsMissingEpisodes(retryInterval: 0)
        #expect(stale == [610])
    }

    /// 远端确实没登记章节的条目也要盖时间戳，否则每次刷新都白拉。
    @Test func emptyEpisodeResultStillMarksSynced() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 620, eps: 0, epStatus: 0))
        #expect(try await db.fetchSubjectIDsMissingEpisodes() == [620])

        try await db.saveEpisodes(subjectId: 620, items: [])
        #expect(try await db.fetchSubjectIDsMissingEpisodes().isEmpty)
    }

    /// 整页批量落库与逐条落库结果一致。
    @Test func saveSubjectsWritesWholePage() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubjects((700...705).map { BangumiFixture.subject(id: $0, eps: 12, epStatus: 0) })
        let page = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(page.total == 6)
    }

    /// 单条目回读（`p1/subjects/{id}` 不返回 interest，附加拉取失败即 nil）不得把本地
    /// 收藏态清掉——一次瞬时网络抖动不该让条目从「在看」消失、进度归零。
    @Test func nonAuthoritativeMissingInterestKeepsLocalCollection() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 1100, eps: 12, epStatus: 5))

        // 回读路径的 DTO：没有 interest 键，元数据是新拉的。
        var refetched = BangumiSubjectDTO(id: 1100, name: "Refetched", type: .anime)
        refetched.eps = 12
        try await db.saveSubject(refetched)

        let stored = try await db.subject(id: 1100)
        #expect(stored?.name == "Refetched", "元数据照常更新")
        #expect(stored?.interest?.type == .doing, "收藏态保留")
        #expect(stored?.interest?.epStatus == 5, "观看进度保留")

        // 进度页按 ctype 过滤：条目必须还在「在看」列表里。
        let page = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(page.data.contains { $0.id == 1100 })
    }

    /// 收藏全量同步是权威来源：服务端确认没收藏（DTO 无 interest）时本地跟着清。
    @Test func authoritativeMissingInterestClearsLocalCollection() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 1200, eps: 12, epStatus: 5))

        try await db.saveSubjects(
            [BangumiSubjectDTO(id: 1200, name: "Refetched", type: .anime)],
            authoritativeInterest: true)

        let stored = try await db.subject(id: 1200)
        #expect(stored?.name == "Refetched")
        #expect(stored?.interest == nil, "权威路径仍按 nil 清空")

        let page = try await db.fetchProgressSubjects(
            progressTab: .anime, sortMode: .collectedAt, search: "",
            episodeWindowSize: 5, limit: 20, offset: 0)
        #expect(!page.data.contains { $0.id == 1200 })
    }

    /// slim 条目落库时 private 不该被 collectionType 带跑。
    @Test func slimSubjectDoesNotInferPrivateFlag() async throws {
        let db = try BangumiFixture.makeDatabase()
        var slim = BangumiSlimSubjectDTO()
        slim.id = 800
        slim.name = "Doing Anime"
        slim.type = .anime
        slim.interest = BangumiSlimSubjectInterest(
            rate: 0, type: .doing, comment: "", tags: [], updatedAt: 1)
        try await db.saveSubject(slim)

        let stored = try await db.subject(id: 800)
        #expect(stored?.interest?.type == .doing)
        #expect(stored?.interest?.`private` == false)
    }

    /// 批量读取一条 IN 查询拿回全部（日历页逐条 await 上百次的替代路径）。
    @Test func subjectsBatchFetchesAllRequested() async throws {
        let db = try BangumiFixture.makeDatabase()
        try await db.saveSubject(BangumiFixture.subject(id: 900, eps: 5, epStatus: 2))
        try await db.saveSubject(BangumiFixture.subject(id: 901, eps: 12, epStatus: 0))
        try await db.saveSubject(BangumiFixture.subject(id: 902, eps: 3, epStatus: 3))

        let fetched = try await db.subjects(ids: [900, 901, 902, 999])
        #expect(fetched.count == 3)
        #expect(fetched[900]?.id == 900)
        #expect(fetched[901]?.id == 901)
        #expect(fetched[999] == nil)
        // 与单条目路径一致：interest 字段都在。
        #expect(fetched[900]?.interest?.type == .doing)
        #expect(try await db.subjects(ids: []).isEmpty)
    }

    @Test func searchDecoding() async throws {
        let json = """
        {
          "data": [
            {
              "id": 343241,
              "name": "負けヒロインが多すぎる！",
              "nameCN": "败犬女主太多了！",
              "type": 1,
              "info": "2021-07-21 / 雨森たきび / いみぎむる / 小学館",
              "metaTags": [
                "日本",
                "小说"
              ],
              "rating": {
                "rank": 749,
                "count": [20, 3, 3, 7, 29, 123, 491, 1146, 410, 228],
                "score": 7.94,
                "total": 2460
              },
              "locked": false,
              "nsfw": false,
              "images": {
                "large": "https://lain.bgm.tv/pic/cover/l/1c/ba/343241_TWFSN.jpg"
              }
            }
          ],
          "total": 112
        }
        """.data(using: .utf8)!
        let paged: BangumiPagedDTO<BangumiSlimSubjectDTO> = try await BangumiAPIClient.shared.decodeResponse(json)
        #expect(paged.total == 112)
        #expect(paged.data.first?.nameCN == "败犬女主太多了！")

        let liveResults = try await BangumiSubjectService.search(keyword: "败犬女主太多了", limit: 10, offset: 0)
        #expect(liveResults.total > 0)
        #expect(!liveResults.data.isEmpty)
    }

    /// 搜索请求体 filter.type 必须是整数数组（{"type":[2]}）——此前编码成
    /// {"type":{"0":2}} 对象，Bangumi 服务端直接 400（body/filter/type must be array），
    /// UI 报「请求参数有误」。
    @Test func searchRequestBodyFilterTypeIsArray() throws {
        let body = BangumiSubjectService.searchRequestBody(keyword: "公主连结", filter: .anime)
        let data = try JSONEncoder().encode(body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["keyword"] as? String == "公主连结")
        #expect(json["sort"] as? String == "match")
        let filter = try #require(json["filter"] as? [String: Any])
        #expect(try #require(filter["type"] as? [Int]) == [BangumiSubjectType.anime.rawValue])
    }

    /// 不带 filter（或 filter 为「全部」）时请求体不出现 filter 字段。
    @Test func searchRequestBodyOmitsFilterWhenNone() throws {
        for filter: BangumiSubjectType? in [nil, .none] {
            let body = BangumiSubjectService.searchRequestBody(keyword: "x", filter: filter)
            let data = try JSONEncoder().encode(body)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["filter"] == nil)
        }
    }

    @Test func calendarDecoding() async throws {
        let json = """
        [
          {
            "weekday": {
              "en": "Mon",
              "cn": "星期一",
              "ja": "月耀日",
              "id": 1
            },
            "items": [
              {
                "id": 456080,
                "url": "http://bgm.tv/subject/456080",
                "type": 2,
                "name": "転校先",
                "name_cn": "转学后",
                "summary": "测试简介",
                "air_date": "2026-07-06",
                "air_weekday": 1,
                "rating": {
                  "total": 504,
                  "count": { "10": 10, "9": 2 },
                  "score": 5.0
                },
                "rank": 9739,
                "images": {
                  "large": "https://lain.bgm.tv/pic/cover/l/ce/e2/456080_C4q4C.jpg"
                },
                "collection": {
                  "doing": 1991
                }
              }
            ]
          }
        ]
        """.data(using: .utf8)!
        let calendar: [BangumiCalendarDayDTO] = try await BangumiAPIClient.shared.decodeResponse(json)
        #expect(calendar.count == 1)
        let day = try #require(calendar.first)
        #expect(day.weekday.id == 1)
        #expect(day.weekday.shortCN == "周一")
        #expect(day.items.count == 1)
        let item = try #require(day.items.first)
        #expect(item.id == 456080)
        #expect(item.nameCN == "转学后")
        #expect(item.displayName == "转学后")
        #expect(item.originalName == "転校先")
        #expect(item.doingCount == 1991)
        #expect(item.rank == 9739)
        #expect(item.rating?.score == 5.0)
        #expect(item.coverURL != nil)

        let slim = item.toSlimSubject()
        #expect(slim.id == 456080)
        #expect(slim.nameCN == "转学后")
    }

    /// 建库失败必须复位 setupTask + 暴露 databaseError；换正常目录重试应成功。
    @Test @MainActor func databaseSetupFailureResetsTaskAndAllowsRetry() async throws {
        let context = BangumiContext()
        // 把「目录」指向一个普通文件：createDirectory 在文件路径下必败。
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgm-block-\(UUID().uuidString)")
        try Data("block".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        context.setupIfNeeded(directory: blocker)
        for _ in 0..<50 where context.databaseError == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(context.databaseError != nil, "失败必须暴露错误态")
        #expect(!context.isDatabaseReady)

        // setupTask 已复位：换正常临时目录重试应成功（失败后不再静默短路）。
        let okDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgm-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: okDir) }
        context.setupIfNeeded(directory: okDir)
        for _ in 0..<50 where !context.isDatabaseReady {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(context.isDatabaseReady, "重试后建库应成功")
        #expect(context.databaseError == nil)
    }
}

// MARK: - 登录态

struct BangumiStoreTests {
    /// 只剩标记位、凭证已被清掉时必须算「未登录」，
    /// 否则 401 之后 UI 会永远停在已登录而每次操作静默失败。
    @Test func isAuthenticatedRequiresStoredCredentials() throws {
        let suite = "BangumiStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BangumiStore(defaults: defaults)

        #expect(store.isAuthenticated == false)

        store.setAuthenticated(true)
        #expect(store.isAuthenticated == false, "只有标记位、没有 token 不算登录")

        store.auth = BangumiAuth(
            response: BangumiTokenResponse(
                accessToken: "token", expiresIn: 3600, tokenType: "Bearer", refreshToken: "refresh"))
        #expect(store.isAuthenticated)

        store.auth = nil
        #expect(store.isAuthenticated == false, "凭证被 401 清掉后不能再算登录")
    }

    @Test func linkRoundTrip() throws {
        let suite = "BangumiLinkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BangumiStore(defaults: defaults)

        #expect(store.bangumiSubjectID(forJellyfinItemID: "abc") == nil)
        store.setBangumiSubjectID(1234, forJellyfinItemID: "abc")
        #expect(store.bangumiSubjectID(forJellyfinItemID: "abc") == 1234)
        store.setBangumiSubjectID(nil, forJellyfinItemID: "abc")
        #expect(store.bangumiSubjectID(forJellyfinItemID: "abc") == nil)
    }

    @Test func expiredAuthIsDetected() {
        let fresh = BangumiAuth(
            response: BangumiTokenResponse(
                accessToken: "a", expiresIn: 3600, tokenType: "Bearer", refreshToken: "r"))
        #expect(fresh.isExpired() == false)

        var expired = fresh
        expired.expiresAt = Date().addingTimeInterval(-1)
        #expect(expired.isExpired())
    }
}

// MARK: - 网关 OAuth 素材

/// 拦截 URLSession 请求，按 host 分派 mock 响应。
///
/// 按 host 而不是全局单例：swift-testing 并行跑测试，全局 handler 会互相串。
final class OAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    private static let lock = NSLock()

    static func register(
        host: String, handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(for host: String?) -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return host.flatMap { handlers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 已发出的网关请求（URLSession 线程写入，测试线程读）。
struct OAuthRequest {
    let path: String
    let apiKey: String?
    let userAgent: String?
    let stateQuery: String?
    let bodyKeys: [String]
}

final class OAuthRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OAuthRequest] = []

    var requests: [OAuthRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: OAuthRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }
}

enum BangumiGatewayFixture {
    static let apiKey = "ocp_test_key"

    /// 造一个走 mock 网关的客户端。每次调用用独立 host，测试之间互不干扰。
    /// `responder` 返回 (HTTP 状态, 响应体)，默认是三个 OAuth 端点的正常响应。
    static func client(
        log: OAuthRequestLog,
        store: BangumiStore? = nil,
        responder: (@Sendable (URLRequest) -> (Int, String))? = nil
    ) -> BangumiAPIClient {
        let host = "gateway-\(UUID().uuidString).test"
        OAuthMockURLProtocol.register(host: host) { request in
            let url = request.url!
            log.append(
                OAuthRequest(
                    path: url.path,
                    apiKey: request.value(forHTTPHeaderField: "X-API-Key"),
                    userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                    stateQuery: URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "state" }?.value,
                    bodyKeys: bodyKeys(of: request)))

            let (status, json) = responder?(request) ?? defaultResponse(for: url)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        return BangumiAPIClient(
            store: store ?? .shared,
            gateway: BangumiGatewayConfiguration(
                baseURL: URL(string: "https://\(host)")!,
                apiKey: apiKey,
                userAgent: "OcPlay/0.0.0-test (macOS; arm64)"),
            sessionFactory: { _ in URLSession(configuration: configuration) })
    }

    private static func defaultResponse(for url: URL) -> (Int, String) {
        switch url.path {
        case "/v1/bangumi/oauth/authorize":
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return (200, """
                {"authorize_url":"https://bgm.tv/oauth/authorize?client_id=bgm-test&response_type=code&redirect_uri=ocplayer%3A%2F%2Foauth%2Fcallback&state=\(state)",
                 "client_id":"bgm-test","redirect_uri":"ocplayer://oauth/callback","state":"\(state)"}
                """)
        case "/v1/bangumi/oauth/token":
            return (200, """
                {"access_token":"access-1","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-1"}
                """)
        default:
            return (404, #"{"success":false,"error":{"code":"ROUTE_NOT_FOUND","message":"unknown"}}"#)
        }
    }

    private static func bodyKeys(of request: URLRequest) -> [String] {
        // URLSession 交给 URLProtocol 时常常把 httpBody 转成 httpBodyStream，两条都要看。
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [] }
        return object.keys.sorted()
    }
}

// MARK: - 素材

/// 测试素材：全部现造，不联网。
enum BangumiFixture {
    static func makeDatabase() throws -> BangumiDatabaseOperator {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BangumiKitTests-\(UUID().uuidString)", isDirectory: true)
        let queue = try BangumiDatabaseFactory.makeDatabase(at: directory)
        return BangumiDatabaseOperator(database: queue)
    }

    static func subject(
        id: Int,
        eps: Int,
        epStatus: Int,
        name: String = "Subject",
        nameCN: String = "",
        subjectType: BangumiSubjectType = .anime,
        collectionType: BangumiCollectionType = .doing,
        collectedAt: Int = 0,
        airDate: String = ""
    ) -> BangumiSubjectDTO {
        BangumiSubjectDTO(
            id: id,
            airtime: BangumiSubjectAirtime(date: airDate),
            eps: eps,
            name: name,
            nameCN: nameCN,
            type: subjectType,
            interest: BangumiSubjectInterest(
                comment: "", epStatus: epStatus, volStatus: 0, private: false, rate: 0,
                tags: [], type: collectionType,
                // collected_at 取自 interest.updatedAt，默认按 id 递减保证排序稳定
                updatedAt: collectedAt == 0 ? 1_000_000 - id : collectedAt)
        )
    }

    static func episode(
        id: Int,
        subjectID: Int,
        sort: Float,
        type: BangumiEpisodeType = .main,
        status: BangumiEpisodeCollectionType = .none,
        airdate: String = "2024-01-01"
    ) -> BangumiEpisodeDTO {
        BangumiEpisodeDTO(
            id: id,
            subjectID: subjectID,
            type: type,
            sort: sort,
            name: "EP\(sort)",
            nameCN: "",
            duration: "24m",
            airdate: airdate,
            comment: 0,
            disc: 0,
            collection: BangumiEpisodeCollectionStatus(status: status.rawValue, updatedAt: nil))
    }
}
