import XCTest
@testable import DiagnosticsKit

/// FNV-1a 的算法契约。**golden 值一变，所有用它的持久化标识都会跟着变**——
/// MoviePilotKit 的 `stableContentHash`（缺主键条目的列表身份）与 JellyfinKit 的
/// 缺 id 兜底派生 id 都钉在这个算法上，所以这里用标准测试向量锁死。
final class StableHashTests: XCTestCase {

    func testKnownVectors() {
        XCTAssertEqual(FNV1a.hex(of: ""), "cbf29ce484222325")
        XCTAssertEqual(FNV1a.hex(of: "a"), "af63dc4c8601ec8c")
        XCTAssertEqual(FNV1a.hex(of: "foobar"), "85944171f73967e8")
    }

    func testMultiFeedConcatenates() {
        var hasher = FNV1a()
        hasher.feed("foo")
        hasher.feed("bar")
        XCTAssertEqual(hasher.finishHex(), FNV1a.hex(of: "foobar"))
    }

    func testDifferentInputsDiffer() {
        XCTAssertNotEqual(FNV1a.hex(of: "abc"), FNV1a.hex(of: "abcd"))
        XCTAssertNotEqual(FNV1a.hex(of: "某片"), FNV1a.hex(of: "某剧"))
    }
}
