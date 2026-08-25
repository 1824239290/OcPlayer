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
}
