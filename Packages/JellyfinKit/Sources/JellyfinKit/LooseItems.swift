import CoreModel
import Foundation
import JellyfinAPI

/// Emby 响应的“洗白”层。
///
/// Emby 是 Jellyfin 的前身但字段值集更宽：`CollectionType` / `Type` 等字段会出
/// jellyfin-sdk-swift 枚举不认的值（如 `"mixed"`、`"CollectionFolder"`），
/// 强类型解码整包炸成 "The data couldn't be read because it is missing"。
/// 这里在 SDK 解码前把脏枚举值替换成安全值，其余字段原样透传——
/// 既有 Mapping 逻辑一行不动。
enum EmbySanitizer {
    /// SDK `CollectionType` 认的值（大小写与 Emby 输出对齐后匹配）。
    private static let knownCollectionTypes: Set<String> = [
        "movies", "tvshows", "music", "musicvideos", "trailers",
        "homevideos", "boxsets", "books", "photos", "livetv", "playlists", "folders",
    ]

    /// SDK `BaseItemKind` 认的值（`Type` 字段）。Emby 会多出 CollectionFolder 等，
    /// 统一压成 "Folder"（SDK 有 case folder）；列表场景它们本来也会被过滤掉。
    private static let knownItemKinds: Set<String> = [
        "Movie", "Series", "Episode", "Season", "BoxSet", "Folder",
        "MusicAlbum", "MusicArtist", "Playlist", "PhotoAlbum", "Channel", "ChannelFolderItem",
    ]

    /// 对根为对象（QueryResult 信封）或数组（/Items/Latest 裸数组）的响应做递归洗白。
    static func sanitize(_ data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data
        }
        object = sanitizeValue(object)
        return (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? data
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var cleaned = dict
            if let type = dict["CollectionType"] as? String {
                if knownCollectionTypes.contains(type.lowercased()) {
                    // SDK 枚举只认小写 rawValue；Emby 会输出 "BoxSets" 这类大小写变体。
                    cleaned["CollectionType"] = type.lowercased()
                } else {
                    // 未知值（如 "mixed"）洗掉：解码为 nil → 域模型 .unknown → 浏览层过滤。
                    cleaned["CollectionType"] = nil
                }
            }
            if let type = dict["Type"] as? String,
               !knownItemKinds.contains(type) {
                // 未知条目类型压成 Folder：SDK 能解，域映射归 .folder，浏览层自行过滤。
                cleaned["Type"] = "Folder"
            }
            if var userData = cleaned["UserData"] as? [String: Any] {
                // SDK 的 UserItemDataDto.Key 是 required decode；Emby 的 UserData
                // 可能不带 Key。存在但缺 Key 时补占位；整个 UserData 缺失则合法
                // （BaseItemDto.userData 可选），不动。
                if (userData["Key"] as? String) == nil {
                    userData["Key"] = ""
                }
                cleaned["UserData"] = sanitizeValue(userData)
            }
            return cleaned.mapValues { sanitizeValue($0) }
        case let array as [Any]:
            return array.map { sanitizeValue($0) }
        default:
            return value
        }
    }
}

/// SDK 解码用的 JSONDecoder 配置（与 jellyfin-sdk-swift 的 JellyfinClient 相同：
/// ISO8601 日期）。宽松解码必须走同一配置，否则响应里的日期字段
/// （DateCreated 等）会炸 typeMismatch——这正是切换服务器全挂的回归根源。
enum LooseDecoding {
    static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZ"
        return formatter
    }()

    static let fallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = isoDateFormatter.date(from: raw) ?? fallbackFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期 \(raw)")
        }
        return decoder
    }
}

/// 宽松解析出来的条目数组（`/Items/Latest` 是裸数组而非 QueryResult 信封）。
extension Array where Element == MediaItem {
    /// 从裸数组 JSON 构造：洗白后按 SDK DTO 解码再走域映射。
    static func looseItems(from data: Data) throws -> [MediaItem] {
        let sanitized = EmbySanitizer.sanitize(data)
        let dtos = try LooseDecoding.decoder.decode([BaseItemDto].self, from: sanitized)
        return dtos.map(\.domainItem)
    }
}

extension Data {
    /// 洗白后按 SDK `BaseItemDtoQueryResult` 信封解码（`/UserViews` 等）。
    func looseQueryResult() throws -> BaseItemDtoQueryResult {
        let sanitized = EmbySanitizer.sanitize(self)
        return try LooseDecoding.decoder.decode(BaseItemDtoQueryResult.self, from: sanitized)
    }
}
