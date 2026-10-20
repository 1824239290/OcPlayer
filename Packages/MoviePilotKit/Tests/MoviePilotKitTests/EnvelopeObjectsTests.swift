import Foundation
import Testing
@testable import MoviePilotKit

/// `MPEnvelope.unwrapObjects` —— `P2-22` 的快速解码路径。
///
/// ## 为什么要有这组用例
///
/// 它替换了原来「`JSONSerialization` 解析 → 回序列化 → `JSONDecoder` 瀑布」的三遍
/// 解析（实测 28.47 ms → 7.92 ms / 243 KB）。**压缩掉的两遍必须不改变结果**：
/// 原来的 `JSONDecoder` 会把整数解成 `.number(Double)`、把 `true` 解成 `.bool`、
/// 把对象解成 `.object` —— 新路径走 `JSONValue(any:)`，类型判定稍有不同就会
/// 静默改变 `MPMediaInfo.raw` 的内容（而 raw 会**原样回传服务端**）。
///
/// 所以这里用**旧路径当 oracle**：同一份 data 跑两条路，结果必须逐字段相等。
@Suite("MPEnvelope.unwrapObjects")
struct EnvelopeObjectsTests {

    private static let oracleDecoder = JSONDecoder()

    /// 旧路径（改动前的实现）：unwrap + JSONDecoder 瀑布。
    private func legacy(_ data: Data) throws -> [[String: JSONValue]] {
        try Self.oracleDecoder.decode(
            [[String: JSONValue]].self, from: MPEnvelope.unwrap(data))
    }

    private func check(_ json: String) throws {
        let data = Data(json.utf8)
        let old = try legacy(data)
        let new = try MPEnvelope.unwrapObjects(data)
        #expect(old == new, "新旧路径结果不一致\n旧: \(old)\n新: \(new)")
    }

    /// 裸数组响应（`[` 开头，不剥信封）。
    @Test func bareArray() throws {
        try check(#"[{"a":1,"b":"x"},{"c":true,"d":null}]"#)
    }

    /// 标准信封响应。
    @Test func envelope() throws {
        try check(#"{"success":true,"data":[{"a":1},{"b":2}]}"#)
    }

    /// **数字 0 / 1 必须是 number**（走 `init(any:)` 的布尔桥接坑，见 `JSONValueAnyInitTests`）。
    @Test func numericZeroAndOne() throws {
        try check(#"{"success":true,"data":[{"seeders":0,"peers":1,"size":0}]}"#)
    }

    /// 各种数字形态。
    @Test func numericVariants() throws {
        try check(#"[{"i":42,"neg":-7,"f":8.5,"big":1000000,"zero":0}]"#)
    }

    /// 真布尔。
    @Test func booleans() throws {
        try check(#"[{"t":true,"f":false}]"#)
    }

    /// 嵌套对象与数组。
    @Test func nested() throws {
        try check(#"[{"torrents":[{"size":100,"seeders":0}],"meta":{"n":1,"b":true}}]"#)
    }

    /// 空数组 / 空对象。
    @Test func empties() throws {
        try check(#"{"success":true,"data":[]}"#)
        try check(#"[{}]"#)
    }

    /// 缺 `success` 的裸对象数组——不剥壳（与 `unwrap` 同语义）。
    @Test func arrayWithoutEnvelopeKeys() throws {
        try check(#"[{"success":false,"data":null,"x":1}]"#)
    }

    /// 真实形态（种子数为 0 的下载任务）。
    @Test func realisticDownloadTask() throws {
        try check("""
        {"success":true,"data":[{"hash":"abc","name":"某资源","size":1234567,
        "progress":17.12,"state":"downloading","dlspeed":"12.3 MB/s","left_time":"1小时"}]}
        """)
    }

    /// 信封里是**非数组**（例如裸字符串 / null）应抛错，而不是崩。
    ///
    /// 断言**具体错误类型与文案**，不只断言「抛了错」：旧路径抛的是 `DecodingError`
    /// （UI 会显示英文），新路径抛 `MoviePilotError.generic`（中文，是改善）。
    /// 只写 `throws: (any Error).self` 的话，将来谁把这里改成 `try?` / 静默返回空数组
    /// 都测不出来。
    @Test func nonArrayPayloadThrowsTypedError() {
        for payload in [#""hello""#, "null", #"{"a":1}"#, "42"] {
            let data = Data(#"{"success":true,"data":\#(payload)}"#.utf8)
            #expect(throws: MoviePilotError.self) {
                try MPEnvelope.unwrapObjects(data)
            }
            do {
                _ = try MPEnvelope.unwrapObjects(data)
                Issue.record("payload=\(payload) 应该抛错")
            } catch let error as MoviePilotError {
                guard case .generic(let message) = error else {
                    Issue.record("错误应是 .generic，实际 \(error)")
                    return
                }
                #expect(message == "响应不是对象数组", "错误文案应明确，实际 \(message)")
            } catch {
                Issue.record("错误类型不对：\(type(of: error))")
            }
        }
    }

    /// **数组里混进非对象元素必须抛错，不能静默丢弃。**
    ///
    /// 旧路径 `JSONDecoder.decode([[String: JSONValue]].self, ...)` 遇到
    /// `[{"a":1}, "oops", 5]` 会抛 `DecodingError`。第一版实现用了 `compactMap`，
    /// 实测同样输入会**静默返回 1 个元素、丢掉 2 个** —— 那等于把「服务端返回畸形
    /// 数据」伪装成「一切正常，只是少了几个条目」。
    @Test func nonObjectElementsThrowInsteadOfBeingDropped() {
        let mixed = Data(#"[{"a":1}, "oops", 5]"#.utf8)
        #expect(throws: (any Error).self) {
            try MPEnvelope.unwrapObjects(mixed)
        }
        // 对照：旧路径确实抛错（这条同时证明「严格」才是旧语义）
        #expect(throws: (any Error).self) {
            try Self.oracleDecoder.decode(
                [[String: JSONValue]].self, from: MPEnvelope.unwrap(mixed))
        }
    }

    /// 空数组仍然是成功（不是错误）。
    @Test func emptyArraySucceeds() throws {
        #expect(try MPEnvelope.unwrapObjects(Data("[]".utf8)).isEmpty)
        #expect(try MPEnvelope.unwrapObjects(Data(#"{"success":true,"data":[]}"#.utf8)).isEmpty)
    }

    /// 非法 JSON 应抛错，且是**明确类型**。
    @Test func malformedJSONThrowsTypedError() {
        do {
            _ = try MPEnvelope.unwrapObjects(Data("{not json".utf8))
            Issue.record("非法 JSON 应该抛错")
        } catch let error as MoviePilotError {
            guard case .generic(let message) = error else {
                Issue.record("错误应是 .generic，实际 \(error)")
                return
            }
            #expect(message == "响应不是合法 JSON", "实际 \(message)")
        } catch {
            Issue.record("错误类型不对：\(type(of: error))")
        }
    }
}
