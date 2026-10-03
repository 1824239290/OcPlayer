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
    /// 服务端元数据里的原生标题（Jellyfin OriginalTitle；番剧库多为日文原名）。
    /// AniSkip 的 MAL ID 解析等标题搜索用它补中文标题搜不中的坑。
    public var originalTitle: String?
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
    public var seasonID: String?
    public var seasonName: String?
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
    /// 艺术字标题 Logo (ClearLogo) 图像 tag。
    public var logoImageTag: String?
    /// 继承自父级剧集的 Logo 条目 ID（用于季或分集回溯主系列的 Logo）。
    public var parentLogoItemID: String?
    // 下面这组父级 / 剧集图字段只服务首页「继续播放 / 接下来看」剧照卡的
    // Jellyfin Web 同款取图链（见 `homeStillImageChoice`）。详情页分集列表
    // 刻意不用父级图，所以不并入上面四个自身图 tag。
    /// 剧集条目自己的 Thumb 图 tag（较少见，通常是季/剧才有横版图）。
    public var seriesThumbImageTag: String?
    /// 父级（剧集/季）Thumb 横版图的条目 ID 与 tag，两者服务端成对下发。
    public var parentThumbItemID: String?
    public var parentThumbImageTag: String?
    /// 父级 Backdrop 的条目 ID 与 tag（取第一张）。
    public var parentBackdropItemID: String?
    public var parentBackdropImageTag: String?
    /// 父级 Primary 海报的条目 ID 与 tag。
    public var parentPrimaryImageItemID: String?
    public var parentPrimaryImageTag: String?
    /// 所属剧集的 Primary 海报 tag（分集自身 primary 缺图时取图链回溯用；
    /// 非剧集条目仍在映射层折进自身 primary，这里额外保留一份原值）。
    public var seriesPrimaryImageTag: String?

    /// Jellyfin ProviderIds 里的 Tmdb id（外部服务对接用，如 MoviePilot 资源搜索）。
    public var tmdbID: String?
    /// ProviderIds 里的 MyAnimeList / AniList id（AniSkip 跳过片头数据源用）。
    /// 依赖媒体库元数据插件，机会性存在；缺了走标题搜索映射。
    public var malID: String?
    public var anilistID: String?

    public init(
        id: String,
        name: String,
        originalTitle: String? = nil,
        kind: Kind,
        overview: String? = nil,
        year: Int? = nil,
        runtimeSeconds: Double? = nil,
        genres: [String] = [],
        communityRating: Double? = nil,
        officialRating: String? = nil,
        seriesID: String? = nil,
        seriesName: String? = nil,
        seasonID: String? = nil,
        seasonName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        playState: PlayState? = nil,
        cast: [Person] = [],
        childCount: Int? = nil,
        primaryImageTag: String? = nil,
        thumbImageTag: String? = nil,
        backdropImageTag: String? = nil,
        logoImageTag: String? = nil,
        parentLogoItemID: String? = nil,
        seriesThumbImageTag: String? = nil,
        parentThumbItemID: String? = nil,
        parentThumbImageTag: String? = nil,
        parentBackdropItemID: String? = nil,
        parentBackdropImageTag: String? = nil,
        parentPrimaryImageItemID: String? = nil,
        parentPrimaryImageTag: String? = nil,
        seriesPrimaryImageTag: String? = nil,
        tmdbID: String? = nil,
        malID: String? = nil,
        anilistID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.originalTitle = originalTitle
        self.kind = kind
        self.overview = overview
        self.year = year
        self.runtimeSeconds = runtimeSeconds
        self.genres = genres
        self.communityRating = communityRating
        self.officialRating = officialRating
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.seasonID = seasonID
        self.seasonName = seasonName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.playState = playState
        self.cast = cast
        self.childCount = childCount
        self.primaryImageTag = primaryImageTag
        self.thumbImageTag = thumbImageTag
        self.backdropImageTag = backdropImageTag
        self.logoImageTag = logoImageTag
        self.parentLogoItemID = parentLogoItemID
        self.seriesThumbImageTag = seriesThumbImageTag
        self.parentThumbItemID = parentThumbItemID
        self.parentThumbImageTag = parentThumbImageTag
        self.parentBackdropItemID = parentBackdropItemID
        self.parentBackdropImageTag = parentBackdropImageTag
        self.parentPrimaryImageItemID = parentPrimaryImageItemID
        self.parentPrimaryImageTag = parentPrimaryImageTag
        self.seriesPrimaryImageTag = seriesPrimaryImageTag
        self.tmdbID = tmdbID
        self.malID = malID
        self.anilistID = anilistID
    }

    /// 哈希只取 id + kind + name：合成实现要哈希全部 ~25 个字段（含长文
    /// overview 与 cast 数组），大库的 SwiftUI diff / 集合操作是纯浪费。
    /// 相等判定仍是全字段（== 未动）；id 唯一，碰撞率不会因此上升。
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
        hasher.combine(name)
    }

    /// 获取 Logo 图像对应的有效条目 ID（若自身无 Logo 且继承了父级则指向父级 ID，否则为自身 ID）。
    public var logoItemID: String {
        parentLogoItemID ?? id
    }

    /// 「S1E4」这样的集标，非剧集条目返回 nil。
    public var episodeLabel: String? {
        guard kind == .episode, let episodeNumber else { return nil }
        if let seasonNumber {
            return "S\(seasonNumber)E\(episodeNumber)"
        }
        return "E\(episodeNumber)"
    }

    /// 首页「继续播放 / 接下来看」剧照卡的取图决策。
    ///
    /// 逐步复刻 Jellyfin Web cardBuilder `getImgInfo` 在 `preferThumb: true`、
    /// `inheritThumb` 默认开启下的回退链（官方这两个板块正是这组参数）：
    /// Thumb(自己) → Thumb(剧) → Thumb(父) → Backdrop(自己) → Backdrop(父,仅分集)
    /// → Primary(自己) → Primary(剧) → Primary(父)。横版图优先于海报，因为卡片
    /// 是 16:9 画幅；没有横版图时官方同样会把海报居中裁成 16:9。
    /// 实测服务器对分集恒下发 `ParentThumb*`（剧集横版图），所以分集默认展示
    /// 剧集剧照而非分集截图 —— 与官方默认一致。
    public var homeStillImageChoice: StillImageChoice? {
        if let tag = thumbImageTag {
            return StillImageChoice(itemID: id, kind: .thumb, tag: tag)
        }
        if let seriesID, let tag = seriesThumbImageTag {
            return StillImageChoice(itemID: seriesID, kind: .thumb, tag: tag)
        }
        if let tag = parentThumbImageTag, let target = parentThumbItemID ?? seriesID {
            return StillImageChoice(itemID: target, kind: .thumb, tag: tag)
        }
        if let tag = backdropImageTag {
            return StillImageChoice(itemID: id, kind: .backdrop, tag: tag)
        }
        if kind == .episode, let tag = parentBackdropImageTag,
           let target = parentBackdropItemID ?? seriesID {
            return StillImageChoice(itemID: target, kind: .backdrop, tag: tag)
        }
        if let tag = primaryImageTag {
            return StillImageChoice(itemID: id, kind: .primary, tag: tag)
        }
        if let seriesID, let tag = seriesPrimaryImageTag {
            return StillImageChoice(itemID: seriesID, kind: .primary, tag: tag)
        }
        if let tag = parentPrimaryImageTag, let target = parentPrimaryImageItemID {
            return StillImageChoice(itemID: target, kind: .primary, tag: tag)
        }
        return nil
    }
}

/// 首页剧照卡的取图结果：指向哪个条目的哪类图，UI 层据此拼图片 URL。
public struct StillImageChoice: Hashable, Sendable {
    public enum ImageKind: Sendable, Hashable {
        case primary, thumb, backdrop
    }

    public var itemID: String
    public var kind: ImageKind
    /// 图像 tag，进 URL 让「图换了 → URL 变了 → 缓存失效」。
    public var tag: String

    public init(itemID: String, kind: ImageKind, tag: String) {
        self.itemID = itemID
        self.kind = kind
        self.tag = tag
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
    /// Primary 封面图 tag；拼图片 URL 时带上，图更新后磁盘缓存自然失效。
    public var primaryImageTag: String?

    public init(id: String, name: String, collectionType: CollectionType, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
        self.primaryImageTag = primaryImageTag
    }
}
