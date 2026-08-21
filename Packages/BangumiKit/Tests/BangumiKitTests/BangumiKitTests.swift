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
