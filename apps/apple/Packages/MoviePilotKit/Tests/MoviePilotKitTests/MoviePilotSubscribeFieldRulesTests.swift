import XCTest
@testable import MoviePilotKit

/// 订阅可清空字段的写入规则（P1-2：清空的字段必须真从原始字典里删掉）。
final class MoviePilotSubscribeFieldRulesTests: XCTestCase {

    func testEmptyTextClearsPairedKeys() {
        var dict: [String: JSONValue] = [
            "tmdbid": .number(12345),
            "tmdb_id": .number(12345),
            "name": .string("某剧"),
        ]
        MoviePilotSubscribeFieldRules.setOrClearNumber(&dict, text: "   ", keys: ["tmdbid", "tmdb_id"])
        XCTAssertNil(dict["tmdbid"])
        XCTAssertNil(dict["tmdb_id"])
        XCTAssertNotNil(dict["name"], "不该误删其他字段")
    }

    func testInvalidNumberClearsAndValidNumberWrites() {
        var dict: [String: JSONValue] = ["bangumiid": .number(1), "bangumi_id": .number(1)]
        MoviePilotSubscribeFieldRules.setOrClearNumber(&dict, text: "abc", keys: ["bangumiid", "bangumi_id"])
        XCTAssertNil(dict["bangumiid"])
        XCTAssertNil(dict["bangumi_id"])

        MoviePilotSubscribeFieldRules.setOrClearNumber(&dict, text: " 42 ", keys: ["bangumiid", "bangumi_id"])
        XCTAssertEqual(dict["bangumiid"]?.intValue, 42)
        XCTAssertEqual(dict["bangumi_id"]?.intValue, 42)
    }

    /// 成对键同进同出：只删一个（或只写一个）会让 `MPSubscribe` 的
    /// `raw["doubanid"] ?? raw["douban_id"]` 读法读到旧值。
    func testPairedKeysAreWrittenAndClearedTogether() {
        var dict: [String: JSONValue] = ["douban_id": .string("old"), "keyword": .string("keep")]
        MoviePilotSubscribeFieldRules.setOrClear(&dict, text: "1234567", keys: ["doubanid", "douban_id"])
        XCTAssertEqual(dict["doubanid"]?.stringValue, "1234567")
        XCTAssertEqual(dict["douban_id"]?.stringValue, "1234567", "别名键要一起更新，不留旧值")
        XCTAssertEqual(dict["keyword"]?.stringValue, "keep")

        MoviePilotSubscribeFieldRules.setOrClear(&dict, text: "", keys: ["doubanid", "douban_id"])
        XCTAssertNil(dict["doubanid"])
        XCTAssertNil(dict["douban_id"])
        XCTAssertEqual(dict["keyword"]?.stringValue, "keep")
    }

    func testTextFieldTrimsValueAndClearsOnWhitespace() {
        var dict: [String: JSONValue] = ["save_path": .string("/old/path")]
        MoviePilotSubscribeFieldRules.setOrClear(&dict, text: "  /media/tv  ", keys: ["save_path"])
        XCTAssertEqual(dict["save_path"]?.stringValue, "/media/tv")

        MoviePilotSubscribeFieldRules.setOrClear(&dict, text: " \n ", keys: ["save_path"])
        XCTAssertNil(dict["save_path"], "纯空白视为清空")
    }

    /// 简介保留原始空白/换行，但纯空白仍判空。
    func testKeepRawValueFieldKeepsWhitespaceButClearsWhenBlank() {
        var dict: [String: JSONValue] = [:]
        MoviePilotSubscribeFieldRules.setOrClear(
            &dict, text: "第一行\n第二行  ", keys: ["overview", "description"], keepRawValue: true
        )
        XCTAssertEqual(dict["overview"]?.stringValue, "第一行\n第二行  ")
        XCTAssertEqual(dict["description"]?.stringValue, "第一行\n第二行  ")

        MoviePilotSubscribeFieldRules.setOrClear(
            &dict, text: "   ", keys: ["overview", "description"], keepRawValue: true
        )
        XCTAssertNil(dict["overview"])
        XCTAssertNil(dict["description"])
    }
}
