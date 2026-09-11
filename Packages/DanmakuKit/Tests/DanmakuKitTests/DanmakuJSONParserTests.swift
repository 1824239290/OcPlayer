import XCTest
@testable import DanmakuKit

final class DanmakuJSONParserTests: XCTestCase {
    func testParsesModesAndClampsColor() {
        let json = """
        {"comments":[
          {"time":1.5,"type":1,"color":16777215,"content":"滚动"},
          {"time":2.0,"type":5,"color":255,"content":"顶部"},
          {"time":3.0,"type":4,"color":0,"content":"底部"},
          {"time":4.0,"type":1,"color":-1,"content":"负数颜色"}
        ]}
        """
        let entries = DanmakuJSONParser.parse(json)
        XCTAssertEqual(entries?.count, 4)
        XCTAssertEqual(entries?[0].mode, .scroll)
        XCTAssertEqual(entries?[1].mode, .top)
        XCTAssertEqual(entries?[2].mode, .bottom)
        // 负数颜色夹到 0（原 overlay 的 trap 防护语义保留在包里）。
        XCTAssertEqual(entries?[3].color, 0)
    }

    func testSkipsInvalidEntries() {
        let json = """
        {"comments":[
          {"time":-1,"type":1,"color":0,"content":"负时间"},
          {"time":1,"type":1,"color":0,"content":""},
          {"time":2,"type":1,"color":0,"content":"有效"}
        ]}
        """
        let entries = DanmakuJSONParser.parse(json)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.text, "有效")
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(DanmakuJSONParser.parse("not json"))
        // 合法 JSON 但缺 comments 键：算「没有弹幕」（[]），不是「解析挂了」（nil）。
        XCTAssertEqual(DanmakuJSONParser.parse("{\"other\":1}"), [])
    }

    func testValidEmptyCommentsReturnsEmpty() {
        // 「合法但没有弹幕」是空数组而不是 nil——调用方据此区分真没有/解析挂了。
        XCTAssertEqual(DanmakuJSONParser.parse("{\"comments\":[]}"), [])
        XCTAssertEqual(DanmakuJSONParser.parse("{}"), [])
    }

    func testRoundTripsWithConverter() {
        // 写入侧（converter）与解析侧（parser）必须对同一份 schema 达成一致：
        // 转出的 JSON 能被解析回来且字段不变。
        let comments = [
            DanmakuComment(cid: 1, p: "12.5,1,16777215,0", m: "hello"),
            DanmakuComment(cid: 2, p: "13.0,5,255,0", m: "顶部弹幕"),
        ]
        guard let json = DanmakuJSONConverter.erikaJSON(from: comments) else {
            return XCTFail("converter 应产出 JSON")
        }
        let entries = DanmakuJSONParser.parse(json)
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?[0].time, 12.5)
        XCTAssertEqual(entries?[0].text, "hello")
        XCTAssertEqual(entries?[0].color, 0xFF_FF_FF)
        XCTAssertEqual(entries?[1].mode, .top)
    }
}
