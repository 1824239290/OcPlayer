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
    /// MediaSegmentType、MediaSources[].Type 是 MediaSourceType。这些值 SDK
    /// 本来就能解，**绝不能洗**——否则"Actor"被压成"Folder"直接炸掉演员表；
    /// MediaSourceType 的 "Default" 也会被 Rule 1 压回 "Folder"（SDK 的
    /// MediaSourceType 没有 Folder case），导致 PlaybackInfo / 详情解码失败。
    private static let knownNonItemTypeValues: Set<String> = [
        // PersonKind（小写）
        "unknown", "actor", "director", "composer", "writer", "gueststar", "producer",
        "conductor", "lyricist", "arranger", "engineer", "mixer", "remixer", "creator",
        "artist", "albumartist", "author", "illustrator", "penciller", "inker",
        "colorist", "letterer", "coverartist", "editor", "translator", "narrator",
        // MediaStreamType / MediaSegmentType（小写）
        "audio", "video", "subtitle", "embeddedimage", "data", "lyric",
        "commercial", "preview", "recap", "outro", "intro",
        // MediaSourceType（小写）：Default / Grouping / Placeholder。
        // MediaSources handler 把 Emby 报的杂值洗成 "Default" 后，外层
        // mapValues 递归回来 Rule 1 不能再碰它——否则压回 Folder 炸解码。
        "default", "grouping", "placeholder",
    ]

    /// SDK `VideoRange` 认的值（Unknown/SDR/HDR）。Emby 兼容层会把杜比视界直接
    /// 写进 `VideoRange`（"DolbyVision"），SDK 解不了 —— `/Items/{id}/PlaybackInfo`
    /// 整包炸，调用方只能回退直连（issue #3：日志里 7 次），杜比片源拿不到
    /// 服务端协商的播放会话。
    ///
    /// 归一成 "HDR"：**这不是我们的发明，而是 Jellyfin 官方的既定语义**。
    /// 上游 `MediaStream.GetVideoColorRange()` 对杜比视界返回的就是
    /// `(VideoRange.HDR, VideoRangeType.DOVI*)` —— 粗粒度归 HDR、细粒度放
    /// VideoRangeType（如 DOVIWithEL 走 `(HDR, DOVIWithEL)`、DOVIWithSDR 走
    /// `(SDR, DOVIWithSDR)`）。Emby 只是把粗粒度字段写成了更细的 "DolbyVision"，
    /// 这里把它还原成上游语义。
    ///
    /// **关键约束**：这只洗 `VideoRange`，绝不能连带动 `VideoRangeType` ——
    /// App 的杜比判定（`PlaybackSessionContext.isDolbyVision`）只看
    /// `VideoRangeType` 的 DOVI 前缀，而 SDK 的 `VideoRangeType` 有完整 DOVI
    /// 系列 case，"DOVIWithEL" 等值本来就能解、原样透传即可。洗 `VideoRange`
    /// 救解码，靠 `VideoRangeType` 保真值域，两者分工不能混。
    private static let knownVideoRanges: Set<String> = ["unknown", "sdr", "hdr"]

    /// SDK `MetadataField` 认的值（`/Items` 列表响应里 `LockedFields` 的元素）。
    /// Emby 会给出 "SortName" 这类 SDK 枚举外的字段名 —— 它在 `/Items` 里，
    /// 一条脏值就让**整个媒体库列表**解码失败（issue #3：日志里 1 次
    /// "媒体库列表加载失败"）。
    ///
    /// 该字段表示「哪些元数据字段被锁定不允许刷新」，App 侧目前无消费方，
    /// 因此未知项直接剔除：信息损失为零，却救回整个列表。
    private static let knownMetadataFields: Set<String> = [
        "cast", "genres", "productionlocations", "studios", "tags",
        "name", "overview", "runtime", "officialrating",
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
            // VideoRange：Emby 报 "DolbyVision" 而 SDK 只认 Unknown/SDR/HDR。
            // 这个键名在 MediaStream 里是独占的（不像 Type 那样被多结构共用），
            // 所以按 key 全局处理是安全的，不必限定子树。
            // **只洗 VideoRange，绝不碰 VideoRangeType** —— 后者是杜比判定的
            // 唯一输入，且 SDK 的 VideoRangeType 有完整 DOVI 系列 case，本就能解。
            if let range = cleaned["VideoRange"] as? String {
                switch range.lowercased() {
                case "sdr": cleaned["VideoRange"] = "SDR"
                case "hdr": cleaned["VideoRange"] = "HDR"
                case "unknown": cleaned["VideoRange"] = "Unknown"
                // 未知值（DolbyVision / DolbyVisionWithHDR …）一律按 HDR 处理：
                // 与 HDR 同族，语义最接近，也避免误报 SDR。幂等。
                default: cleaned["VideoRange"] = "HDR"
                }
            }
            // LockedFields：Emby 会带 SDK `MetadataField` 枚举外的字段名
            // （如 "SortName"），它在 /Items 列表响应里，一条脏值炸整个列表。
            // 这是**数组元素过滤**（不是替换）：剔除未知项、保留认识的。
            // 幂等：过滤后元素全在 knownMetadataFields 里，再跑一遍无变化。
            if let locked = cleaned["LockedFields"] as? [Any] {
                cleaned["LockedFields"] = locked.filter { value in
                    guard let name = value as? String else { return false }
                    return knownMetadataFields.contains(name.lowercased())
                }
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
            // 注意只能作用于 MediaSources[] 内部：顶层 BaseItemDto 自己也有
            // MediaStreams，靠「有 MediaStreams」判定会把条目的 Type（Episode/
            // Movie 等 BaseItemKind）误洗成 "Default"，SDK 没有这个 case，
            // 整个详情解码炸成 "Cannot initialize BaseItemKind from Default"，
            // 章节列表 / 条目详情全挂。这里按 key 精确处理子树。
            //
            // 同一子树里还要洗 MediaStreams[].Type（MediaStreamType）：Emby 给
            // MKV 内嵌字体（附件）报 "Attachment"，SDK 的 MediaStreamType 没有
            // 这个 case —— PlaybackInfo 整包炸（issue #3：日志里 4 次，整季不可播）。
            // 归一成 SDK 已有的 "Data"（非音视频的非媒体流），附件流本身保留，
            // 只修类型值。同理按 key 精确限定，不碰顶层 Type。
            if var sources = cleaned["MediaSources"] as? [Any] {
                for index in sources.indices {
                    guard var source = sources[index] as? [String: Any] else { continue }
                    if let type = source["Type"] as? String,
                       type != "Default", type != "Grouping", type != "Placeholder" {
                        source["Type"] = "Default"
                    }
                    if var streams = source["MediaStreams"] as? [Any] {
                        for streamIndex in streams.indices {
                            guard var stream = streams[streamIndex] as? [String: Any] else { continue }
                            // 只在值不是 SDK 认的 MediaStreamType 时才动手；
                            // "Data" 幂等（再跑一遍仍是 Data）。
                            if let streamType = stream["Type"] as? String,
                               !knownNonItemTypeValues.contains(streamType.lowercased()) {
                                stream["Type"] = "Data"
                            }
                            streams[streamIndex] = stream
                        }
                        source["MediaStreams"] = streams
                    }
                    sources[index] = source
                }
                cleaned["MediaSources"] = sources
            }
            // NameIDPair 形态（Id+Name 同级）的对象在 Emby 上 Id 可能返回数字
            // （Jellyfin 是字符串）：GenreItems / Studios / Networks 全是
            // [NameIDPair]，SDK 的 id 是 String——数字统一字符串化。
            // 特意不碰其它名字的数字字段（年份、索引号等必须是数字）。
            if cleaned["Name"] != nil, let numID = cleaned["Id"] as? NSNumber {
                cleaned["Id"] = numID.stringValue
            }
            // MediaSources 子树已在上面按 key 精确处理（含内部递归 sanitize）；
            // mapValues 会对它再过一遍 sanitizeValue，但对已洗过的字典幂等无害。
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
    /// 全部静态复用：原先 `static var decoder` 是计算属性，每个请求新建
    /// JSONDecoder，每个日期字段跑两遍 DateFormatter（慢且覆盖窄——`Z` 模式
    /// 认不得 `+08:00` 带冒号偏移，一条带时区偏移的日期炸整包解码）。
    ///
    /// 热路径用 ISO8601DateFormatter（快一个量级）：带小数秒与不带各一；
    /// `.withInternetDateTime` 只认 RFC3339 标准偏移（`Z`/`+08:00`），
    /// `+0800` 这类无冒号写法由末位的 DateFormatter 兜底。
    // ISO8601DateFormatter/DateFormatter 均为文档保证的线程安全类型（DateFormatter
    // 自 iOS 7/macOS 10.9 起），跨线程复用安全，nonisolated(unsafe) 只豁免检查。
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoBasic = ISO8601DateFormatter()

    nonisolated(unsafe) private static let legacyFractional: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSZ"
        return formatter
    }()

    nonisolated(unsafe) private static let legacyBasic: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = isoFractional.date(from: raw)
                ?? isoBasic.date(from: raw)
                ?? legacyFractional.date(from: raw)
                ?? legacyBasic.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期 \(raw)")
        }
        return decoder
    }()
}
