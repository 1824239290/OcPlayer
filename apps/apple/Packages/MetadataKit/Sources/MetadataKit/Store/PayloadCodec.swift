import CoreModel
import Foundation
import JellyfinKit

/// payload 的编解码（JSON）。
///
/// 单独一层而不是各处直接 `JSONEncoder()`：编码器的配置（键序、日期策略）与
/// 「版本不认就当未命中」这条判定必须**只有一处**，否则改一处忘一处会让旧 payload
/// 在某条读路径上突然解不出来，而另一条还好——那种半坏状态最难查。
enum PayloadCodec {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // 键序稳定：payload 会进缓存，稳定序列化让「同一条目重复写入」的字节可比较，
        // 排查体积问题时可复现（对正确性无影响）。
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    /// 解码。`storedVersion` 不认识时返回 nil（调用方当「未命中」重拉）。
    ///
    /// **不抛错**：这是缓存路径，解不出来唯一正确的反应是当作没缓存过。
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, storedVersion: Int) -> T? {
        guard storedVersion == Schema.payloadVersion else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// 一条 rail 的自包含快照。
///
/// 存整个数组而不是 item_id 列表：条目被淘汰后，id 列表会指向不存在的行，
/// 「继续观看」就会静默少几张卡（见 `Schema` 的说明）。
struct RailSnapshot: Codable {
    var items: [MediaItem]
}

/// 一个库页的自包含快照。
struct PageSnapshot: Codable {
    var items: [MediaItem]
    var totalRecordCount: Int?
}
