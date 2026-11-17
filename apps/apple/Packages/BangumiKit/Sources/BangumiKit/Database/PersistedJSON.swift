import Foundation

/// JSON 编解码辅助（sortedKeys 保证编码稳定，decode 容错返回 nil）。
enum BangumiPersistedJSON {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func encode<Value: Encodable>(_ value: Value) -> Data? {
        try? encoder.encode(value)
    }

    static func encode<Value: Encodable>(_ value: Value?) -> Data? {
        guard let value else { return nil }
        return try? encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) -> Value? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// 数据库行读 JSON BLOB 的辅助（nil 时用 fallback）。
enum BangumiRecordCoding {
    static func encode<Value: Encodable>(_ value: Value) -> Data? {
        BangumiPersistedJSON.encode(value)
    }

    static func encode<Value: Encodable>(_ value: Value?) -> Data? {
        BangumiPersistedJSON.encode(value)
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data?, fallback: @autoclosure () -> Value
    ) -> Value {
        BangumiPersistedJSON.decode(type, from: data) ?? fallback()
    }

    static func bool(_ value: Bool) -> Int {
        value ? 1 : 0
    }

    static func bool(_ value: Int) -> Bool {
        value != 0
    }
}
