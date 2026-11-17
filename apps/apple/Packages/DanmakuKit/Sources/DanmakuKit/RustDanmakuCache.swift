import Foundation
import OcPlayerCore

/// Core owns the file format, conservative recovery, revisions, TTL and LRU.
/// Payload JSON stays textual across the generic ABI projection to retain Int64.
struct RustDanmakuCache: Sendable {
    let core: OcpCoreClient

    init(directory: URL, ttl: TimeInterval, capacity: Int) throws {
        core = try OcpCoreClient()
        let opened = try core.call("danmakuCache.open", arguments: [
            "directory": directory.path,
            "commentsTTL": ttl,
            "commentsMemoryCapacity": capacity,
        ])
        guard opened.ok else { throw OcpCoreError(message: opened.message) }
    }

    func call<T: Decodable>(
        _ method: String, _ arguments: [String: Any] = [:], as: T.Type = T.self
    ) throws -> T {
        let response = try core.call("danmakuCache." + method, arguments: arguments)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        let raw = try response.data.decode(CachePayload.self)
        return try JSONDecoder().decode(T.self, from: Data(raw.payloadJSON.utf8))
    }

    func write<T: Encodable>(_ method: String, value: T, arguments: [String: Any]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        var args = arguments
        args["payloadJSON"] = String(decoding: data, as: UTF8.self)
        let _: Bool? = try? call(method, args)
    }

    private struct CachePayload: Decodable {
        let payloadJSON: String
    }
}
