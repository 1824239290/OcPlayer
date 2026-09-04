import XCTest
@testable import DanmakuKit

final class DanmakuFilenameParserTests: XCTestCase {

    func testNormalizeFullWidth() {
        let input = "【ＮＣ－Ｒａｗｓ】　葬送的芙莉莲　０１"
        let output = DanmakuFilenameParser.normalizeFullWidth(input)
        XCTAssertEqual(output, "【NC-Raws】 葬送的芙莉莲 01")
    }

    func testStandardReleaseGroupsWithEpisode() {
        // [NC-Raws] 葬送的芙莉莲 - 01 (B-Global 1920x1080 HEVC AAC MKV) [9C874A2B].mkv
        let r1 = DanmakuFilenameParser.parse("[NC-Raws] 葬送的芙莉莲 - 01 (B-Global 1920x1080 HEVC AAC MKV) [9C874A2B].mkv")
        XCTAssertEqual(r1.title, "葬送的芙莉莲")
        XCTAssertEqual(r1.episodeNumber, 1)

        // [Lilith-Raws] Sousou no Frieren - 02 [Baha][1080p][AVC AAC][CHT].mp4
        let r2 = DanmakuFilenameParser.parse("[Lilith-Raws] Sousou no Frieren - 02 [Baha][1080p][AVC AAC][CHT].mp4")
        XCTAssertEqual(r2.title, "Sousou no Frieren")
        XCTAssertEqual(r2.episodeNumber, 2)

        // 【喵萌奶茶屋】★04月新番★[吹响吧！上低音号3_Hibike! Euphonium 3][03][1080p][简日双语].mp4
        let r3 = DanmakuFilenameParser.parse("【喵萌奶茶屋】★04月新番★[吹响吧！上低音号3_Hibike! Euphonium 3][03][1080p][简日双语].mp4")
        XCTAssertTrue(r3.title.contains("吹响吧") && r3.title.contains("上低音号3"))
        XCTAssertEqual(r3.episodeNumber, 3)
    }

    func testSeasonAndEpisodePatterns() {
        // Frieren.S01E05.1080p.mkv
        let r1 = DanmakuFilenameParser.parse("Frieren.S01E05.1080p.mkv")
        XCTAssertEqual(r1.title, "Frieren")
        XCTAssertEqual(r1.seasonNumber, 1)
        XCTAssertEqual(r1.episodeNumber, 5)

        // 进击的巨人 Season 2 - 04.mp4
        let r2 = DanmakuFilenameParser.parse("进击的巨人 Season 2 - 04.mp4")
        XCTAssertEqual(r2.title, "进击的巨人")
        XCTAssertEqual(r2.seasonNumber, 2)
        XCTAssertEqual(r2.episodeNumber, 4)

        // 进击的巨人 第二季 第06话.mkv
        let r3 = DanmakuFilenameParser.parse("进击的巨人 第二季 第06话.mkv")
        XCTAssertEqual(r3.seasonNumber, 2)
        XCTAssertEqual(r3.episodeNumber, 6)

        // 进击的巨人 The Final Season 01.mkv
        let r4 = DanmakuFilenameParser.parse("进击的巨人 The Final Season 01.mkv")
        XCTAssertTrue(r4.isFinal)
        XCTAssertEqual(r4.episodeNumber, 1)
    }

    func testSimpleGenericFiles() {
        let r1 = DanmakuFilenameParser.parse("01.mp4")
        XCTAssertEqual(r1.episodeNumber, 1)

        let r2 = DanmakuFilenameParser.parse("S01E12.mkv")
        XCTAssertEqual(r2.seasonNumber, 1)
        XCTAssertEqual(r2.episodeNumber, 12)
    }

    /// 枚举外发布组（VCB-Studio）：行首方括号 + 全名另有括号组 → 按发布组位剥除。
    func testUnlistedReleaseGroupLeadingSlotIsStripped() {
        let r = DanmakuFilenameParser.parse("[VCB-Studio] 葬送的芙莉莲 - 01 [Ma10p][1080p].mkv")
        XCTAssertEqual(r.title, "葬送的芙莉莲")
        XCTAssertEqual(r.episodeNumber, 1)
    }

    /// 防误伤：全名只有单个方括号组时首槽视为标题本身，不得剥除。
    func testSingleBracketSlotIsKeptAsTitle() {
        let r = DanmakuFilenameParser.parse("[Frieren] 02.mp4")
        XCTAssertEqual(r.title, "Frieren")
        XCTAssertEqual(r.episodeNumber, 2)
    }

    /// 年份括号（如 [2023]）按年份剥除，不进标题。
    func testYearBracketIsStripped() {
        let r = DanmakuFilenameParser.parse("葬送的芙莉莲 [2023] - 01.mp4")
        XCTAssertEqual(r.title, "葬送的芙莉莲")
        XCTAssertEqual(r.episodeNumber, 1)
    }
}
