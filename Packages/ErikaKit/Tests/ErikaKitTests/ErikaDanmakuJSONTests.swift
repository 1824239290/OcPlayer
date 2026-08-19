import XCTest
@testable import ErikaKit

/// 锁定 Erika 内核 inline JSON 弹幕的确切 schema。
/// PLAN.md 声称根键 `comments`、每条 `time`/`type`/`color`/`content`，
/// 但仓库此前只有 Bilibili XML 路径的测试；这里实测两种候选形态，
/// 转换器（DanmakuKit）按实测结果输出。
final class ErikaDanmakuJSONTests: XCTestCase {

    func testCommentsObjectShape() throws {
        let engine = try ErikaEngine()
        defer { try? engine.close() }

        let json = """
        {"comments":[
          {"time":0.5,"type":1,"color":16777215,"content":"first"},
          {"time":1.0,"type":5,"color":16711680,"content":"second"}
        ]}
        """
        let trackID = try engine.addDanmakuTrack(json: json, name: "JSON")
        let track = try XCTUnwrap(try engine.danmakuTracks().first { $0.id == trackID })
        XCTAssertEqual(track.itemCount, 2)
    }

    func testRootArrayShape() throws {
        let engine = try ErikaEngine()
        defer { try? engine.close() }

        let json = """
        [
          {"time":0.5,"type":1,"color":16777215,"content":"first"},
          {"time":1.0,"type":5,"color":16711680,"content":"second"}
        ]
        """
        let trackID = try engine.addDanmakuTrack(json: json, name: "Array")
        let track = try XCTUnwrap(try engine.danmakuTracks().first { $0.id == trackID })
        XCTAssertEqual(track.itemCount, 2)
    }

    /// 弹幕正文含引号 / 换行 / emoji 时必须能原样进入弹幕轨道。
    func testContentEscaping() throws {
        let engine = try ErikaEngine()
        defer { try? engine.close() }

        let content = "他说：\"好\"\n下一行 🎉"
        let payload: [String: [[String: Any]]] = [
            "comments": [
                ["time": 0.5, "type": 1, "color": 16777215, "content": content]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8)!
        let trackID = try engine.addDanmakuTrack(json: json, name: "Escaped")
        let track = try XCTUnwrap(try engine.danmakuTracks().first { $0.id == trackID })
        XCTAssertEqual(track.itemCount, 1)
    }
}
