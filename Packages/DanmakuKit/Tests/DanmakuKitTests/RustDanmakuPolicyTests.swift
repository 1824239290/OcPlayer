import Foundation
import XCTest
@testable import DanmakuKit

final class RustDanmakuPolicyTests: XCTestCase {
    private func requireCore() throws {
        guard RustDanmakuPolicy.active != nil else { throw XCTSkip("Enable Core for native policy differential checks") }
    }
    func testFilenameAndCanonicalPolicyAgainstNativeCorpus() throws {
        try requireCore()
        let names = ["Frieren", "葬送的芙莉莲", "吹响吧！上低音号3", "进击的巨人 第二季", "Show The Final Season", "Re：从零开始", "Café", "Cafe\u{301}"]
        let tags = ["", "[VCB-Studio] ", "[标题] ", "【喵萌奶茶屋】★04月新番★"]
        let episodes = [" - 01", " 02", ".S01E05", " 第十二话", " [2023] - 03", " S2", " C1", " Season 2 - 04", " 01 02", " 1970 - 05"]
        for name in names {
            XCTAssertEqual(DanmakuFilenameParser.comparableTitle(name), DanmakuFilenameParser.comparableTitleNative(name), name)
            for tag in tags {
                for episode in episodes {
                    for suffix in [".mkv", " [Ma10p][1080p].mp4", ""] {
                        let raw = "C:\\media\\" + tag + name + episode + suffix
                        XCTAssertEqual(DanmakuFilenameParser.parse(raw), DanmakuFilenameParser.parseNative(raw), raw)
                    }
                }
            }
        }
        for raw in [".hidden", "a.b.mkv", "a/", "", "01.mkv", "[作品] 02.mp4", "Title.S01E01", "[2023]作品01.mkv"] {
            XCTAssertEqual(DanmakuFilenameParser.parse(raw), DanmakuFilenameParser.parseNative(raw), raw)
            for season in [nil, 0, 1, 2, -1] as [Int?] {
                for episode in [nil, .number(5), .special(kind:.special,index:2), .special(kind:.extra,index:1)] as [DanmakuEpisodeToken?] {
                    XCTAssertEqual(DanmakuFilenameParser.canonicalMatchName(seriesTitle:"作品",season:season,episode:episode,rawFileName:raw), DanmakuFilenameParser.canonicalMatchNameNative(seriesTitle:"作品",season:season,episode:episode,rawFileName:raw), raw)
                }
            }
        }
    }
    func testEpisodeTokenAndUnicodeComparisonAgainstNative() throws {
        try requireCore()
        for title in [nil,"","第9223372036854775807话","第十二话","S0","S2","s2","C1234","S2字","O1 BD Vol.1 Warning","EP06","ep06","０５","Ｓ２","SP1 特番","05","第0话","剧场版","01.02","Title.E05.mkv"] as [String?] {
            XCTAssertEqual(DanmakuEpisodeToken.parse(title), DanmakuEpisodeToken.parseNative(title), title ?? "nil")
        }
        for title in ["É", "E\u{301}", "가", "가", "İ", "ß", "a\u{200D}b", "a\u{301}b", "²", "Ⅳ", "㍿", "一", "０１", "👨‍👩‍👧‍👦", "🇨🇳", "A![]\nB"] {
            XCTAssertEqual(DanmakuFilenameParser.comparableTitle(title), DanmakuFilenameParser.comparableTitleNative(title), title)
        }
    }
    func testSpecialKeywordBoundariesAndRawCanonicalFallback() throws {
        try requireCore()
        for keyword in ["SP", "special", "NCOP", "Menu", "OVA", "预告", "特典", "sports", "spring"] {
            for prefix in ["", "作品 ", "a", "a\u{200D}", " "] {
                for suffix in ["", "01.mkv", "a", "\u{301}", "\u{200D}a", " 01.mkv"] {
                    let raw = prefix + keyword + suffix
                    XCTAssertEqual(DanmakuSpecialKeyword.kind(in:raw), DanmakuSpecialKeyword.kindNative(in:raw), raw)
                }
            }
        }
        for raw in ["a/", ".hidden", "", "a.b.mkv", "a.", "..", "dir/01.mp4/"] {
            XCTAssertEqual(DanmakuFilenameParser.canonicalMatchName(seriesTitle:nil,season:nil,episode:nil,rawFileName:raw), DanmakuFilenameParser.canonicalMatchNameNative(seriesTitle:nil,season:nil,episode:nil,rawFileName:raw),raw)
        }
    }
    func testBatchSelectionRetainsExactIDsShiftAndGlobalOrder() throws {
        try requireCore()
        let match = MatchResponse.Match(episodeId: 9007199254740993, animeId:nil, animeTitle:"作品", episodeTitle:"第1话", type:nil,
            typeDescription:nil, shift:4294967296, fileName:nil, fileSize:nil, hash:nil)
        let target = DanmakuCandidateScorer.TargetContext(animeTitle:"作品",episodeNumber:1,seasonNumber:1)
        let selected = DanmakuCandidateScorer.pickBestMatch(from:[match, match],target:target)
        XCTAssertEqual(selected?.match.episodeID,9007199254740993)
        XCTAssertEqual(selected?.match.shiftSeconds,4294967296)
        XCTAssertEqual(selected?.score,4050)
        let episodes = (0..<1500).map { Episode(episodeId:Int64($0)+9007199254740993,episodeTitle:"第1话") }
        let best = DanmakuCandidateScorer.pickBestEpisode(from:[AnimeWithEpisodes(animeId:1,animeTitle:"作品",type:nil,typeDescription:nil,episodes:episodes)],target:target)
        XCTAssertEqual(best?.match.episodeID,9007199254740993)
        XCTAssertEqual(best?.score,4050)
    }
    func testScoresAgainstNativeIdentityRules() throws {
        try requireCore()
        let titles: [String?] = [nil, "", "作品", "作品 第二季", "作品 Final Season", "Café", "Cafe\u{301}", "a\u{200D}b", "甲乙丙", "乙丙丁"]
        let episodes: [String?] = [nil, "第1话", "第2话", "S1", "C1", "O2", "剧场版", "第十二话"]
        var comparisons = 0
        for kind in [DanmakuCandidateScorer.TargetKind.episode, .movie] {
            for season in [nil, 0, 1, 2] as [Int?] {
                for special in [nil, DanmakuSpecialTarget(index:1,kinds:[.extra,.special]), DanmakuSpecialTarget(index:2,kinds:[])] as [DanmakuSpecialTarget?] {
                    let target = DanmakuCandidateScorer.TargetContext(animeTitle:"作品",episodeNumber:1,seasonNumber:season,isFinal:season==nil,special:special,kind:kind)
                    for title in titles {
                        for episode in episodes {
                            for (description, type) in [(nil,nil),("电影","movie")] as [(String?,String?)] {
                                let rank = comparisons % 80 - 5
                                let actual = DanmakuCandidateScorer.scoreCandidate(animeTitle:title,episodeTitle:episode,typeDescription:description,type:type,target:target,rankIndex:rank)
                                let expected = DanmakuCandidateScorer.scoreCandidateNative(animeTitle:title,episodeTitle:episode,typeDescription:description,type:type,target:target,rankIndex:rank)
                                XCTAssertEqual(actual, expected, "\(String(describing:title)) \(String(describing:episode)) \(season as Any) \(special as Any)")
                                comparisons += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(comparisons,3840)
    }
}
