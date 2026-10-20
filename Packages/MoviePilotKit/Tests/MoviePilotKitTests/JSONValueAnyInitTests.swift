import Foundation
import Testing
@testable import MoviePilotKit

/// `JSONValue.init(any:)` 的类型判定 —— 这里修掉过一个**既有 bug**。
///
/// ## bug 是什么
///
/// `JSONSerialization` 给出的数字是 `NSNumber`，而 Swift 的 `NSNumber` → `Bool`
/// 桥接**对 0 和 1 也成立**：
///
/// ```
/// NSNumber(value: 0) as? Bool  →  false
/// NSNumber(value: 1) as? Bool  →  true
/// ```
///
/// 原实现先 `case let value as Bool`，于是 JSON 里**任何 `0`/`1` 数字**都变成 `.bool`。
/// 而 `JSONValue.intValue` / `doubleValue` 只认 `.number` —— 于是这些字段**变成 nil**。
///
/// ## 为什么值得钉
///
/// 生产路径上 SSE 资源搜索用 `torrentRaw.mapValues(JSONValue.init(any:))` 把整个
/// `torrent_info` 收进 `MPTorrent.raw`。种子数为 0 或 1 的资源，`seeders` 字段
/// 会直接消失。
@Suite("JSONValue.init(any:)")
struct JSONValueAnyInitTests {

    /// 从真实 JSON 字符串走 `JSONSerialization` 再转，链路与生产一致。
    private func value(_ json: String, key: String) throws -> JSONValue {
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw = try #require(object?[key])
        return JSONValue(any: raw)
    }

    /// **核心判据：数字 0 / 1 必须是 `.number`，不是 `.bool`。**
    @Test func numericZeroAndOneStayNumbers() throws {
        for (json, expected) in [("0", 0.0), ("1", 1.0)] {
            let v = try value("{\"k\":\(json)}", key: "k")
            #expect(v == .number(expected), "JSON 数字 \(json) 应保持为 number")
        }
    }

    /// 数字 0 / 1 的 `intValue` 必须拿得到（这是 bug 的实际后果）。
    @Test func numericZeroAndOneExposeIntValue() throws {
        #expect(try value(#"{"k":0}"#, key: "k").intValue == 0)
        #expect(try value(#"{"k":1}"#, key: "k").intValue == 1)
    }

    /// **真布尔仍然是 `.bool`**（不能为了修 bug 把布尔也变成数字）。
    @Test func realBooleansStayBooleans() throws {
        #expect(try value(#"{"k":true}"#, key: "k") == .bool(true))
        #expect(try value(#"{"k":false}"#, key: "k") == .bool(false))
    }

    /// 布尔与数字互不串味：`true` 的 `intValue` 必须是 nil（不是 1）。
    @Test func booleansDoNotExposeIntValue() throws {
        #expect(try value(#"{"k":true}"#, key: "k").intValue == nil)
        #expect(try value(#"{"k":false}"#, key: "k").intValue == nil)
    }

    /// 其它数字照常是 `.number`（不能把修 bug 变成了「所有数字变 .null」）。
    @Test func otherNumbersStayNumbers() throws {
        #expect(try value(#"{"k":2}"#, key: "k") == .number(2))
        #expect(try value(#"{"k":42}"#, key: "k") == .number(42))
        #expect(try value(#"{"k":-1}"#, key: "k") == .number(-1))
        #expect(try value(#"{"k":8.5}"#, key: "k") == .number(8.5))
        #expect(try value(#"{"k":1000}"#, key: "k") == .number(1000))
    }

    /// 字符串 / null / 数组 / 嵌套对象照常。
    @Test func otherTypesUnchanged() throws {
        #expect(try value(#"{"k":"x"}"#, key: "k") == .string("x"))
        #expect(try value(#"{"k":null}"#, key: "k") == .null)

        let array = try value(#"{"k":[0,1,true,"s"]}"#, key: "k")
        #expect(array == .array([.number(0), .number(1), .bool(true), .string("s")]))

        let nested = try value(#"{"k":{"n":0,"b":true}}"#, key: "k")
        #expect(nested == .object(["n": .number(0), "b": .bool(true)]))
    }

    /// **真实形态**：种子数为 0 的资源对象，`seeders` 必须读得出来。
    ///
    /// 这条直接复刻 SSE 路径的用法（`torrentRaw.mapValues(JSONValue.init(any:))`）。
    @Test func realisticTorrentWithZeroSeedersKeepsField() throws {
        let json = """
        {"title":"某资源","size":1234567,"seeders":0,"peers":1,"enclosure":"https://x/1.torrent"}
        """
        let data = Data(json.utf8)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let converted = raw.mapValues(JSONValue.init(any:))

        #expect(converted["seeders"]?.intValue == 0, "seeders=0 不该丢失")
        #expect(converted["peers"]?.intValue == 1, "peers=1 不该丢失")
        #expect(converted["size"]?.intValue == 1_234_567)
        #expect(converted["title"]?.stringValue == "某资源")
    }
}
