import XCTest
@testable import DanmakuKit

/// 集号 token：正片「第 N 话」与特典 `S/C/O` 命名空间的解析。
/// 回归背景：`S5 聖地巡礼企画` 这类特典标题里的 5 曾被宽松兜底当成第 5 话，
/// 特典候选因此污染正片匹配。
final class DanmakuEpisodeTokenTests: XCTestCase {

    func testParsesNumberedEpisodeForms() {
        XCTAssertEqual(DanmakuEpisodeToken.parse("第5话 死者的幻影"), .number(5))
        XCTAssertEqual(DanmakuEpisodeToken.parse("第02话"), .number(2))
        XCTAssertEqual(DanmakuEpisodeToken.parse("第3集"), .number(3))
        XCTAssertEqual(DanmakuEpisodeToken.parse("第十二话"), .number(12))
        XCTAssertEqual(DanmakuEpisodeToken.parse("EP06"), .number(6))
        XCTAssertEqual(DanmakuEpisodeToken.parse("05"), .number(5))
        XCTAssertEqual(DanmakuEpisodeToken.parse("04 某某"), .number(4))
    }

    func testParsesSpecialNamespaces() {
        XCTAssertEqual(DanmakuEpisodeToken.parse("S2 アームストロング"), .special(kind: .special, index: 2))
        XCTAssertEqual(
            DanmakuEpisodeToken.parse("S5 聖地巡礼企画『負けヒロインに会いに来た!』#4"),
            .special(kind: .special, index: 5)
        )
        XCTAssertEqual(DanmakuEpisodeToken.parse("C1 Opening"), .special(kind: .extra, index: 1))
        XCTAssertEqual(DanmakuEpisodeToken.parse("C4 Ending 3"), .special(kind: .extra, index: 4))
        XCTAssertEqual(DanmakuEpisodeToken.parse("O1 BD Vol.1 Warning"), .special(kind: .other, index: 1))
    }

    func testDoesNotMistakeWordsForSpecialPrefix() {
        // `SP1` 不是命名空间前缀（字母后必须是数字）；`剧场版` 没有集号。
        XCTAssertNil(DanmakuEpisodeToken.parse("SP1 特番"))
        XCTAssertNil(DanmakuEpisodeToken.parse("剧场版"))
        XCTAssertNil(DanmakuEpisodeToken.parse(nil))
    }

    func testSearchValueMatchesOfficialEpisodeParameter() {
        XCTAssertEqual(DanmakuEpisodeToken.number(12).searchValue, "12")
        XCTAssertEqual(DanmakuEpisodeToken.special(kind: .special, index: 2).searchValue, "S2")
        XCTAssertEqual(DanmakuEpisodeToken.special(kind: .extra, index: 1).searchValue, "C1")
        XCTAssertEqual(DanmakuEpisodeToken.special(kind: .other, index: 1).searchValue, "O1")
    }

    func testSpecialKeywordDetection() {
        XCTAssertEqual(DanmakuSpecialKeyword.kind(in: "[Group] Show NCOP.mkv"), .extra)
        XCTAssertEqual(DanmakuSpecialKeyword.kind(in: "Show NCED 01.mkv"), .extra)
        XCTAssertEqual(DanmakuSpecialKeyword.kind(in: "Show Menu.mkv"), .extra)
        XCTAssertEqual(DanmakuSpecialKeyword.kind(in: "Show SP01.mkv"), .special)
        XCTAssertEqual(DanmakuSpecialKeyword.kind(in: "Show 特典 01.mkv"), .special)
        // OVA/OAD 不认：弹弹play 常把 OVA 编成该作品的正片「第 1 话」，认成特典会扣分。
        XCTAssertNil(DanmakuSpecialKeyword.kind(in: "Show OVA.mkv"))
        XCTAssertNil(DanmakuSpecialKeyword.kind(in: "Show OAD 01.mkv"))
        // 关键词必须是独立 token：`sports` / `spring` 里的 sp 不算。
        XCTAssertNil(DanmakuSpecialKeyword.kind(in: "[Group] Sports Day 01.mkv"))
        XCTAssertNil(DanmakuSpecialKeyword.kind(in: "Spring 2024 - 01.mkv"))
    }
}
