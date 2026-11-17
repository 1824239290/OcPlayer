import XCTest
@testable import MoviePilotKit

/// 模型 id 兜底与稳定内容哈希：缺主键时 ForEach 身份不能每次重绘都变。
final class MoviePilotModelsTests: XCTestCase {

    func testSubscribeIDFallsBackToStableHash() {
        let a = MPSubscribe(raw: ["season": .number(1)])
        let b = MPSubscribe(raw: ["season": .number(1)])
        let c = MPSubscribe(raw: ["season": .number(2)])
        XCTAssertEqual(a.id, b.id, "相同 raw 的兜底 id 必须稳定")
        XCTAssertNotEqual(a.id, c.id, "不同 raw 的兜底 id 要不同")
        // 有主键时走主键，不走哈希。
        XCTAssertEqual(MPSubscribe(raw: ["id": .number(42)]).id, "sub:42")
    }

    func testTorrentAndDownloadTaskIDsAreStable() {
        let raw: [String: JSONValue] = ["title": .string("Matrix"), "size": .number(1.5)]
        XCTAssertEqual(MPTorrent(raw: raw).id, MPTorrent(raw: raw).id)
        XCTAssertEqual(MPDownloadTask(raw: raw).id, MPDownloadTask(raw: raw).id)
        XCTAssertNotEqual(
            MPTorrent(raw: raw).id, MPDownloadTask(raw: raw).id, "类型前缀要区分不同列表")
        // 有确定性 id 字段时直接用字段。
        XCTAssertEqual(
            MPTorrent(raw: ["enclosure": .string("magnet:?xt=abc")]).id, "magnet:?xt=abc")
        XCTAssertEqual(
            MPDownloadTask(raw: ["hash": .string("h1")]).id, "h1")
    }

    func testStableHashIgnoresDictionaryOrder() {
        let left = JSONValue.object(["b": .string("2"), "a": .string("1")])
        let right = JSONValue.object(["a": .string("1"), "b": .string("2")])
        XCTAssertEqual(left.stableContentHash, right.stableContentHash)
    }

    func testStableHashDistinguishesTypes() {
        // 类型前缀：字符串 "1" 和数字 1 不能算出同一个哈希。
        XCTAssertNotEqual(
            JSONValue.object(["v": .string("1")]).stableContentHash,
            JSONValue.object(["v": .number(1)]).stableContentHash)
        XCTAssertNotEqual(
            JSONValue.object(["v": .string("abc")]).stableContentHash,
            JSONValue.object(["v": .string("abcd")]).stableContentHash)
    }
}
