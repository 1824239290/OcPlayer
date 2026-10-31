import XCTest
@testable import MoviePilotKit

/// 详情页「先搜媒体 → 手动选源」的候选排序。
///
/// 这套打分存在的理由只有一条：**别让用户（或旧代码的自动挑选）拿到没有
/// `tmdb_id` 的条目**。所以这里的用例全是「同名多源回来，谁排在前面」，
/// 而不是展示层字段的宽容解析（那在 `MoviePilotModelsTests` / `MoviePilotSearchTests`）。
final class MoviePilotMediaRankingTests: XCTestCase {

    private func media(
        source: String,
        title: String = "Frieren",
        tmdb: Int? = nil,
        douban: String? = nil,
        bangumi: Int? = nil,
        year: String? = nil,
        type: String = "电视剧"
    ) -> MPMediaInfo {
        var raw: [String: JSONValue] = [
            "media_source": .string(source),
            "title": .string(title),
            "type": .string(type),
        ]
        if let tmdb {
            raw["tmdb_id"] = .number(Double(tmdb))
            raw["media_id"] = .string("tmdb:\(tmdb)")
        } else {
            raw["media_id"] = .string("\(source):\(title)")
        }
        if let douban { raw["douban_id"] = .string(douban) }
        if let bangumi { raw["bangumi_id"] = .number(Double(bangumi)) }
        if let year { raw["year"] = .string(year) }
        return MPMediaInfo(raw: raw)
    }

    // MARK: - 排序

    func testTMDBResultOutranksDoubanEvenWhenServerReturnsDoubanFirst() {
        let douban = media(source: "douban", douban: "35593344")
        let tmdb = media(source: "tmdb", tmdb: 209867)
        let ranked = MoviePilotMediaRanking.candidates([douban, tmdb])

        XCTAssertEqual(ranked.map(\.media.mediaSource), ["tmdb", "douban"])
        XCTAssertEqual(ranked.first?.isRecommended, true, "TMDB 源应当被推荐")
        XCTAssertEqual(ranked.last?.isRecommended, false, "缺 TMDB 编号的 Douban 条目不该被推荐")
        XCTAssertEqual(ranked.last?.isMissingTMDBID, true)
        XCTAssertEqual(ranked.first?.isMissingTMDBID, false)
    }

    func testExactTMDBIDMatchOutranksOtherTMDBResults() {
        let otherTMDB = media(source: "tmdb", tmdb: 111, year: "2019")
        let matched = media(source: "tmdb", tmdb: 222, year: "2023")
        let ranked = MoviePilotMediaRanking.candidates([otherTMDB, matched], year: 2023, tmdbID: "222")

        XCTAssertEqual(ranked.first?.media.tmdbId, 222)
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    func testYearAndTypeOnlyNudgeOrderButDoNotRecommend() {
        let wrongYear = media(source: "douban", douban: "1", year: "1999")
        let rightYear = media(source: "douban", douban: "2", year: "2023")
        let ranked = MoviePilotMediaRanking.candidates(
            [wrongYear, rightYear], year: 2023, type: "电视剧")

        XCTAssertEqual(ranked.first?.media.doubanId, "2")
        XCTAssertEqual(ranked.first?.isRecommended, false, "纯 Douban 候选不该被推荐（会缺 tmdb_id）")
        XCTAssertNil(
            MoviePilotMediaRanking.recommended([wrongYear, rightYear], year: 2023, type: "电视剧"),
            "没有 TMDB 源命中时不给推荐，选择权交给用户")
    }

    func testTiesKeepServerOrder() {
        let first = media(source: "douban", douban: "1")
        let second = media(source: "douban", douban: "2")
        let third = media(source: "douban", douban: "3")
        let ranked = MoviePilotMediaRanking.candidates([first, second, third])

        XCTAssertEqual(ranked.map(\.media.doubanId), ["1", "2", "3"])
        XCTAssertEqual(Set(ranked.map(\.score)).count, 1, "三条同分，排序必须只靠原序")
    }

    // MARK: - 推荐

    func testRecommendedPrefersTMDBSourceAndFallsBackToNil() {
        let douban = media(source: "douban", douban: "1")
        let tmdb = media(source: "tmdb", tmdb: 209867)
        XCTAssertEqual(MoviePilotMediaRanking.recommended([douban, tmdb])?.tmdbId, 209867)

        XCTAssertNil(MoviePilotMediaRanking.recommended([]), "空结果不该编出推荐")
        XCTAssertNil(MoviePilotMediaRanking.recommended([douban]))
    }

    // MARK: - 展示口径

    func testSourceSummaryNamesTheIdentifierThatWillBeSentBack() {
        let tmdb = media(source: "tmdb", tmdb: 209867)
        let douban = media(source: "douban", douban: "35593344")
        let bangumi = media(source: "bangumi", bangumi: 400602)
        let bare = media(source: "bangumi")

        XCTAssertEqual(
            MoviePilotMediaRanking.candidates([tmdb]).first?.sourceSummary,
            "来源 TMDB · TMDB 编号 209867")
        XCTAssertEqual(
            MoviePilotMediaRanking.candidates([douban]).first?.sourceSummary,
            "来源 DOUBAN · 豆瓣编号 35593344")
        XCTAssertEqual(
            MoviePilotMediaRanking.candidates([bangumi]).first?.sourceSummary,
            "来源 BANGUMI · Bangumi 编号 400602")
        XCTAssertEqual(
            MoviePilotMediaRanking.candidates([bare]).first?.sourceSummary,
            "来源 BANGUMI · 没有外部编号")
    }

    func testYearParsingAcceptsFullDateAndPrefersTitleYear() {
        var raw: [String: JSONValue] = [
            "media_source": .string("tmdb"),
            "tmdb_id": .number(1),
            "year": .string("2023"),
            "title_year": .string("2023-09-29"),
        ]
        let dated = MPMediaInfo(raw: raw)
        XCTAssertEqual(MoviePilotMediaRanking.year(of: dated), 2023)

        raw.removeValue(forKey: "title_year")
        XCTAssertEqual(MoviePilotMediaRanking.year(of: MPMediaInfo(raw: raw)), 2023)
        XCTAssertNil(MoviePilotMediaRanking.year(of: MPMediaInfo(raw: ["title": .string("x")])))
    }
}
