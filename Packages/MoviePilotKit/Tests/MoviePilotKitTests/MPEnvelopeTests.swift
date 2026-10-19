import Foundation
import XCTest

@testable import MoviePilotKit

/// MoviePilot 响应信封的**浅判定**（性能审查清单 `P2-21`）。
///
/// ## 背景
///
/// 改前对**每一个**响应都先 `JSONSerialization.jsonObject` 全量解析（Foundation 的
/// `Any` 树，装箱 + `NSNumber`/`NSString`），带信封时再把 `data` 序列化回 `Data`
/// 交给 `JSONDecoder` —— **一次响应解析两遍**。
///
/// 改后先看首个非空白字节：`[` 不可能是信封（信封是对象），**直接原样返回**，零解析。
///
/// ## 这组用例钉什么
///
/// 浅判定是纯优化，**输出必须与改前逐字节相同** —— 所以主判据是等价性，
/// 而不是「是否走了快路径」（后者无法从外部观测）。
final class MPEnvelopeTests: XCTestCase {

    /// 裸数组：原样返回（最短路径，且必须逐字节不变）。
    func testBareArrayIsReturnedUnchanged() {
        let input = Data(#"[{"id":1},{"id":2}]"#.utf8)
        XCTAssertEqual(MPEnvelope.unwrap(input), input)
    }

    /// 前缀空白不影响判定（`[` 前面有空格 / 换行 / 制表符都要认）。
    func testLeadingWhitespaceBeforeArrayIsHandled() {
        for prefix in [" ", "\n", "\r\n", "\t", "  \n\t "] {
            let input = Data((prefix + #"[{"id":1}]"#).utf8)
            XCTAssertEqual(MPEnvelope.unwrap(input), input, "前缀 \(prefix.debugDescription)")
        }
    }

    /// 信封：剥出 `data`。
    func testEnvelopeIsUnwrapped() throws {
        let input = Data(#"{"success":true,"data":[{"id":1},{"id":2}]}"#.utf8)
        let output = MPEnvelope.unwrap(input)
        let parsed = try JSONSerialization.jsonObject(with: output) as? [[String: Int]]
        XCTAssertEqual(parsed?.count, 2, "信封应被剥掉，只留 data")
        XCTAssertEqual(parsed?.first?["id"], 1)
    }

    /// 信封里 `data` 是对象也要能剥。
    func testEnvelopeWithObjectPayload() throws {
        let input = Data(#"{"success":true,"data":{"access_token":"t","user_id":"u"}}"#.utf8)
        let output = MPEnvelope.unwrap(input)
        let parsed = try JSONSerialization.jsonObject(with: output) as? [String: String]
        XCTAssertEqual(parsed?["access_token"], "t")
    }

    /// **没有 `success` 字段的对象不算信封**，原样返回（否则会把普通响应拆坏）。
    func testObjectWithoutSuccessKeyIsReturnedUnchanged() {
        let input = Data(#"{"data":{"a":1},"other":2}"#.utf8)
        XCTAssertEqual(MPEnvelope.unwrap(input), input)
    }

    /// 带 `success` 但**没有 `data`** → 原样返回（不能把信封当负载）。
    func testObjectWithSuccessButNoDataIsReturnedUnchanged() {
        let input = Data(#"{"success":false,"detail":"boom"}"#.utf8)
        XCTAssertEqual(MPEnvelope.unwrap(input), input)
    }

    /// `data` 是 `null` → 原样返回（退回信封，让下游按自己的错误路径处理）。
    func testEnvelopeWithNullDataIsReturnedUnchanged() {
        let input = Data(#"{"success":true,"data":null}"#.utf8)
        XCTAssertEqual(MPEnvelope.unwrap(input), input)
    }

    /// **`data` 是标量时不能崩。**
    ///
    /// `JSONSerialization.data(withJSONObject:)` 只接受容器；顶层 `String`/`Number`
    /// 会抛 **NSInvalidArgumentException** —— ObjC 异常，`try?` **接不住**，进程直接崩。
    /// 这是改前就存在的缺陷，差分用例当场炸出来的。
    func testScalarDataPayloadDoesNotCrash() {
        for raw in [
            #"{"success":true,"data":"plain string"}"#,
            #"{"success":true,"data":42}"#,
            #"{"success":true,"data":true}"#,
            #"{"success":true,"data":3.14}"#,
        ] {
            let input = Data(raw.utf8)
            XCTAssertEqual(MPEnvelope.unwrap(input), input, "标量 data 应原样退回：\(raw)")
        }
    }

    /// 非 JSON / 空数据 → 原样返回，不崩。
    func testMalformedInputIsReturnedUnchanged() {
        for raw in ["", "not json", "{", "[", "{\"success\":", "\u{0}"] {
            let input = Data(raw.utf8)
            XCTAssertEqual(MPEnvelope.unwrap(input), input, "输入 \(raw.debugDescription)")
        }
    }

    /// **等价性黄金**：一批真实形态的输入，浅判定版与「无浅判定」的参考实现逐字节相同。
    ///
    /// 参考实现就是改前的样子（先 `JSONSerialization` 再判信封）。这条防的是
    /// 「为了快而改变了行为」—— 那类改动最危险，因为只在特定响应形态下才暴露。
    func testShallowCheckIsBehaviourallyIdenticalToTheOldImplementation() {
        func reference(_ data: Data) -> Data {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object.keys.contains("success"),
                  let inner = object["data"], !(inner is NSNull)
            else { return data }
            // 与生产实现同一个约束：非容器无法序列化（`try?` 接不住 ObjC 异常）。
            guard JSONSerialization.isValidJSONObject(inner) else { return data }
            return (try? JSONSerialization.data(withJSONObject: inner)) ?? data
        }

        let corpus: [String] = [
            "[]",
            "[1,2,3]",
            #"[{"a":1}]"#,
            #"  [ {"a": 1} ]  "#,
            #"{"success":true,"data":[1,2,3]}"#,
            #"{"success":true,"data":{"k":"v"}}"#,
            #"{"success":true,"data":null}"#,
            #"{"success":false,"detail":"x"}"#,
            #"{"data":{"a":1}}"#,
            #"{"success":true}"#,
            #"{"success":true,"data":"plain string"}"#,
            #"{"success":true,"data":42}"#,
            "",
            "   ",
            "not json",
        ]
        for raw in corpus {
            let input = Data(raw.utf8)
            XCTAssertEqual(
                MPEnvelope.unwrap(input), reference(input),
                "浅判定改变了行为：输入 \(raw.prefix(60))")
        }
    }
}
