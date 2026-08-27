import Foundation
import JellyfinAPI

/// Emby 响应的“洗白”层。
///
/// Emby 是 Jellyfin 的前身但字段值集更宽：`CollectionType` / `Type` 等字段会出
/// jellyfin-sdk-swift 枚举不认的值（如 `"mixed"`、`"CollectionFolder"`），
/// `UserData` 可能缺 SDK 必填的 `Key`——强类型解码整包炸成
/// "The data couldn't be read because it is missing"。
/// `JellyfinServer.send` 在 SDK 解码前统一过这里把脏值替换掉，其余字段原样
/// 透传——对 Jellyfin 标准响应是无害透传，既有 Mapping 逻辑一行不动。
enum EmbySanitizer {
    /// SDK `CollectionType` 认的值；Emby 会输出 "BoxSets" 这类大小写变体，
    /// 归一化成小写 rawValue；未知值（如 "mixed"）洗掉 → 域模型 .unknown → 浏览层过滤。
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

    /// `Type` 这字段名被多个结构共用：People[].Type 是 PersonKind、
    /// MediaStream[].Type 是 MediaStreamType、MediaSegments[].Type 是
    /// MediaSegmentType。这些值 SDK 本来就能解，**绝不能洗**——否则"Actor"
    /// 被压成"Folder"直接炸掉演员表。
    private static let knownNonItemTypeValues: Set<String> = [
        // PersonKind（小写）
        "unknown", "actor", "director", "composer", "writer", "gueststar", "producer",
        "conductor", "lyricist", "arranger", "engineer", "mixer", "remixer", "creator",
        "artist", "albumartist", "author", "illustrator", "penciller", "inker",
        "colorist", "letterer", "coverartist", "editor", "translator", "narrator",
        // MediaStreamType / MediaSegmentType（小写）
        "audio", "video", "subtitle", "embeddedimage", "data", "lyric",
        "commercial", "preview", "recap", "outro", "intro",
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
            // CollectionType 只出现在媒体库/合集对象上，全局安全。
            if let type = dict["CollectionType"] as? String {
                if knownCollectionTypes.contains(type.lowercased()) {
                    cleaned["CollectionType"] = type.lowercased()
                } else {
                    cleaned["CollectionType"] = nil
                }
            }
            // `Type` 字段在 People[].Type("Actor") / MediaStream.Type("Subtitle") /
            // MediaSegment.Type("Intro") 等结构里也同名且语义不同。SDK 认的值
            // （nonItemTypeValues）原样放行；只有条目形态（带 Id+Name）且值
            // 完全不被任何枚举认识的才压成 Folder。
            if let type = dict["Type"] as? String,
               !knownItemKinds.contains(type),
               !knownNonItemTypeValues.contains(type.lowercased()),
               dict["Id"] != nil, dict["Name"] != nil {
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
            // MediaSources[]（MediaSourceInfo）的 Type 是 MediaSourceType
            // （Default/Grouping/Placeholder）。Emby 会给直连源报 "Folder"
            // 等值，SDK 解不了——洗成 Default（即普通可播放源的语义）。
            if let type = cleaned["Type"] as? String,
               type != "Default", type != "Grouping", type != "Placeholder",
               cleaned["MediaStreams"] != nil {
                cleaned["Type"] = "Default"
            }
            // NameIDPair 形态（Id+Name 同级）的对象在 Emby 上 Id 可能返回数字
            // （Jellyfin 是字符串）：GenreItems / Studios / Networks 全是
            // [NameIDPair]，SDK 的 id 是 String——数字统一字符串化。
            // 特意不碰其它名字的数字字段（年份、索引号等必须是数字）。
            if cleaned["Name"] != nil, let numID = cleaned["Id"] as? NSNumber {
                cleaned["Id"] = numID.stringValue
            }
            return cleaned.mapValues { sanitizeValue($0) }
            return cleaned.mapValues { sanitizeValue($0) }
        case let array as [Any]:
            return array.map { sanitizeValue($0) }
        default:
            return value
        }
    }
}

/// 宽松解码配置：与 jellyfin-sdk-swift 的 JellyfinClient 相同的 ISO8601 日期策略。
/// sanitizer 后的二次解码必须用同一配置，否则带 DateCreated 的响应会炸 typeMismatch。
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
