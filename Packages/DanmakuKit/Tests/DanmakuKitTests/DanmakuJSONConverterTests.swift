import XCTest
@testable import DanmakuKit

final class DanmakuJSONConverterTests: XCTestCase {

    func testBasicConversion() throws {
        let comments = [
            DanmakuComment(cid: 1, p: "0.5,1,16777215,user1", m: "first"),
            DanmakuComment(cid: 2, p: "1.0,5,16711680,user2", m: "second")
        ]
        let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
        // 解回结构验证，不比对原始字符串（key 顺序不稳定）。
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let items = try XCTUnwrap(decoded?["comments"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["time"] as? Double, 0.5)
        XCTAssertEqual(items[0]["type"] as? Int, 1)
        XCTAssertEqual(items[0]["color"] as? Int64, 16777215)
        XCTAssertEqual(items[0]["content"] as? String, "first")
        XCTAssertEqual(items[0]["id"] as? Int64, 1)
        XCTAssertEqual(items[1]["type"] as? Int, 5) // 顶部
        XCTAssertEqual(items[1]["color"] as? Int64, 16711680) // 0xFF0000
    }

    func testAllModes() throws {
        let expected: [(Int, Int)] = [(1, 1), (4, 4), (5, 5)] // 滚动 / 底部 / 顶部
        for (mode, want) in expected {
            let comments = [DanmakuComment(p: "1.0,\(mode),16777215,u", m: "x")]
            let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
            let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            let items = try XCTUnwrap(decoded?["comments"] as? [[String: Any]])
            XCTAssertEqual(items[0]["type"] as? Int, want)
        }
    }

    func testFractionalSeconds() throws {
        let comments = [DanmakuComment(p: "12.345,1,16777215,u", m: "x")]
        let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let items = try XCTUnwrap(decoded?["comments"] as? [[String: Any]])
        XCTAssertEqual(items[0]["time"] as? Double, 12.345)
    }

    func testSkipsInvalidEntries() throws {
        let comments = [
            DanmakuComment(p: "0.5,1,16777215,u", m: "ok"),       // 有效
            DanmakuComment(p: "abc,1,16777215,u", m: "bad"),        // 非数字 time
            DanmakuComment(p: "0.5,1,16777215,u", m: "  "),         // 空 content
            DanmakuComment(p: "-1,1,16777215,u", m: "neg"),        // 负 time
            DanmakuComment(p: "0.5", m: "short"),                   // p 不足 3 段
            DanmakuComment(p: "inf,1,16777215,u", m: "infinite"),   // 非有限 time
            DanmakuComment(p: "0.5,6,16777215,u", m: "mode"),       // 不支持的 mode
            DanmakuComment(p: "0.5,1,16777216,u", m: "color"),      // 超出 RGB
        ]
        let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let items = try XCTUnwrap(decoded?["comments"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["content"] as? String, "ok")
    }

    /// 正文含引号 / 换行 / emoji 必须 JSON 转义后原样还原。
    func testContentEscaping() throws {
        let raw = "他说：\"好\"\n下一行 🎉"
        let comments = [DanmakuComment(p: "0.5,1,16777215,u", m: raw)]
        let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let items = try XCTUnwrap(decoded?["comments"] as? [[String: Any]])
        XCTAssertEqual(items[0]["content"] as? String, raw)
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(DanmakuJSONConverter.erikaJSON(from: nil))
        XCTAssertNil(DanmakuJSONConverter.erikaJSON(from: []))
    }

    func testDuplicateCIDsGetStableUniqueIDs() throws {
        // withRelated 合并的第三方来源 cid 会与官方重复；重复 id 会让 Erika
        // stable_tracks（合成 track_id<<48|item_id）key 冲突，窗口重排时个别
        // 弹幕轨道偏好互相顶掉 → 单独几条突然换位置。转换器必须保证 id 唯一。
        let comments = [
            DanmakuComment(cid: 7, p: "0.5,1,16777215,u", m: "a"),
            DanmakuComment(cid: 7, p: "1.0,1,16777215,u", m: "b"), // cid 重复
            DanmakuComment(cid: nil, p: "2.0,1,16777215,u", m: "c"), // 无 cid
        ]
        let json = try XCTUnwrap(DanmakuJSONConverter.erikaJSON(from: comments))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let items = try XCTUnwrap(decoded["comments"] as? [[String: Any]])
        let ids = try XCTUnwrap(items.map { $0["id"] as? Int64 })
        XCTAssertEqual(ids.count, Set(ids).count, "id 必须全部唯一")
        XCTAssertEqual(ids[0], 7, "首个有效 cid 保留")
        XCTAssertNotEqual(ids[1], 7, "重复 cid 必须换成序号，不能冲突")
        XCTAssertEqual(ids[1], 2, "重复 cid 用整集序号兜底")
        XCTAssertEqual(ids[2], 3, "无 cid 用整集序号")
    }

    func testAllInvalidReturnsNil() {
        let comments = [DanmakuComment(p: "bad", m: ""), DanmakuComment(p: "0.5", m: "  ")]
        XCTAssertNil(DanmakuJSONConverter.erikaJSON(from: comments))
    }
}
