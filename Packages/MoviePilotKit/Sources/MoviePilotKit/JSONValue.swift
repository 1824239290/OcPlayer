import DiagnosticsKit
import Foundation

/// 无损 JSON 值：解码拿来展示几个字段，下载时把**原始对象原样回传**给服务器
/// （`POST /download/` 要求 media_in / torrent_in 是搜索结果里的完整对象，
/// 裁剪过的 DTO 回传会让服务端识别不出媒体）。
///
/// 数字统一走 Double：本项目回传的 id / size / 进度都远在 2^53 内，
/// 且服务端对这些字段本来就是 int/float 混用。
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的 JSON 值"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// 从 `JSONSerialization` 的 Any 构造（SSE 事件现场解析用）。
    /// 注意 Bool 分支要在 NSNumber 前判断（Bool 桥接成 NSNumber）。
    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as NSNumber:
            // ## ⚠️ 布尔判定**不能**用 `as? Bool`（这是一处修掉的既有 bug）
            //
            // `JSONSerialization` 给出的数字是 `NSNumber`，而 Swift 的
            // `NSNumber` → `Bool` 桥接对 **0 和 1 也成立**：实测
            // `NSNumber(value: 0) as? Bool` 得到 `false`、`1` 得到 `true`。
            //
            // 原先这里先 `case let value as Bool`，于是 JSON 里**任何 `0`/`1` 数字**
            // 都会被当成布尔：`{"seeders":0}` → `.bool(false)`，而
            // `JSONValue.boolValue == nil` 之外的 accessor 全部失效 ——
            // 具体地 `intValue` / `doubleValue` 都返回 `nil`（它们只认 `.number`）。
            //
            // 生产影响：SSE 资源搜索把 `torrent_info` 整对象经 `init(any:)` 转成
            // `MPTorrent.raw`，于是 `seeders` / `size` 取到 **0 或 1** 的那些条目
            // 字段直接**消失**（`raw["seeders"]?.intValue == nil`）。
            //
            // 正确判据要问 CoreFoundation 的**真实类型**：只有 `__NSCFBoolean`
            // 才是布尔，普通数字 `NSNumber` 不是。
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        default:
            self = .null
        }
    }
}

extension JSONValue {
    /// 对象字段访问。
    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var intValue: Int? {
        doubleValue.flatMap { Int(exactly: $0) }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// 是否是对象（用于 `[String: JSONValue]` 解码后再包一层）。
    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }
}

extension JSONValue {
    /// 稳定的内容哈希（FNV-1a，十六进制，实现共享在 `DiagnosticsKit.FNV1a`）。
    /// 对象键排序、值带类型前缀，同一个 JSON 每次算出同一个值——给缺主键的条目做
    /// ForEach 身份兜底，替代「每次读取都返回新 UUID()」导致的列表行重建/闪烁。
    var stableContentHash: String {
        var hasher = FNV1a()
        writeCanonical(into: &hasher)
        return hasher.finishHex()
    }

    private func writeCanonical(into hasher: inout FNV1a) {
        switch self {
        case .null:
            hasher.feed("z")
        case .bool(let value):
            hasher.feed(value ? "b:1" : "b:0")
        case .number(let value):
            hasher.feed("n:\(value)")
        case .string(let value):
            hasher.feed("s:\(value)")
        case .array(let items):
            hasher.feed("[")
            for item in items { item.writeCanonical(into: &hasher); hasher.feed(",") }
            hasher.feed("]")
        case .object(let dict):
            hasher.feed("{")
            for key in dict.keys.sorted() {
                hasher.feed("k:\(key):")
                dict[key]?.writeCanonical(into: &hasher)
                hasher.feed(";")
            }
            hasher.feed("}")
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// 参见 `JSONValue.stableContentHash`。
    var stableContentHash: String {
        JSONValue.object(self).stableContentHash
    }
}
