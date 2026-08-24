import MoviePilotKit
import XCTest
@testable import OcPlayer

/// 种子筛选 / 排序 / 候选聚合（对齐 MP 网页端 useTorrentFilter 的语义）。
final class TorrentFilterTests: XCTestCase {

    private static func torrent(
        _ fields: [String: JSONValue], meta: [String: JSONValue] = [:]
    ) -> MPTorrent {
        MPTorrent(raw: fields, meta: meta)
    }

    private static let sample: [MPTorrent] = [
        torrent(
            ["site_name": .string("萝莉"), "size": .number(100), "seeders": .number(5),
             "volume_factor": .string("免费"), "pri_order": .number(1),
             "enclosure": .string("a"), "pubdate": .string("2026-08-14 03:25:15")],
            meta: ["resource_pix": .string("1080p"), "resource_team": .string("OurBits"),
                   "season_episode": .string("S01")]),
        torrent(
            ["site_name": .string("馒头"), "size": .number(300), "seeders": .number(20),
             "volume_factor": .string("普通"), "pri_order": .number(2),
             "enclosure": .string("b"), "pubdate": .string("2026-08-20 10:00:00")],
            meta: ["resource_pix": .string("2160p"), "video_encode": .string("AV1"),
                   "season_episode": .string("S01E05")]),
        // 字段缺失的条目：有对应筛选时应被排除。
        torrent(
            ["site_name": .string("萝莉"), "size": .number(200), "seeders": .number(9),
             "pri_order": .number(3), "enclosure": .string("c")],
            meta: [:]),
    ]

    func testEmptyFiltersPassEverything() {
        XCTAssertEqual(TorrentFilterEngine.filtered(Self.sample, filters: TorrentFilters()).count, 3)
    }

    func testExactMatchSemantics() {
        var filters = TorrentFilters()
        filters.site = ["萝莉"]
        XCTAssertEqual(TorrentFilterEngine.filtered(Self.sample, filters: filters).count, 2)

        // 促销筛 volume_factor；无该字段的条目被排除。
        filters = TorrentFilters()
        filters.freeState = ["免费"]
        XCTAssertEqual(TorrentFilterEngine.filtered(Self.sample, filters: filters).count, 1)

        // 分辨率筛 meta.resource_pix。
        filters = TorrentFilters()
        filters.resolution = ["2160p"]
        XCTAssertEqual(TorrentFilterEngine.filtered(Self.sample, filters: filters).count, 1)

        // 条件之间 AND。
        filters = TorrentFilters()
        filters.site = ["馒头"]
        filters.resolution = ["2160p"]
        XCTAssertEqual(TorrentFilterEngine.filtered(Self.sample, filters: filters).count, 1)
        filters.resolution = ["1080p"]
        XCTAssertEqual(TorrentFilterEngine.filtered(Self.sample, filters: filters).count, 0)
    }

    func testSortFieldsAndDirection() {
        XCTAssertEqual(
            TorrentFilterEngine.sorted(Self.sample, field: .size, ascending: true)
                .map(\.size),
            [100, 200, 300]
        )
        XCTAssertEqual(
            TorrentFilterEngine.sorted(Self.sample, field: .seeder, ascending: false)
                .map(\.seeders),
            [20, 9, 5]
        )
        XCTAssertEqual(
            TorrentFilterEngine.sorted(Self.sample, field: .publishTime, ascending: false)
                .map(\.id),
            ["b", "a", "c"]
        )
        XCTAssertEqual(
            TorrentFilterEngine.sorted(Self.sample, field: .defaultOrder, ascending: true)
                .map(\.id),
            ["a", "b", "c"]
        )
    }

    func testSortIsStableOnTies() {
        let tied = [
            Self.torrent(["seeders": .number(1), "enclosure": .string("x1")]),
            Self.torrent(["seeders": .number(1), "enclosure": .string("x2")]),
            Self.torrent(["seeders": .number(1), "enclosure": .string("x3")]),
        ]
        XCTAssertEqual(
            TorrentFilterEngine.sorted(tied, field: .seeder, ascending: false)
                .map(\.id),
            ["x1", "x2", "x3"],
            "同值保持原顺序"
        )
    }

    func testOptionsAggregationAndSeasonOrdering() {
        let options = TorrentFilterEngine.options(Self.sample)
        XCTAssertEqual(options.site, ["馒头", "萝莉"].sorted())
        XCTAssertEqual(options.freeState, ["免费", "普通"].sorted())
        XCTAssertEqual(options.season.first, "S01", "整季排在单集前面")
        XCTAssertTrue(options.season.contains("S01E05"))
        XCTAssertEqual(options.videoCode, ["AV1"])
        XCTAssertEqual(options.releaseGroup, ["OurBits"])
    }
}
