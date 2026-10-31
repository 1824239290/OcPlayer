import XCTest
@testable import MoviePilotKit

/// `/media/search` 结果的展示排序。
///
/// 这套排序存在的理由只有一条：**别让 Douban 条目排在最前面挡住 TMDB 那条**。
/// 挑到没有 `tmdb_id` 的条目时，它会原样回传给 `/download/`，MoviePilot 下载
/// 完成后的自动刮削就缺编号。所以用例全是「同名多源回来，谁排在前面」。
final class MoviePilotMediaRankingTests: XCTestCase {

    private func media(
        source: String,
        title: String = "Frieren",
        tmdb: Int? = nil,
        douban: String? = nil
    ) -> MPMediaInfo {
        var raw: [String: JSONValue] = [
            "media_source": .string(source),
            "title": .string(title),
        ]
        if let tmdb {
            raw["tmdb_id"] = .number(Double(tmdb))
            raw["media_id"] = .string("tmdb:\(tmdb)")
        } else {
            raw["media_id"] = .string("\(source):\(title)")
        }
        if let douban { raw["douban_id"] = .string(douban) }
        return MPMediaInfo(raw: raw)
    }

    func testTMDBSourceOutranksDoubanEvenWhenServerReturnsDoubanFirst() {
        let douban = media(source: "douban", douban: "35593344")
        let tmdb = media(source: "tmdb", tmdb: 209867)

        let sorted = MoviePilotMediaRanking.sortedForDisplay([douban, tmdb])
        XCTAssertEqual(sorted.map(\.mediaSource), ["tmdb", "douban"])
        XCTAssertEqual(sorted.first?.tmdbId, 209867)
    }

    /// 服务端本来就排对了的时候不能被排乱（幂等）。
    func testAlreadySortedInputIsUnchanged() {
        let tmdb = media(source: "tmdb", tmdb: 1)
        let douban = media(source: "douban", douban: "2")
        XCTAssertEqual(
            MoviePilotMediaRanking.sortedForDisplay([tmdb, douban]).map(\.mediaSource),
            ["tmdb", "douban"])
    }

    /// 两个都不是 TMDB 源时，带 `tmdb_id` 的在前（个别源的适配器会补齐编号）。
    func testNonTMDBResultWithIdentifierRanksHigher() {
        let bare = media(source: "bangumi")
        let enriched = MPMediaInfo(raw: [
            "media_source": .string("douban"),
            "title": .string("Frieren"),
            "douban_id": .string("3"),
            "tmdb_id": .number(4242),
        ])

        let sorted = MoviePilotMediaRanking.sortedForDisplay([bare, enriched])
        XCTAssertEqual(sorted.first?.tmdbId, 4242)
        XCTAssertGreaterThan(
            MoviePilotMediaRanking.score(enriched),
            MoviePilotMediaRanking.score(bare),
            "带 tmdb_id 的条目应当排在没有任何编号的条目前面")
    }

    /// 同分必须保持服务端原序（`sorted` 本身不保证稳定性，这里钉住显式下标比较）。
    func testTiesKeepServerOrder() {
        let first = media(source: "douban", douban: "1")
        let second = media(source: "douban", douban: "2")
        let third = media(source: "douban", douban: "3")

        XCTAssertEqual(
            MoviePilotMediaRanking.sortedForDisplay([first, second, third]).map(\.doubanId),
            ["1", "2", "3"])
        XCTAssertEqual(
            Set([first, second, third].map(MoviePilotMediaRanking.score)).count, 1,
            "三条同分，排序必须只靠原序")
    }

    func testEmptyInputIsEmpty() {
        XCTAssertTrue(MoviePilotMediaRanking.sortedForDisplay([]).isEmpty)
    }

    /// 排序**只**调整顺序，不增删条目、不改内容——每张卡都是服务端返回的完整对象。
    func testSortingDoesNotAlterMediaObjects() {
        let douban = media(source: "douban", douban: "35593344")
        let tmdb = media(source: "tmdb", tmdb: 209867)
        let sorted = MoviePilotMediaRanking.sortedForDisplay([douban, tmdb])

        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(Set(sorted.map(\.id)), Set([douban.id, tmdb.id]))
        XCTAssertEqual(sorted.first { $0.mediaSource == "tmdb" }, tmdb)
    }
}
