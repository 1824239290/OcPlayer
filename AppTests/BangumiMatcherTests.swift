import BangumiKit
import CoreModel
import XCTest
@testable import OcPlayer

@MainActor
final class BangumiMatcherTests: XCTestCase {

    // MARK: - 标题与季度解析测试

    func testNormalizeFullWidth() {
        let input = "１２３　ＡＢＣ：～！"
        let output = AnimeTitleParser.normalizeFullWidth(input)
        XCTAssertEqual(output, "123 ABC:~!")
    }

    func testReplaceChineseSeasonNumbers() {
        XCTAssertEqual(AnimeTitleParser.replaceChineseSeasonNumbers("进击的巨人 第二季"), "进击的巨人 第2季")
        XCTAssertEqual(AnimeTitleParser.replaceChineseSeasonNumbers("鬼灭之刃 第三期"), "鬼灭之刃 第3期")
        XCTAssertEqual(AnimeTitleParser.replaceChineseSeasonNumbers("某科学的超电磁炮 第一季度"), "某科学的超电磁炮 第1季")
    }

    func testReplaceRomanNumerals() {
        XCTAssertTrue(AnimeTitleParser.replaceRomanNumerals("约会大作战 IV").contains("4"))
        XCTAssertTrue(AnimeTitleParser.replaceRomanNumerals("约会大作战 Ⅳ").contains("4"))
        XCTAssertTrue(AnimeTitleParser.replaceRomanNumerals("Overlord II").contains("2"))
        XCTAssertTrue(AnimeTitleParser.replaceRomanNumerals("デート・ア・ライブIV").contains("4"))
    }

    func testParseSeasonNumbers() {
        let info1 = AnimeTitleParser.parse(title: "进击的巨人 第二季")
        XCTAssertEqual(info1.season, 2)
        XCTAssertEqual(info1.cleanBaseName, "进击的巨人")

        let info2 = AnimeTitleParser.parse(title: "進撃の巨人 Season 2")
        XCTAssertEqual(info2.season, 2)
        XCTAssertEqual(info2.cleanBaseName, "進撃の巨人")

        let info3 = AnimeTitleParser.parse(title: "进击的巨人 S2")
        XCTAssertEqual(info3.season, 2)
        XCTAssertEqual(info3.cleanBaseName, "进击的巨人")

        let info4 = AnimeTitleParser.parse(title: "吹响吧！上低音号 3")
        XCTAssertEqual(info4.season, 3)
        XCTAssertEqual(info4.cleanBaseName, "吹响吧上低音号")

        let info5 = AnimeTitleParser.parse(title: "约会大作战 Ⅳ")
        XCTAssertEqual(info5.season, 4)
        XCTAssertEqual(info5.cleanBaseName, "约会大作战")

        let info6 = AnimeTitleParser.parse(title: "某科学的超电磁炮S")
        XCTAssertEqual(info6.season, 2)

        let info7 = AnimeTitleParser.parse(title: "某科学的超电磁炮T")
        XCTAssertEqual(info7.season, 3)

        let info8 = AnimeTitleParser.parse(title: "进击的巨人 最终季")
        XCTAssertTrue(info8.isFinal)

        let info9 = AnimeTitleParser.parse(title: "進撃の巨人 The Final Season")
        XCTAssertTrue(info9.isFinal)

        let info10 = AnimeTitleParser.parse(title: "鬼灭之刃 游郭篇")
        XCTAssertEqual(info10.subtitle, "游郭篇")
        XCTAssertEqual(info10.cleanBaseName, "鬼灭之刃")

        let info11 = AnimeTitleParser.parse(title: "无职转生 ～到了异世界就拿出真本事～ 第2季")
        XCTAssertEqual(info11.season, 2)

        let info12 = AnimeTitleParser.parse(title: "我的青春恋爱物语果然有问题。完")
        XCTAssertTrue(info12.isFinal)

        let info13 = AnimeTitleParser.parse(title: "我的青春恋爱物语果然有问题。续")
        XCTAssertEqual(info13.season, 2)
    }

    // MARK: - 候选者打分算法测试

    private func makeSlimSubject(
        id: Int,
        name: String,
        nameCN: String,
        type: BangumiSubjectType
    ) -> BangumiSlimSubjectDTO {
        var subject = BangumiSlimSubjectDTO()
        subject.id = id
        subject.name = name
        subject.nameCN = nameCN
        subject.type = type
        return subject
    }

    func testAnimePrioritizedOverBookAndGame() {
        let query = AnimeTitleParser.parse(title: "败犬女主太多了！")

        let book = makeSlimSubject(
            id: 101,
            name: "負けヒロインが多すぎる！",
            nameCN: "败犬女主太多了！",
            type: .book
        )
        let anime = makeSlimSubject(
            id: 102,
            name: "負けヒロインが多すぎる！",
            nameCN: "败犬女主太多了！",
            type: .anime
        )

        let candidates = [book, anime]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 102, "动画条目应优先于同名书籍")
        XCTAssertEqual(best?.candidate.type, .anime)
    }

    func testSeason2DoesNotMatchSeason1() {
        let query = AnimeTitleParser.parse(title: "进击的巨人 第二季")

        let season1 = makeSlimSubject(
            id: 1,
            name: "進撃の巨人",
            nameCN: "进击的巨人",
            type: .anime
        )
        let season2 = makeSlimSubject(
            id: 2,
            name: "進撃の巨人 Season 2",
            nameCN: "进击的巨人 第二季",
            type: .anime
        )
        let season3 = makeSlimSubject(
            id: 3,
            name: "進撃の巨人 Season 3",
            nameCN: "进击的巨人 第三季",
            type: .anime
        )

        let candidates = [season1, season2, season3]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 2, "第 2 季应精确匹配第 2 季条目，而不是第 1 季或第 3 季")
    }

    func testSeason1DoesNotMatchSeason2() {
        let query = AnimeTitleParser.parse(title: "进击的巨人")

        let season2 = makeSlimSubject(
            id: 2,
            name: "進撃の巨人 Season 2",
            nameCN: "进击的巨人 第二季",
            type: .anime
        )
        let season1 = makeSlimSubject(
            id: 1,
            name: "進撃の巨人",
            nameCN: "进击的巨人",
            type: .anime
        )

        // 即使搜索结果中 Season 2 排在第一位，也应该正确选择 Season 1
        let candidates = [season2, season1]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 1, "第 1 季应匹配第 1 季条目")
    }

    func testFinalSeasonMatching() {
        let query = AnimeTitleParser.parse(title: "进击的巨人 最终季")

        let season1 = makeSlimSubject(
            id: 1,
            name: "進撃の巨人",
            nameCN: "进击的巨人",
            type: .anime
        )
        let finalSeason = makeSlimSubject(
            id: 4,
            name: "進撃の巨人 The Final Season",
            nameCN: "进击的巨人 最终季",
            type: .anime
        )

        let candidates = [season1, finalSeason]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 4, "最终季应匹配 Final Season")
    }

    func testSpecificArcSubtitleMatching() {
        let query = AnimeTitleParser.parse(title: "鬼灭之刃 游郭篇")

        let s1 = makeSlimSubject(
            id: 1,
            name: "鬼滅の刃",
            nameCN: "鬼灭之刃",
            type: .anime
        )
        let train = makeSlimSubject(
            id: 2,
            name: "鬼滅の刃 無限列車編",
            nameCN: "鬼灭之刃 无限列车篇",
            type: .anime
        )
        let yukaku = makeSlimSubject(
            id: 3,
            name: "鬼滅の刃 遊郭編",
            nameCN: "鬼灭之刃 游郭篇",
            type: .anime
        )

        let candidates = [s1, train, yukaku]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 3, "游郭篇应匹配游郭篇条目")
    }

    func testRomanNumeralSeasonMatching() {
        let query = AnimeTitleParser.parse(title: "约会大作战 Ⅳ")

        let s1 = makeSlimSubject(
            id: 1,
            name: "デート・ア・ライブ",
            nameCN: "约会大作战",
            type: .anime
        )
        let s4 = makeSlimSubject(
            id: 4,
            name: "デート・ア・ライブIV",
            nameCN: "约会大作战 第四季",
            type: .anime
        )

        let candidates = [s1, s4]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 4, "约会大作战 Ⅳ 应匹配第 4 季")
    }

    func testLetterSuffixSeasonMatching() {
        let query = AnimeTitleParser.parse(title: "某科学的超电磁炮S")

        let s1 = makeSlimSubject(
            id: 1,
            name: "とある科学の超電磁砲",
            nameCN: "某科学的超电磁炮",
            type: .anime
        )
        let s2 = makeSlimSubject(
            id: 2,
            name: "とある科学の超電磁砲S",
            nameCN: "某科学的超电磁炮S",
            type: .anime
        )
        let s3 = makeSlimSubject(
            id: 3,
            name: "とある科学の超電磁砲T",
            nameCN: "某科学的超电磁炮T",
            type: .anime
        )

        let candidates = [s1, s2, s3]
        let best = BangumiMatcher.pickBestCandidate(from: candidates, query: query)

        XCTAssertNotNil(best)
        XCTAssertEqual(best?.candidate.id, 2, "超电磁炮S 应匹配超电磁炮S")
    }

    // MARK: - 关联搜索关键词

    func testSeasonSearchTitles() {
        let series = MediaItem(id: "series", name: "中二病也要谈恋爱！", kind: .series)
        let cases: [(String, String)] = [
            ("中二病也要谈恋爱！ 恋", "中二病也要谈恋爱！ 恋"),
            ("  中二病也要谈恋爱！ 恋\n", "中二病也要谈恋爱！ 恋"),
            ("完全不同的当季标题", "完全不同的当季标题"),
            ("第2季", "中二病也要谈恋爱！ 第2季"),
            ("第二季", "中二病也要谈恋爱！ 第二季"),
            ("Season 2", "中二病也要谈恋爱！ Season 2"),
            ("2nd Season", "中二病也要谈恋爱！ 2nd Season"),
            ("S02", "中二病也要谈恋爱！ S02"),
            ("Season Ⅱ", "中二病也要谈恋爱！ Season Ⅱ"),
            ("最终季", "中二病也要谈恋爱！ 最终季"),
            ("\n ", "中二病也要谈恋爱！ 第2季"),
        ]
        for (name, expected) in cases {
            let season = MediaItem(id: "season", name: name, kind: .season, seasonNumber: 2)
            XCTAssertEqual(BangumiMatcher.searchTitle(for: series, season: season), expected, name)
        }
        XCTAssertEqual(BangumiMatcher.searchTitle(for: series), series.name)

        let arcSeries = MediaItem(id: "arc-series", name: "鬼灭之刃", kind: .series)
        let arcSeason = MediaItem(id: "arc-season", name: "游郭篇", kind: .season, seasonNumber: 2)
        XCTAssertEqual(BangumiMatcher.searchTitle(for: arcSeries, season: arcSeason), "鬼灭之刃 游郭篇")

        let episode = MediaItem(
            id: "episode", name: "第1集", kind: .episode, seriesName: series.name,
            seasonName: "中二病也要谈恋爱！ 恋", seasonNumber: 2)
        XCTAssertEqual(BangumiMatcher.searchTitle(for: episode), "中二病也要谈恋爱！ 恋")
    }

    func testManualSearchFallsBackOnlyAfterTitleHasNoResults() async throws {
        let recorder = SearchRecorder()
        let subject = makeSlimSubject(id: 2, name: "中二病でも恋がしたい！戀", nameCN: "中二病也要谈恋爱！ 恋", type: .anime)
        let results = try await BangumiMatcher.search(
            "中二病也要谈恋爱！ 恋", fallbackKeyword: "中二病也要谈恋爱！",
            search: { keyword, filter in
                recorder.record(filter: filter, keyword: keyword)
                return BangumiPagedDTO(data: keyword == "中二病也要谈恋爱！" ? [subject] : [], total: 1)
            })
        XCTAssertEqual(results.map(\.id), [2])
        XCTAssertEqual(recorder.keywords, ["中二病也要谈恋爱！ 恋", "中二病也要谈恋爱！ 恋", "中二病也要谈恋爱！"])
    }

    func testManualSearchKeepsSuccessfulSeasonTitle() async throws {
        let recorder = SearchRecorder()
        let subject = makeSlimSubject(id: 2, name: "中二病でも恋がしたい！戀", nameCN: "中二病也要谈恋爱！ 恋", type: .anime)
        let results = try await BangumiMatcher.search(
            subject.nameCN, fallbackKeyword: "中二病也要谈恋爱！",
            search: { keyword, filter in
                recorder.record(filter: filter, keyword: keyword)
                return BangumiPagedDTO(data: [subject], total: 1)
            })
        XCTAssertEqual(results.map(\.id), [2])
        XCTAssertEqual(recorder.keywords, [subject.nameCN])
    }

    func testManualSearchFailureDoesNotTriggerFallback() async {
        let recorder = SearchRecorder()
        do {
            _ = try await BangumiMatcher.search(
                "完整季标题", fallbackKeyword: "剧名",
                search: { keyword, filter in
                    recorder.record(filter: filter, keyword: keyword)
                    throw URLError(.notConnectedToInternet)
                })
            XCTFail("网络错误应继续抛出")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(recorder.keywords, ["完整季标题"])
    }

    func testAutoMatchFindsNamedSeasonWithoutNumericSuffix() async throws {
        let recorder = SearchRecorder()
        let series = MediaItem(id: "series", name: "中二病也要谈恋爱！", kind: .series)
        let season = MediaItem(id: "season", name: "中二病也要谈恋爱！ 恋", kind: .season, seasonNumber: 2)
        let first = makeSlimSubject(id: 1, name: "中二病でも恋がしたい！", nameCN: series.name, type: .anime)
        let second = makeSlimSubject(id: 2, name: "中二病でも恋がしたい！戀", nameCN: season.name, type: .anime)
        // 完整季名下也可能有多个候选；第一季和明确标着第三季的条目都不能胜出。
        let third = makeSlimSubject(id: 3, name: "中二病でも恋がしたい！戀 Season 3", nameCN: "中二病也要谈恋爱！ 恋 第3季", type: .anime)
        let result = try await BangumiMatcher.searchAndPick(for: series, season: season, search: { keyword, filter in
            recorder.record(filter: filter, keyword: keyword)
            return BangumiPagedDTO(data: keyword == season.name ? [first, third, second] : [first], total: 3)
        })
        XCTAssertEqual(result?.id, second.id)
        XCTAssertEqual(Set(recorder.keywords), Set([season.name, series.name]))

        let conflictOnly = try await BangumiMatcher.searchAndPick(for: series, season: season, search: { _, _ in
            BangumiPagedDTO(data: [third], total: 1)
        })
        XCTAssertNil(conflictOnly, "相似完整标题不能覆盖候选明确写出的季数冲突")
    }

    func testAutoMatchGenericSeasonKeepsSeasonNumberConstraint() async throws {
        let series = MediaItem(id: "series", name: "进击的巨人", kind: .series)
        let season = MediaItem(id: "season", name: "Season 2", kind: .season, seasonNumber: 2)
        let first = makeSlimSubject(id: 1, name: "進撃の巨人", nameCN: series.name, type: .anime)
        let second = makeSlimSubject(id: 2, name: "進撃の巨人 Season 2", nameCN: "进击的巨人 第二季", type: .anime)
        let result = try await BangumiMatcher.searchAndPick(for: series, season: season, search: { _, _ in
            BangumiPagedDTO(data: [first, second], total: 2)
        })
        XCTAssertEqual(result?.id, second.id)

        let fallbackOnly = try await BangumiMatcher.searchAndPick(for: series, season: season, search: { _, _ in
            BangumiPagedDTO(data: [first], total: 1)
        })
        XCTAssertNil(fallbackOnly, "剧名回退不能把第一季关联成第二季")
    }

    // MARK: - 第二轮「放开类型过滤」的触发条件

    /// 回归：**关键词请求全部失败时，不该再发第二轮注定失败的请求**。
    ///
    /// 第二轮用的是同一批关键词、只是把 `filter` 从 `.anime` 换成 `nil`，所以网关
    /// 全挂 / 断网时它必然也全失败 —— 唯一效果是把等待翻倍（每轮 ≈ 关键词数 × 10 s
    /// 超时）。判据必须是「**至少有一个请求真的到达了服务端**」，而不是
    /// `lastError == nil`：部分成功 + 部分失败时 `lastError` 也非空，而那一轮放开
    /// 类型过滤仍可能命中真人剧（见下一条用例）。
    @MainActor
    func testAllSearchesFailingSkipsTypeFilterRound() async {
        let recorder = SearchRecorder()
        let item = MediaItem(id: "movie-offline", name: "某部不存在的电影", kind: .movie)

        var thrown: Error?
        do {
            _ = try await BangumiMatcher.searchAndPick(for: item, search: { _, filter in
                recorder.record(filter: filter)
                throw URLError(.notConnectedToInternet)
            })
            XCTFail("全部失败应当抛出，而不是返回 nil —— 后者会被 UI 读成「没找到」")
        } catch {
            thrown = error
        }

        XCTAssertNotNil(thrown, "全部失败要抛出")
        XCTAssertGreaterThan(recorder.count, 0, "第一轮本来就该发出去")
        XCTAssertFalse(
            recorder.didSearchWithoutTypeFilter,
            "全部失败时不该再发第二轮（放开类型过滤那次）")
    }

    /// 反证：**部分失败**（有的关键词到达了服务端）时，第二轮仍要发。
    /// 这一条守的是「别把守卫收得太紧」——拿 `lastError == nil` 当判据会漏掉这种情形。
    @MainActor
    func testPartialFailureStillAllowsTypeFilterRound() async {
        let recorder = SearchRecorder()
        let item = MediaItem(id: "movie-partial", name: "某部不存在的电影 Season 2", kind: .movie)

        _ = try? await BangumiMatcher.searchAndPick(for: item, search: { _, filter in
            let seen = recorder.record(filter: filter)
            // 只让第一发失败：模拟「部分关键词没到达服务端」
            if filter == .anime, seen == 1 {
                throw URLError(.timedOut)
            }
            return BangumiPagedDTO(data: [], total: 0)
        })

        XCTAssertTrue(
            recorder.didSearchWithoutTypeFilter,
            "有过成功请求 ⇒ 候选为空时仍要放开类型过滤再试一轮")
    }
}

/// 记录注入检索被调用的次数，以及**有没有出现过 `filter == nil` 那一次**
/// （= 第二轮「放开类型过滤」是否真的发了）。
///
/// 判据取「有没有发过 nil 过滤」而不是「发了几次」：次数会随关键词生成规则变动
/// （无季号条目 2 条、带季号 3 条），而「第二轮发没发」才是这两条用例要钉的。
/// 注入的闭包跑在 `withTaskGroup` 里，所以要自己上锁。
private final class SearchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var sawUnfiltered = false
    private var searchedKeywords: [String] = []

    /// 返回这是第几次调用（从 1 开始）。
    @discardableResult
    func record(filter: BangumiSubjectType?, keyword: String? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if let keyword { searchedKeywords.append(keyword) }
        if filter == nil { sawUnfiltered = true }
        return callCount
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var keywords: [String] {
        lock.lock()
        defer { lock.unlock() }
        return searchedKeywords
    }

    var didSearchWithoutTypeFilter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawUnfiltered
    }
}
