import Foundation

/// 媒体条目：Jellyfin `BaseItemDto` 映射出来的纯值类型，UI 只认这个。
/// 刻意不含 URL —— 图片 / 流地址由 JellyfinKit 结合服务器地址现场拼。
public struct MediaItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case movie, series, season, episode, boxSet
        case musicAlbum, musicArtist, audio, book, photo
        case folder, playlist, other
    }

    /// 服务端的播放进度快照。
    public struct PlayState: Hashable, Sendable {
        public var played: Bool
        /// 已看比例，**0–1**（0.375 = 37.5%）。Jellyfin 的 PlayedPercentage 是 0–100，映射层已除以 100。
        public var percentage: Double
        /// 服务端 `PlaybackPositionTicks`（1 tick = 100 ns）换算出的秒。
        public var positionSeconds: Double
        public var unplayedCount: Int?

        public init(played: Bool, percentage: Double, positionSeconds: Double, unplayedCount: Int? = nil) {
            self.played = played
            self.percentage = percentage
            self.positionSeconds = positionSeconds
            self.unplayedCount = unplayedCount
        }
    }

    /// 演员 / 导演等关联人物。
    public struct Person: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var role: String?
        /// "Actor" / "Director" …；演员列表 UI 只显示 Actor。
        public var kind: String

        public init(id: String, name: String, role: String? = nil, kind: String) {
            self.id = id
            self.name = name
            self.role = role
            self.kind = kind
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var overview: String?
    public var year: Int?
    /// 秒。剧集的 `runTimeTicks` 是单集时长。
    public var runtimeSeconds: Double?
    public var genres: [String]
    /// 豆瓣/TMDB 式评分（10 分制）。
    public var communityRating: Double?
    /// 分级，如 "PG-13"。
    public var officialRating: String?

    // 剧集族谱
    public var seriesID: String?
    public var seriesName: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    public var playState: PlayState?
    public var cast: [Person]
    /// 季数（Series 的 childCount）或集数（Season），侧栏角标用。
    public var childCount: Int?

    /// 图像 tag：变了说明图片换了，用它当 URL 的一部分让缓存自动失效。
    public var primaryImageTag: String?
    /// 分集剧照常用的 Thumb 图像 tag。
    public var thumbImageTag: String?
    public var backdropImageTag: String?

    public init(
        id: String,
        name: String,
        kind: Kind,
        overview: String? = nil,
        year: Int? = nil,
        runtimeSeconds: Double? = nil,
        genres: [String] = [],
        communityRating: Double? = nil,
        officialRating: String? = nil,
        seriesID: String? = nil,
        seriesName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        playState: PlayState? = nil,
        cast: [Person] = [],
        childCount: Int? = nil,
        primaryImageTag: String? = nil,
        thumbImageTag: String? = nil,
        backdropImageTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.overview = overview
        self.year = year
        self.runtimeSeconds = runtimeSeconds
        self.genres = genres
        self.communityRating = communityRating
        self.officialRating = officialRating
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.playState = playState
        self.cast = cast
        self.childCount = childCount
        self.primaryImageTag = primaryImageTag
        self.thumbImageTag = thumbImageTag
        self.backdropImageTag = backdropImageTag
    }

    /// 「S1E4」这样的集标，非剧集条目返回 nil。
    public var episodeLabel: String? {
        guard kind == .episode, let episodeNumber else { return nil }
        if let seasonNumber {
            return "S\(seasonNumber)E\(episodeNumber)"
        }
        return "E\(episodeNumber)"
    }
}

/// 媒体库（Jellyfin 的 UserView / CollectionFolder）。
public struct MediaLibrary: Identifiable, Hashable, Sendable {
    public enum CollectionType: String, Hashable, Sendable {
        case movies, tvshows, music, musicvideos, homevideos, boxsets, books, photos
        case playlists, folders, livetv, unknown
    }

    public var id: String
    public var name: String
    public var collectionType: CollectionType

    public init(id: String, name: String, collectionType: CollectionType) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
    }
}
