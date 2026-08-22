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
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
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
