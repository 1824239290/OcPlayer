import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 匹配器：优先级、打分分档、以及**集/季的 tmdbID 陷阱**。
final class TMDbMatcherTests: XCTestCase {

    // MARK: - 夹具

    private func item(
        id: String = "i1",
        name: String,
        kind: MediaItem.Kind = .series,
        year: Int? = nil,
        originalTitle: String? = nil,
        tmdbID: String? = nil,
        seriesID: String? = nil,
        seasonNumber: Int? = nil,
        seriesName: String? = nil
    ) -> MediaItem {
        var item = MediaItem(id: id, name: name, kind: kind)
        item.year = year
        item.originalTitle = originalTitle
        item.tmdbID = tmdbID
        item.seriesID = seriesID
        item.seasonNumber = seasonNumber
        item.seriesName = seriesName
        return item
    }

    private func matcher(
        results: [TMDbSearchResult] = [],
        recorder: (@Sendable (String, TMDbMediaType, Int?, String) -> Void)? = nil
    ) -> TMDbMatcher {
        TMDbMatcher(language: "zh-CN") { query, type, year, language in
            recorder?(query, type, year, language)
            return results
        }
    }

    // MARK: - ProviderIds 优先

    func testProviderIDWinsWithFullConfidence() async throws {
        let m = await matcher(results: []).match(
            item: item(name: "黑客帝国", kind: .movie, tmdbID: "603"),
            seriesLink: nil)
        XCTAssertEqual(m?.entityKey, .movie(603))
        XCTAssertEqual(m?.source, .providerID)
        XCTAssertEqual(m?.confidence, 1.0)
        XCTAssertTrue(m?.shouldApplyAutomatically == true)
    }

    func testTVProviderIDMakesTVKey() async throws {
        let m = await matcher().match(item: item(name: "权力的游戏", tmdbID: "1399"), seriesLink: nil)
        XCTAssertEqual(m?.entityKey, .tv(1399))
    }

    /// 脏 `ProviderIds`（空串 / 0 / 非数字 / 空白）必须当「没有」，否则会拿 0 去查
    /// TMDb 得到 404，日志里表现为「明明有 id 却查不到」，很难查。
    func testDirtyProviderIDsAreIgnored() async throws {
        let m = TMDbMatcher(language: "zh-CN") { _, _, _, _ in [] }
        for dirty in ["", " ", "0", "-5", "abc", "12.5", "\n"] {
            let value = await m.providerTmdbID(of: item(name: "x", tmdbID: dirty))
            XCTAssertNil(value, "「\(dirty)」应被当作没有 id")
        }
        let clean = await m.providerTmdbID(of: item(name: "x", tmdbID: " 603 "))
        XCTAssertEqual(clean, 603, "前后空白应被容忍")
    }

    // MARK: - 集 / 季：不许用自己的 tmdbID

    /// **本文件最要紧的用例**：集带一个「单集 TMDb id」，它**不是剧集 id**。
    /// 若拿它去查 `/tv/{id}` 会拉到另一部剧或 404（实测 S1E1 的 Tmdb=3384539
    /// 而剧集 id 是 153217）。
    func testEpisodeUsesSeriesLinkNotItsOwnTmdbID() async throws {
        let episode = item(
            id: "e1", name: "电气少年", kind: .episode,
            tmdbID: "3384539",                       // ← 单集 id，绝不能直接用
            seriesID: "s1", seasonNumber: 1, seriesName: "二十世纪电气目录")
        let seriesLink = TMDbLink(itemID: "s1", entityKey: .tv(153217),
                                  source: .providerID, confidence: 1.0, linkedAt: Date())

        let m = await matcher().match(item: episode, seriesLink: seriesLink)

        XCTAssertEqual(m?.entityKey, .season(tvID: 153217, number: 1),
                       "必须用父剧 id 推导，而不是集自己的 3384539")
        XCTAssertNotEqual(m?.entityKey.tmdbID, 3384539)
    }

    /// 季同理：实测季级 ProviderIds **只有 Tvdb、没有 Tmdb**，所以也只能从父剧推导。
    func testSeasonUsesSeriesLink() async throws {
        let season = item(id: "se1", name: "第 1 季", kind: .season,
                          seriesID: "s1", seasonNumber: 1, seriesName: "败犬女主太多了！")
        let link = TMDbLink(itemID: "s1", entityKey: .tv(241535),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        let m = await matcher().match(item: season, seriesLink: link)
        XCTAssertEqual(m?.entityKey, .season(tvID: 241535, number: 1))
    }

    /// 没有父剧对应时，集/季**不做标题搜索**（它们的标题是分集名，搜出来必错）。
    func testEpisodeWithoutSeriesLinkDoesNotFallBackToSearch() async throws {
        let searched = Flag()
        let episode = item(id: "e1", name: "电气少年", kind: .episode,
                           tmdbID: "3384539", seasonNumber: 1)
        let m = TMDbMatcher(language: "zh-CN") { _, _, _, _ in
            searched.set()
            return []
        }
        let result = await m.match(item: episode, seriesLink: nil)
        XCTAssertNil(result)
        XCTAssertFalse(searched.value, "不该为分集名打搜索请求")
    }

    /// 季缺季号时也放弃（无法定位 `/season/{n}`）。
    func testSeasonWithoutNumberGivesUp() async throws {
        let season = item(id: "se1", name: "第 1 季", kind: .season, seriesID: "s1")
        let link = TMDbLink(itemID: "s1", entityKey: .tv(1),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        let m = await matcher().match(item: season, seriesLink: link)
        XCTAssertNil(m)
    }

    // MARK: - 搜索打分

    func testExactTitleAndYearIsAutoApplied() async throws {
        let results = [TMDbSearchResult(id: 603, mediaType: .movie, title: "黑客帝国",
                                        originalTitle: "The Matrix", year: 1999)]
        let m = await matcher(results: results).match(
            item: item(name: "黑客帝国", kind: .movie, year: 1999), seriesLink: nil)
        XCTAssertEqual(m?.entityKey, .movie(603))
        XCTAssertEqual(m?.confidence ?? 0, 0.95, accuracy: 0.001)
        XCTAssertTrue(m?.shouldApplyAutomatically == true)
    }

    /// 标题对但**年份明显不符** → 压到很低、不自动应用（多半是翻拍/重名）。
    func testExactTitleButWrongYearIsNotAutoApplied() async throws {
        let results = [TMDbSearchResult(id: 1, mediaType: .movie, title: "黑客帝国", year: 2021)]
        let m = await matcher(results: results).match(
            item: item(name: "黑客帝国", kind: .movie, year: 1999), seriesLink: nil)
        XCTAssertEqual(m?.confidence ?? 0, 0.4, accuracy: 0.001)
        XCTAssertFalse(m?.shouldApplyAutomatically == true)
    }

    /// 差 1 年（跨年首播）→ 0.8，仍不自动（阈值 0.85）。
    func testYearOffByOneIsNotAutoApplied() async throws {
        let results = [TMDbSearchResult(id: 2, mediaType: .tv, title: "某剧", year: 2020)]
        let m = await matcher(results: results).match(
            item: item(name: "某剧", year: 2021), seriesLink: nil)
        XCTAssertEqual(m?.confidence ?? 0, 0.8, accuracy: 0.001)
        XCTAssertFalse(m?.shouldApplyAutomatically == true, "阈值之上才自动，0.8 不够")
    }

    /// 缺年份无法排除重名 → 0.7，不自动。
    func testMissingYearIsNotAutoApplied() async throws {
        let results = [TMDbSearchResult(id: 3, mediaType: .tv, title: "某剧", year: nil)]
        let m = await matcher(results: results).match(
            item: item(name: "某剧", year: 2021), seriesLink: nil)
        XCTAssertEqual(m?.confidence ?? 0, 0.7, accuracy: 0.001)
        XCTAssertFalse(m?.shouldApplyAutomatically == true)
    }

    /// 标题完全不相干 → 0.1，连候选都算不上（但仍会被返回为「最像的」，
    /// 因为它不自动应用，调用方可据此展示手动面板）。
    func testUnrelatedTitleScoresLow() async throws {
        let results = [TMDbSearchResult(id: 9, mediaType: .movie, title: "完全无关的片子", year: 1999)]
        let m = await matcher(results: results).match(
            item: item(name: "黑客帝国", kind: .movie, year: 1999), seriesLink: nil)
        XCTAssertEqual(m?.confidence ?? 0, 0.1, accuracy: 0.001)
        XCTAssertFalse(m?.shouldApplyAutomatically == true)
    }

    /// 原名命中也算（用户库里存的可能是原名）。中文译名在 TMDb 索引里常查不到。
    func testOriginalTitleMatchCounts() async throws {
        let results = [TMDbSearchResult(id: 603, mediaType: .movie, title: "黑客帝国",
                                        originalTitle: "The Matrix", year: 1999)]
        let m = await matcher(results: results).match(
            item: item(name: "The Matrix", kind: .movie, year: 1999), seriesLink: nil)
        XCTAssertEqual(m?.confidence ?? 0, 0.95, accuracy: 0.001)
    }

    /// 中文译名搜不到时，用 `originalTitle` 再搜一次（只在首次没选出可自动应用的
    /// 候选时才多打这一趟）。
    func testFallsBackToOriginalTitleSearch() async throws {
        let queries = Recorder()
        let m = TMDbMatcher(language: "zh-CN") { query, _, _, _ in
            queries.append(query)
            // 中文搜不到，原名能搜到
            return query == "Sparks of Tomorrow"
                ? [TMDbSearchResult(id: 100, mediaType: .tv, title: "二十世纪电气目录",
                                    originalTitle: "Sparks of Tomorrow", year: 2026)]
                : []
        }
        let result = await m.match(
            item: item(name: "二十世纪电气目录", kind: .series, year: 2026,
                       originalTitle: "Sparks of Tomorrow"),
            seriesLink: nil)

        XCTAssertEqual(queries.values, ["二十世纪电气目录", "Sparks of Tomorrow"])
        XCTAssertEqual(result?.entityKey, .tv(100))
        XCTAssertTrue(result?.shouldApplyAutomatically == true)
    }

    /// 首次就搜到了可信结果时**不该**再搜原名（省一次请求）。
    func testDoesNotSearchOriginalWhenPrimarySucceeds() async throws {
        let queries = Recorder()
        let m = TMDbMatcher(language: "zh-CN") { query, _, _, _ in
            queries.append(query)
            return [TMDbSearchResult(id: 1, mediaType: .tv, title: "某剧", year: 2020)]
        }
        _ = await m.match(item: item(name: "某剧", kind: .series, year: 2020,
                                     originalTitle: "Some Show"), seriesLink: nil)
        XCTAssertEqual(queries.values, ["某剧"], "已可自动应用，不该再搜原名")
    }

    /// 候选排序：取分最高者，其余进 `alternatives`（供手动面板）。
    func testPicksHighestScoringCandidateAndKeepsAlternatives() async throws {
        let results = [
            TMDbSearchResult(id: 1, mediaType: .tv, title: "某剧", year: 2015),   // 年份不符 0.4
            TMDbSearchResult(id: 2, mediaType: .tv, title: "某剧", year: 2020),   // 精确 0.95
            TMDbSearchResult(id: 3, mediaType: .tv, title: "某剧 第二季", year: 2021),
        ]
        let m = await matcher(results: results).match(
            item: item(name: "某剧", year: 2020), seriesLink: nil)
        XCTAssertEqual(m?.entityKey, .tv(2))
        XCTAssertFalse(m?.alternatives.isEmpty == true)
    }

    func testSearchDisabledSkipsNetwork() async throws {
        let searched = Flag()
        let m = TMDbMatcher(language: "zh-CN") { _, _, _, _ in
            searched.set()
            return [TMDbSearchResult(id: 1, mediaType: .tv, title: "某剧", year: 2020)]
        }
        let result = await m.match(item: item(name: "某剧", year: 2020), seriesLink: nil,
                                   allowSearch: false)
        XCTAssertNil(result)
        XCTAssertFalse(searched.value)
    }

    // MARK: - 标题归一化

    func testTitleNormalizationIgnoresPunctuationAndCase() {
        XCTAssertEqual(TitleNormalizer.normalize("The Matrix"), TitleNormalizer.normalize("the matrix"))
        XCTAssertEqual(TitleNormalizer.normalize("黑客帝国：矩阵重启"),
                       TitleNormalizer.normalize("黑客帝国 矩阵重启"))
        XCTAssertEqual(TitleNormalizer.normalize("Spider-Man"), TitleNormalizer.normalize("spider man"))
    }

    func testTitleNormalizationStripsSeasonSuffix() {
        XCTAssertEqual(TitleNormalizer.normalize("阿松 第二季").contains("第二季"), false)
        XCTAssertEqual(TitleNormalizer.normalize("Some Show Season 2"),
                       TitleNormalizer.normalize("Some Show"))
    }

    /// **不剥数字差异**：把「阿松」和「阿松 2」归一成同一个是本类最该避免的错误。
    func testTitleNormalizationKeepsDistinguishingNumbers() {
        XCTAssertNotEqual(TitleNormalizer.normalize("阿松 2"), TitleNormalizer.normalize("阿松"))
        XCTAssertNotEqual(TitleNormalizer.normalize("机动战士高达 00"),
                          TitleNormalizer.normalize("机动战士高达"))
    }

    /// 服务端没给 `year` 字段、但标题里带年份时，**搜索要带上年份**。
    ///
    /// 不带年份的搜索会把同名作品（重名/翻拍/特别篇）混在一起，打分只能靠标题精确度
    /// 硬扛；实测库里确实有「年份写在标题里」的条目。
    func testSearchUsesYearFromTitleWhenFieldMissing() async throws {
        let years = Recorder()
        let m = TMDbMatcher(language: "zh-CN") { _, _, year, _ in
            years.append(year.map(String.init) ?? "nil")
            return [TMDbSearchResult(id: 1, mediaType: .movie, title: "某片", year: 2019)]
        }
        _ = await m.match(item: item(name: "某片 (2019)", kind: .movie), seriesLink: nil)
        XCTAssertEqual(years.values.first, "2019", "应从标题里认出 2019 并带上")
    }

    /// 服务端字段优先于标题里的年份（字段是结构化数据，更可信）。
    func testServerYearWinsOverTitleYear() async throws {
        let years = Recorder()
        let m = TMDbMatcher(language: "zh-CN") { _, _, year, _ in
            years.append(year.map(String.init) ?? "nil")
            return [TMDbSearchResult(id: 1, mediaType: .movie, title: "某片", year: 2021)]
        }
        _ = await m.match(item: item(name: "某片 (2019)", kind: .movie, year: 2021), seriesLink: nil)
        XCTAssertEqual(years.values.first, "2021")
    }

    func testYearExtractionFromTitle() {
        XCTAssertEqual(TitleNormalizer.year(fromTitle: "某片 (2019)"), 2019)
        XCTAssertEqual(TitleNormalizer.year(fromTitle: "某片（2019）"), 2019)
        XCTAssertNil(TitleNormalizer.year(fromTitle: "某片"))
        XCTAssertNil(TitleNormalizer.year(fromTitle: "某片 (19)"))
    }
}

// MARK: - 小工具

/// 记录调用（用于断言「有没有发这次请求」）。
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
}
