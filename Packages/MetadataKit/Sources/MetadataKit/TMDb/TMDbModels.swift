import Foundation

/// TMDb 响应模型。
///
/// 只声明**我们真的会用到**的字段：TMDb 的响应很大（`append_to_response` 之后
/// 一部剧的 payload 可达几百 KB），把不用的字段也解出来等于白白占内存与磁盘。
///
/// 解码一律**宽容**（`decodeIfPresent` + 默认值）：TMDb 的字段会增删，
/// 而解析失败意味着整条补全失败——比某个字段取到 nil 严重得多。

// MARK: - 媒体类型

/// TMDb 的实体类型。`season` / `episode` 不是顶层端点，靠父剧集 id + 季集号定位。
public enum TMDbMediaType: String, Sendable, Codable, CaseIterable {
    case movie
    case tv
    case season
    case episode
    /// TMDb 的**合集**（`/collection/{id}`）——「同一系列的多部电影」那层容器，
    /// 对应 Jellyfin / Emby 的合集（BoxSet）。**只装电影**：TMDb 没有剧集的合集概念。
    case collection

    /// 顶层详情端点路径段（季/集没有独立端点，走 `/tv/{id}/season/{n}`）。
    var endpointSegment: String? {
        switch self {
        case .movie: "movie"
        case .tv: "tv"
        case .collection: "collection"
        case .season, .episode: nil
        }
    }

    /// 搜索结果里的 `media_type` 字段（`/search/multi` 用）。
    public var searchResultKind: String {
        switch self {
        case .movie: "movie"
        case .tv: "tv"
        case .collection: "collection"
        case .season, .episode: "tv"
        }
    }
}

// MARK: - 详情

/// 一部电影 / 剧集的详情（含 `append_to_response` 带回来的关联块）。
public struct TMDbEntity: Sendable, Equatable, Codable {
    public var id: Int
    public var mediaType: TMDbMediaType
    /// 本地化标题（`title` 或 `name`）。可能为空串——那门语言没有翻译时 TMDb 就这么返回。
    public var title: String?
    /// 原始语言标题（`original_title` / `original_name`）。**永远非空**，是最后兜底。
    public var originalTitle: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var voteAverage: Double?
    public var genres: [String]
    public var cast: [CastMember]
    /// 剧集的季列表。
    public var seasons: [SeasonSummary]
    public var originalLanguage: String?
    public var imdbID: String?
    /// 内容分级（按 `language` 取一条，用于和 Jellyfin 的 officialRating 对齐）。
    public var contentRating: String?

    /// 这部电影**属于哪个 TMDb 合集**（电影详情里的 `belongs_to_collection.id`）。
    ///
    /// 这是把服务端的「合集」对到 TMDb 合集的**权威入口**：合集自己没有可用的
    /// `ProviderIds["Tmdb"]`（实测 Jellyfin 手工建的合集是空 Map），但它的成员电影
    /// 每一条都写着归属于哪个合集。见 `TMDbEnricher.refreshCollection`。
    ///
    /// **Optional 是有意的**：老缓存里没有这个键，`decodeIfPresent` 解成 nil
    /// （「这份数据没带这条信息」），不会因为加字段而让既有 payload 全部解不出来。
    public var collectionID: Int?

    public init(
        id: Int,
        mediaType: TMDbMediaType,
        title: String? = nil,
        originalTitle: String? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        voteAverage: Double? = nil,
        genres: [String] = [],
        cast: [CastMember] = [],
        seasons: [SeasonSummary] = [],
        originalLanguage: String? = nil,
        imdbID: String? = nil,
        contentRating: String? = nil,
        collectionID: Int? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.voteAverage = voteAverage
        self.genres = genres
        self.cast = cast
        self.seasons = seasons
        self.originalLanguage = originalLanguage
        self.imdbID = imdbID
        self.contentRating = contentRating
        self.collectionID = collectionID
    }

    /// 有没有「值得展示」的内容——补全后拿它判断是否落库。
    public var hasDisplayableContent: Bool {
        let hasTitle = !(title ?? "").isEmpty
        let hasOverview = !(overview ?? "").isEmpty
        return hasTitle || hasOverview || posterPath != nil || backdropPath != nil
    }
}

public struct CastMember: Sendable, Equatable, Codable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?

    public init(id: Int, name: String, character: String? = nil, profilePath: String? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profilePath = profilePath
    }
}

/// 剧集详情里的季摘要。
public struct SeasonSummary: Sendable, Equatable, Codable {
    public var seasonNumber: Int
    public var name: String?
    public var overview: String?
    public var posterPath: String?
    public var episodeCount: Int?

    public init(seasonNumber: Int, name: String? = nil, overview: String? = nil,
                posterPath: String? = nil, episodeCount: Int? = nil) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.episodeCount = episodeCount
    }
}

/// 一季的全部集（`/tv/{id}/season/{n}`）——**一次请求拿一整季**，
/// 不是每集一次。这是控制配额的关键（见 `TMDbClient.season`）。
public struct TMDbSeason: Sendable, Equatable, Codable {
    public var seasonNumber: Int
    public var name: String?
    public var overview: String?
    public var posterPath: String?
    public var episodes: [EpisodeEntry]

    public init(seasonNumber: Int, name: String? = nil, overview: String? = nil,
                posterPath: String? = nil, episodes: [EpisodeEntry] = []) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.episodes = episodes
    }
}

public struct EpisodeEntry: Sendable, Equatable, Codable {
    public var episodeNumber: Int
    public var name: String?
    public var overview: String?
    public var stillPath: String?
    public var airDate: String?
    public var runtime: Int?
    public var voteAverage: Double?

    public init(episodeNumber: Int, name: String? = nil, overview: String? = nil,
                stillPath: String? = nil, airDate: String? = nil, runtime: Int? = nil,
                voteAverage: Double? = nil) {
        self.episodeNumber = episodeNumber
        self.name = name
        self.overview = overview
        self.stillPath = stillPath
        self.airDate = airDate
        self.runtime = runtime
        self.voteAverage = voteAverage
    }
}

// MARK: - 搜索结果

/// 标题搜索结果的一项。用于没有 `ProviderIds["Tmdb"]` 时的兜底匹配。
public struct TMDbSearchResult: Sendable, Equatable, Codable {
    public var id: Int
    public var mediaType: TMDbMediaType
    public var title: String?
    public var originalTitle: String?
    public var overview: String?
    public var posterPath: String?
    /// 发行年 / 首播年（电影 `release_date`、剧集 `first_air_date`）。
    public var year: Int?
    public var popularity: Double?

    public init(id: Int, mediaType: TMDbMediaType, title: String? = nil,
                originalTitle: String? = nil, overview: String? = nil,
                posterPath: String? = nil, year: Int? = nil, popularity: Double? = nil) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.posterPath = posterPath
        self.year = year
        self.popularity = popularity
    }
}

// MARK: - 图片尺寸

/// TMDb 的图片 CDN 只认固定尺寸档，不接受任意宽度。
///
/// 我们的调用点传的是「希望的最大宽度」（如 400 / 720 / 1600），必须映射到最近的档位：
/// 取**不小于**请求宽度的最小档（宁可略大也别糊），超出最大档时用 `original`。
public enum TMDbImageSize: String, Sendable, CaseIterable {
    case w92, w154, w185, w342, w500, w780, w1280
    case original

    var width: Int? {
        switch self {
        case .w92: 92
        case .w154: 154
        case .w185: 185
        case .w342: 342
        case .w500: 500
        case .w780: 780
        case .w1280: 1280
        case .original: nil
        }
    }

    static func nearest(to width: Int) -> TMDbImageSize {
        let sized = allCases.filter { $0 != .original }
        guard let best = sized
            .compactMap({ size -> (TMDbImageSize, Int)? in size.width.map { (size, $0) } })
            .filter({ $0.1 >= width })
            .min(by: { $0.1 < $1.1 })
            .map(\.0)
        else { return .original }   // 比最大档还大 → 原图
        return best
    }

    /// 拼出可直接下载的图片 URL。`path` 是 TMDb 返回的 `/xxxx.jpg`。
    ///
    /// **免鉴权**：图片 CDN 不需要 key，也不带我们的 Authorization 头
    /// （所以 `RemoteImage` 调用时 `authHeader` 传 nil）。
    public static func url(path: String?, size: TMDbImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }

    /// 按请求宽度直接拼 URL 的便捷入口。
    public static func url(path: String?, requestedWidth: Int) -> URL? {
        url(path: path, size: nearest(to: requestedWidth))
    }
}
