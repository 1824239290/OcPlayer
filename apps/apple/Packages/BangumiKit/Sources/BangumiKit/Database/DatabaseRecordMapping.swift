import Foundation
import GRDB

extension Row {
    /// 读 JSON BLOB 列，nil 或解码失败时用 fallback。
    func json<Value: Decodable>(
        _ column: String, fallback: @autoclosure () -> Value
    ) -> Value {
        let data: Data? = self[column]
        return BangumiPersistedJSON.decode(Value.self, from: data) ?? fallback()
    }

    /// 读可空的 JSON BLOB 列。
    func jsonOptional<Value: Decodable>(_ column: String) -> Value? {
        let data: Data? = self[column]
        return BangumiPersistedJSON.decode(Value.self, from: data)
    }
}
