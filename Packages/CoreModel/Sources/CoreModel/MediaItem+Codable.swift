import Foundation

// `MediaItem` / `MediaLibrary` 及其嵌套值的持久化编解码。
//
// ## 为什么解码是「宽容」的
//
// 这些类型是**会持续长大的**（`MediaItem` 已有 ~35 个字段且还在加）。若直接用
// 合成的 `Codable`：新增一个非可选字段，旧 payload 就解不出来；新增可选字段虽
// 能解，但只要有人把某个字段从可选改成非可选，同样炸。而这里的 payload 是**缓存**——
// 解不出来的正确反应是「当作没缓存过，重拉一次」，绝不能是抛错上浮。
//
// 所以 `init(from:)` 对每个字段都用 `decodeIfPresent(...) ?? 默认值`：
// **缺字段 → 取默认值**，旧 payload 永远能解。这样「加字段」完全不需要迁移。
// 真出现语义不兼容时，靠 `Schema.payloadVersion` 整体作废，而不是在这里做版本分支。
//
// 编码一侧是常规合成行为（全部字段都写出去）。

// MARK: - MediaItem

extension MediaItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, originalTitle, kind, overview, year, runtimeSeconds, genres
        case communityRating, officialRating
        case seriesID, seriesName, seasonID, seasonName, seasonNumber, episodeNumber
        case playState, cast, childCount
        case primaryImageTag, thumbImageTag, backdropImageTag, logoImageTag, parentLogoItemID
        case seriesThumbImageTag, parentThumbItemID, parentThumbImageTag
        case parentBackdropItemID, parentBackdropImageTag
        case parentPrimaryImageItemID, parentPrimaryImageTag, seriesPrimaryImageTag
        case tmdbID, malID, anilistID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id / name / kind 是「条目身份」：缺了就没有缓存意义，让上层当未命中处理。
        // 但它们**极少**缺失，且这里仍给兜底值而不是抛错——抛错会让整条 rail 读不出来。
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名",
            originalTitle: try c.decodeIfPresent(String.self, forKey: .originalTitle),
            kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other,
            overview: try c.decodeIfPresent(String.self, forKey: .overview),
            year: try c.decodeIfPresent(Int.self, forKey: .year),
            runtimeSeconds: try c.decodeIfPresent(Double.self, forKey: .runtimeSeconds),
            genres: try c.decodeIfPresent([String].self, forKey: .genres) ?? [],
            communityRating: try c.decodeIfPresent(Double.self, forKey: .communityRating),
            officialRating: try c.decodeIfPresent(String.self, forKey: .officialRating),
            seriesID: try c.decodeIfPresent(String.self, forKey: .seriesID),
            seriesName: try c.decodeIfPresent(String.self, forKey: .seriesName),
            seasonID: try c.decodeIfPresent(String.self, forKey: .seasonID),
            seasonName: try c.decodeIfPresent(String.self, forKey: .seasonName),
            seasonNumber: try c.decodeIfPresent(Int.self, forKey: .seasonNumber),
            episodeNumber: try c.decodeIfPresent(Int.self, forKey: .episodeNumber),
            playState: try c.decodeIfPresent(PlayState.self, forKey: .playState),
            cast: try c.decodeIfPresent([Person].self, forKey: .cast) ?? [],
            childCount: try c.decodeIfPresent(Int.self, forKey: .childCount),
            primaryImageTag: try c.decodeIfPresent(String.self, forKey: .primaryImageTag),
            thumbImageTag: try c.decodeIfPresent(String.self, forKey: .thumbImageTag),
            backdropImageTag: try c.decodeIfPresent(String.self, forKey: .backdropImageTag),
            logoImageTag: try c.decodeIfPresent(String.self, forKey: .logoImageTag),
            parentLogoItemID: try c.decodeIfPresent(String.self, forKey: .parentLogoItemID),
            seriesThumbImageTag: try c.decodeIfPresent(String.self, forKey: .seriesThumbImageTag),
            parentThumbItemID: try c.decodeIfPresent(String.self, forKey: .parentThumbItemID),
            parentThumbImageTag: try c.decodeIfPresent(String.self, forKey: .parentThumbImageTag),
            parentBackdropItemID: try c.decodeIfPresent(String.self, forKey: .parentBackdropItemID),
            parentBackdropImageTag: try c.decodeIfPresent(String.self, forKey: .parentBackdropImageTag),
            parentPrimaryImageItemID: try c.decodeIfPresent(String.self, forKey: .parentPrimaryImageItemID),
            parentPrimaryImageTag: try c.decodeIfPresent(String.self, forKey: .parentPrimaryImageTag),
            seriesPrimaryImageTag: try c.decodeIfPresent(String.self, forKey: .seriesPrimaryImageTag),
            tmdbID: try c.decodeIfPresent(String.self, forKey: .tmdbID),
            malID: try c.decodeIfPresent(String.self, forKey: .malID),
            anilistID: try c.decodeIfPresent(String.self, forKey: .anilistID)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(originalTitle, forKey: .originalTitle)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(runtimeSeconds, forKey: .runtimeSeconds)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(communityRating, forKey: .communityRating)
        try c.encodeIfPresent(officialRating, forKey: .officialRating)
        try c.encodeIfPresent(seriesID, forKey: .seriesID)
        try c.encodeIfPresent(seriesName, forKey: .seriesName)
        try c.encodeIfPresent(seasonID, forKey: .seasonID)
        try c.encodeIfPresent(seasonName, forKey: .seasonName)
        try c.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try c.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try c.encodeIfPresent(playState, forKey: .playState)
        try c.encode(cast, forKey: .cast)
        try c.encodeIfPresent(childCount, forKey: .childCount)
        try c.encodeIfPresent(primaryImageTag, forKey: .primaryImageTag)
        try c.encodeIfPresent(thumbImageTag, forKey: .thumbImageTag)
        try c.encodeIfPresent(backdropImageTag, forKey: .backdropImageTag)
        try c.encodeIfPresent(logoImageTag, forKey: .logoImageTag)
        try c.encodeIfPresent(parentLogoItemID, forKey: .parentLogoItemID)
        try c.encodeIfPresent(seriesThumbImageTag, forKey: .seriesThumbImageTag)
        try c.encodeIfPresent(parentThumbItemID, forKey: .parentThumbItemID)
        try c.encodeIfPresent(parentThumbImageTag, forKey: .parentThumbImageTag)
        try c.encodeIfPresent(parentBackdropItemID, forKey: .parentBackdropItemID)
        try c.encodeIfPresent(parentBackdropImageTag, forKey: .parentBackdropImageTag)
        try c.encodeIfPresent(parentPrimaryImageItemID, forKey: .parentPrimaryImageItemID)
        try c.encodeIfPresent(parentPrimaryImageTag, forKey: .parentPrimaryImageTag)
        try c.encodeIfPresent(seriesPrimaryImageTag, forKey: .seriesPrimaryImageTag)
        try c.encodeIfPresent(tmdbID, forKey: .tmdbID)
        try c.encodeIfPresent(malID, forKey: .malID)
        try c.encodeIfPresent(anilistID, forKey: .anilistID)
    }
}

// MARK: - 嵌套值

extension MediaItem.Kind: Codable {
    /// 服务端将来报出新的 `Type` 串时落到 `.other`，而不是让整个 payload 解不出来
    /// （`EmbyServer` 的宽松 DTO 就是为同类问题存在的，见 `MediaServer` 的类型注释）。
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MediaItem.Kind(rawValue: raw) ?? .other
    }
}

extension MediaItem.PlayState: Codable {
    private enum CodingKeys: String, CodingKey {
        case played, percentage, positionSeconds, unplayedCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            played: try c.decodeIfPresent(Bool.self, forKey: .played) ?? false,
            percentage: try c.decodeIfPresent(Double.self, forKey: .percentage) ?? 0,
            positionSeconds: try c.decodeIfPresent(Double.self, forKey: .positionSeconds) ?? 0,
            unplayedCount: try c.decodeIfPresent(Int.self, forKey: .unplayedCount)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(played, forKey: .played)
        try c.encode(percentage, forKey: .percentage)
        try c.encode(positionSeconds, forKey: .positionSeconds)
        try c.encodeIfPresent(unplayedCount, forKey: .unplayedCount)
    }
}

extension MediaItem.Person: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, role, kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            role: try c.decodeIfPresent(String.self, forKey: .role),
            kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encode(kind, forKey: .kind)
    }
}

// MARK: - MediaLibrary

extension MediaLibrary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, collectionType, primaryImageTag
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            collectionType: try c.decodeIfPresent(CollectionType.self, forKey: .collectionType) ?? .unknown,
            primaryImageTag: try c.decodeIfPresent(String.self, forKey: .primaryImageTag)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(collectionType, forKey: .collectionType)
        try c.encodeIfPresent(primaryImageTag, forKey: .primaryImageTag)
    }
}

extension MediaLibrary.CollectionType: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MediaLibrary.CollectionType(rawValue: raw) ?? .unknown
    }
}
