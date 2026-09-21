import Foundation

// Emby 响应的宽松 DTO。
//
// **值域刻意放宽**：所有枚举类字段（`Type` / `CollectionType` / `VideoRange` /
// `MediaStreams[].Type` / `LockedFields` …）一律收成 `String?`，不建 Swift 枚举。
// 这不是偷懒，而是这一层存在的全部理由：Emby 是 Jellyfin 的前身但值域更宽 ——
// `VideoRange` 会报 "DolbyVision"、`MediaStreams[].Type` 会报 "Attachment"（MKV
// 内嵌字体）、`LockedFields` 会报 "SortName"、`Type` 会报 "CollectionFolder"。
// 这些值超出 Jellyfin SDK 的枚举值域，用 SDK 的强类型 DTO 解会**整包炸**（历史
// 实现为此养了一层 200 行 JSON 洗白）。收成字符串后，脏值在映射层落到
// `.unknown` / `.other`，或者干脆不匹配任何分支被过滤掉，响应始终解得出来。
//
// 每个字段都是 Optional：缺字段不报错，缺语义由 Adapter 的默认值兜底。
//
// ponytail: 这里只做**值域**宽松，不做**类型**宽松 —— 若某字段实际会以字符串
// 发数字（当前未见），再给那个字段加一层数字/字符串双收。

struct EmbyItemDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    /// 条目类型。Emby 会多出 CollectionFolder 等 Jellyfin 没有的值。
    var type: String?
    /// 媒体库的集合类型（只在 UserView / CollectionFolder 上有意义）。
    /// Emby 会发 "BoxSets" 这类大小写变体，映射层做大小写归一。
    var collectionType: String?
    var overview: String?
    var productionYear: Int?
    var runTimeTicks: Int?
    var genres: [String]?
    var communityRating: Double?
    var officialRating: String?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var parentIndexNumber: Int?
    var indexNumber: Int?
    var childCount: Int?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var albumPrimaryImageTag: String?
    var seriesPrimaryImageTag: String?
    var parentLogoImageTag: String?
    var parentLogoItemId: String?
    var providerIds: [String: String]?
    var userData: EmbyUserDataDTO?
    var people: [EmbyPersonDTO]?
    var chapters: [EmbyChapterDTO]?
    var mediaSources: [EmbyMediaSourceDTO]?
    var container: String?
}

/// `/Items` 与 `/Users/{id}/Views` 这类 QueryResult 信封。
struct EmbyQueryResultDTO: Decodable, Sendable {
    var items: [EmbyItemDTO]?
    var totalRecordCount: Int?
}

/// 条目上的 `UserData`，也是「标记已看 / 取消已看」接口的响应体。
///
/// **注意属性名**：已看标志在 wire 上是 `Played`（不是 `IsPlayed` —— 那是
/// `BaseItemDto` 顶层别处的拼法），所以这里叫 `played`。名字必须写成
/// **首字母降位之后**的形态 —— `keyDecodingStrategy` 会先把 JSON 键转成小写
/// 首字母再和属性名比对，任何显式 `CodingKeys` 都得按这个转换后的形态写。
struct EmbyUserDataDTO: Decodable, Sendable {
    var played: Bool?
    /// 0–100 的百分数（与 Jellyfin 同口径）。Emby 可能发整数或小数，都收。
    var playedPercentage: Double?
    var playbackPositionTicks: Int?
    var unplayedItemCount: Int?
}

struct EmbyPersonDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var role: String?
    /// PersonKind。Emby 会给 "Actor" / "Director" 等，SDK 之外的值原样透传。
    var type: String?
}

struct EmbyChapterDTO: Decodable, Sendable {
    var name: String?
    var startPositionTicks: Int?
    var markerType: EmbyChapterMarker?
}

struct EmbyMediaSourceDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var path: String?
    var size: Int?
    var container: String?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var bitrate: Int?
    var runTimeTicks: Int?
    var mediaStreams: [EmbyMediaStreamDTO]?
}

struct EmbyMediaStreamDTO: Decodable, Sendable {
    /// MediaStreamType。Emby 会给 "Attachment"（MKV 内嵌字体）这类 SDK 没有的值 ——
    /// 收成字符串后它只是不匹配 Video/Audio/Subtitle 分支，被自然过滤掉。
    var type: String?
    var codec: String?
    var index: Int?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var averageFrameRate: Double?
    var realFrameRate: Double?
    var bitDepth: Int?
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorSpace: String?
    var colorRange: String?
    /// 杜比判定的唯一输入。Emby 会把 "DolbyVision" 写进 `VideoRange`（粗粒度，
    /// SDK 解不了），但 `VideoRangeType` 是细粒度且值域与 Jellyfin 一致 ——
    /// 原样收字符串，不归一，保住 DOVI 系列的真值。
    var videoRangeType: String?
    var profile: String?
    var isInterlaced: Bool?
    var channels: Int?
    var channelLayout: String?
    var sampleRate: Int?
    var language: String?
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
}

/// `/Users/AuthenticateByName` 的登录响应。只抽需要三样，其余字段类型波动全忽略。
struct EmbyAuthResultDTO: Decodable, Sendable {
    struct UserDTO: Decodable, Sendable {
        var id: String?
        var name: String?
    }

    var accessToken: String?
    var user: UserDTO?
}

/// `/System/Info/Public` 探活响应。
struct EmbyPublicSystemInfoDTO: Decodable, Sendable {
    var id: String?
    var serverName: String?
    var version: String?
    var productName: String?
}
