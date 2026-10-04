import CoreModel
import Foundation

/// 叠加到条目上的 TMDb 数据（**只读**，不修改服务端返回的 `MediaItem`）。
///
/// ## 为什么是独立结构而不是改写 `MediaItem`
///
/// 服务端数据与 TMDb 数据是**两个来源、两套生命周期**：
/// - 服务端数据每次刷新都会重新拉到，是「当前事实」；
/// - TMDb 数据是按用户开关叠加的**增强**，可以随时整体关掉（用户清缓存、
///   换语言、TMDb 挂了）。
///
/// 若把 TMDb 字段直接写进 `MediaItem`，这两个来源就混成一个：关掉 TMDb 后要「把
/// 之前改过的字段改回去」，而那时已经不知道原值是什么了。独立结构让「关掉」等于
/// 「不再叠加」，天然可逆。视图侧用 `DisplayMetadata` 取值，取不到就回落到
/// 服务端那套——那条路径本来就在。
///
/// 另一个附带好处：`MediaItem` 每加一个 TMDb 字段都要跟着动 Codable 与快照，
/// 而这里可以独立演进。
public struct TMDbOverlay: Sendable, Equatable {

    /// 从哪来（诊断与「数据来源」展示）。
    public var source: TMDbLinkSource
    public var confidence: Double
    public var entityKey: TMDbEntityKey

    /// 展示文本。nil = TMDb 没这条数据（不是「空字符串」——那样会顶掉服务端的值）。
    public var title: String?
    public var overview: String?
    public var genres: [String]
    public var communityRating: Double?
    public var contentRating: String?
    public var cast: [CastMember]
    public var imdbID: String?

    /// 图片**路径**（TMDb 的 `/xxx.jpg`）。取 URL 时按目标宽度映射档位。
    public var posterPath: String?
    public var backdropPath: String?

    /// 该季的各集（**只有季叠加层才有**；电影/剧为空）。
    ///
    /// 一次请求就带回整季（见 `TMDbClient.season`），所以这里是现成的——
    /// 分集卡片能用上每集的**标题**与**简介**，正好补服务端那种「第 9 集」的占位名。
    public var episodes: [EpisodeEntry]

    /// 数据抓取时间（文案「数据更新于 X 前」用）。
    public var fetchedAt: Date
    /// 是否已过缓存期（展示仍可用，只是提示可能要更新）。
    public var isExpired: Bool

    public init(
        source: TMDbLinkSource,
        confidence: Double,
        entityKey: TMDbEntityKey,
        title: String? = nil,
        overview: String? = nil,
        genres: [String] = [],
        communityRating: Double? = nil,
        contentRating: String? = nil,
        cast: [CastMember] = [],
        imdbID: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        episodes: [EpisodeEntry] = [],
        fetchedAt: Date = Date(),
        isExpired: Bool = false
    ) {
        self.source = source
        self.confidence = confidence
        self.entityKey = entityKey
        self.title = title
        self.overview = overview
        self.genres = genres
        self.communityRating = communityRating
        self.contentRating = contentRating
        self.cast = cast
        self.imdbID = imdbID
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.episodes = episodes
        self.fetchedAt = fetchedAt
        self.isExpired = isExpired
    }

    /// 从一份实体数据构造。
    ///
    /// - Parameter replaceText: 文本是否允许**顶替**服务端的值（用户开关）。
    ///   false 时只填服务端**缺**的字段。
    init(entity: TMDbEntity, link: TMDbLink, fetchedAt: Date, isExpired: Bool) {
        self.source = link.source
        self.confidence = link.confidence
        self.entityKey = link.entityKey
        self.title = entity.title
        self.overview = entity.overview
        self.genres = entity.genres
        self.communityRating = entity.voteAverage
        self.contentRating = entity.contentRating
        self.cast = entity.cast
        self.imdbID = entity.imdbID
        self.posterPath = entity.posterPath
        self.backdropPath = entity.backdropPath
        self.episodes = []
        self.fetchedAt = fetchedAt
        self.isExpired = isExpired
    }

    /// 从一季数据构造（季只有自己的简介与海报，没有演员/评分）。
    init(season: TMDbSeason, link: TMDbLink, fetchedAt: Date, isExpired: Bool) {
        self.source = link.source
        self.confidence = link.confidence
        self.entityKey = link.entityKey
        self.title = season.name
        self.overview = season.overview
        self.genres = []
        self.communityRating = nil
        self.contentRating = nil
        self.cast = []
        self.imdbID = nil
        self.posterPath = season.posterPath
        self.backdropPath = nil
        self.episodes = season.episodes
        self.fetchedAt = fetchedAt
        self.isExpired = isExpired
    }

    // MARK: - 分集（季叠加层专属）

    /// 按集号取该集的 TMDb 数据。nil = 这一季没这集 / 不是季叠加层。
    public func episode(number: Int) -> EpisodeEntry? {
        episodes.first { $0.episodeNumber == number }
    }

    /// 分集标题。
    ///
    /// **为什么分集特别需要它**：服务端对没有元数据的分集常给「第 9 集」这种占位名
    /// （实测库里就有），而 TMDb 有真标题。所以这里与整页文本策略一致：
    /// `preferTMDb` 为真时 TMDb 优先，否则只补服务端**空**的。
    ///
    /// 但**占位名**（`第 N 集` / `Episode N`）无论开关如何都该被 TMDb 顶掉——
    /// 那不是「用户的元数据」，是服务端没数据的表现，留着它等于白白浪费 TMDb 数据。
    public func displayEpisodeTitle(number: Int, serverValue: String, preferTMDb: Bool) -> String {
        guard let tmdb = episode(number: number)?.name, !tmdb.isEmpty else { return serverValue }
        if preferTMDb { return tmdb }
        if serverValue.isEmpty { return tmdb }
        return Self.isPlaceholderEpisodeName(serverValue) ? tmdb : serverValue
    }

    /// 分集简介。规则同上（占位/空都补）。
    public func displayEpisodeOverview(number: Int, serverValue: String?, preferTMDb: Bool) -> String? {
        guard let tmdb = episode(number: number)?.overview, !tmdb.isEmpty else { return serverValue }
        if preferTMDb { return tmdb }
        let server = serverValue ?? ""
        return server.isEmpty ? tmdb : serverValue
    }

    /// 分集剧照路径（服务端缺图时可用）。
    public func episodeStillPath(number: Int) -> String? {
        episode(number: number)?.stillPath
    }

    /// 判断是不是服务端生成的占位集名。
    ///
    /// 覆盖 Jellyfin / Emby 的常见形态：`第 9 集`、`第9集`、`Episode 9`、`第 9 話`。
    /// **刻意不做模糊匹配**：真有个片子把某一集就叫「第 9 集」也无所谓——
    /// 用 TMDb 的标题替换它不会更差。
    static func isPlaceholderEpisodeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // ⚠️ 用 `[0-9]` 而**不是** `\d`：实测 ICU 的 `\d` 会匹配中文数字
        // （「九」被 `^\d+$` 判为 true），于是「第九集」这种**真实标题**会被误判成
        // 占位名、被 TMDb 的标题顶掉。占位名是服务端用 ASCII 数字生成的，
        // 只认 `[0-9]` 既够用又不会误伤。
        // 中日文的「第 N 集」**只锚结尾不锚开头**：实测服务端还有
        // 「我的朋友很少 - S01E00 - 第 0 集」这种由文件名派生的形态，
        // 锚了开头就抓不到它（而它显然也是占位名）。
        // 结尾锚定同时保证「第 9 集的秘密」这类真标题不被误伤。
        let patterns = [
            #"第\s*[0-9]+\s*[集话話]$"#,
            #"^[Ee][Pp]isode\s*[0-9]+$"#,
            #"^[Ee][Pp]\.?\s*[0-9]+$"#,
            #"^[0-9]+$"#,
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - 取值（按用户策略决定是否顶替）

    /// 标题：`preferTMDbText` 为真时 TMDb 优先，否则只补空缺。
    ///
    /// TMDb 返回**空串**表示「这门语言没这个字段」，所以判定一律用「非空」。
    public func displayTitle(serverValue: String, preferTMDb: Bool) -> String {
        guard let title, !title.isEmpty else { return serverValue }
        if preferTMDb { return title }
        return serverValue.isEmpty ? title : serverValue
    }

    public func displayOverview(serverValue: String?, preferTMDb: Bool) -> String? {
        let tmdb = overview
        if preferTMDb {
            if let tmdb, !tmdb.isEmpty { return tmdb }
            return serverValue
        }
        let server = serverValue ?? ""
        if !server.isEmpty { return serverValue }
        return (tmdb?.isEmpty ?? true) ? serverValue : tmdb
    }

    public func displayGenres(serverValue: [String], preferTMDb: Bool) -> [String] {
        guard !genres.isEmpty else { return serverValue }
        if preferTMDb { return genres }
        return serverValue.isEmpty ? genres : serverValue
    }

    public func displayRating(serverValue: Double?, preferTMDb: Bool) -> Double? {
        guard let communityRating else { return serverValue }
        if preferTMDb { return communityRating }
        return serverValue ?? communityRating
    }

    public func displayCast(serverValue: [MediaItem.Person], preferTMDb: Bool) -> [MediaItem.Person] {
        guard !cast.isEmpty else { return serverValue }
        // `kind: "Actor"` 不是可选的：演员列表 UI 只显示 `kind == "Actor"` 的条目，
        // 传其它值会让 TMDb 补的演员一个都不显示（而且不报错，最难查的那种）。
        let mapped = cast.map {
            MediaItem.Person(id: Self.personID(forTMDbID: $0.id), name: $0.name,
                             role: $0.character, kind: "Actor")
        }
        if preferTMDb { return mapped }
        return serverValue.isEmpty ? mapped : serverValue
    }

    /// TMDb 演员在 `MediaItem.Person.id` 里的前缀。
    ///
    /// 为什么要加前缀：服务端的演员 id 与 TMDb 的演员 id 是**两套编号**，可能撞号。
    /// 撞了的话「用服务端 id 去问服务端要图」会拿到另一个人的头像——静默错图。
    /// 前缀把两者分开，同时给下游一个明确的判据（见 `profilePath(forPersonID:)`）。
    public static let tmdbPersonPrefix = "tmdb-"

    static func personID(forTMDbID id: Int) -> String {
        "\(tmdbPersonPrefix)\(id)"
    }

    /// 由 `MediaItem.Person.id` 反查 TMDb 头像路径。nil = 这个演员不是 TMDb 来的。
    ///
    /// **必须有这个反查**：演员头像原先一律由「服务端条目 id」拼 URL，而 TMDb 演员的
    /// id 在服务端根本不存在——实测服务端返回 **400**，每个演员一张破图 + 一次白打的
    /// 请求（一页最多 20 个）。调用方据此改走 TMDb CDN（免鉴权）。
    public func profilePath(forPersonID personID: String) -> String? {
        guard personID.hasPrefix(Self.tmdbPersonPrefix),
              let id = Int(personID.dropFirst(Self.tmdbPersonPrefix.count))
        else { return nil }
        return cast.first { $0.id == id }?.profilePath
    }
}

/// 图片取用策略。
public struct TMDbImagePolicy: Sendable {
    /// 是否允许 TMDb 图**顶替**服务端已有的图。
    ///
    /// **默认 true（TMDb 优先）**，与 `TMDbPreferences.replaceExistingImages` 的默认
    /// 保持一致——同一个概念**不能有两个默认值**（这里踩过：结构体 init 默认 false、
    /// 偏好默认 true，于是「生产路径 TMDb 优先、测试里默认只补缺」，用例直接失败）。
    ///
    /// 保留这个开关是因为「谁的图更好」没有客观答案：用户用刮削器精修过的海报被
    /// TMDb 顶掉是**单向损失**，必须留一个关掉的出口。
    public var replacesExisting: Bool

    public init(replacesExisting: Bool = true) {
        self.replacesExisting = replacesExisting
    }
}

/// 把 TMDb 数据接到展示层的**纯函数**集合。
///
/// 不做网络、不碰数据库——输入是服务端条目 + 叠加数据，输出是「该显示什么」。
/// 这样这套策略（文本优先、图片只补缺）可以脱离 App 单独测。
public enum DisplayMetadata {

    /// 海报 URL：服务端没有、或允许顶替时才用 TMDb。
    ///
    /// - Parameter requestedWidth: 调用点希望的最大宽度（如 400）；
    ///   TMDb 只认固定档位，故按 `TMDbImageSize` 映射。
    public static func posterURL(
        serverURL: URL?,
        overlay: TMDbOverlay?,
        requestedWidth: Int,
        policy: TMDbImagePolicy
    ) -> URL? {
        if serverURL != nil, !policy.replacesExisting { return serverURL }
        guard let overlay else { return serverURL }
        // TMDb 图**免鉴权**（CDN 不校验），所以取 URL 时不需要 auth 头；
        // 调用点传 authHeader 时应对 TMDb URL 传 nil，否则会给 CDN 发无意义的凭证。
        return TMDbImageSize.url(path: overlay.posterPath, requestedWidth: requestedWidth) ?? serverURL
    }

    public static func backdropURL(
        serverURL: URL?,
        overlay: TMDbOverlay?,
        requestedWidth: Int,
        policy: TMDbImagePolicy
    ) -> URL? {
        if serverURL != nil, !policy.replacesExisting { return serverURL }
        guard let overlay else { return serverURL }
        return TMDbImageSize.url(path: overlay.backdropPath, requestedWidth: requestedWidth) ?? serverURL
    }

    /// 该 URL 是否来自 TMDb（决定要不要带服务端认证头）。
    ///
    /// 单独一个判断而不是在各调用点写 `url.host == "image.tmdb.org"`：
    /// 给 CDN 发 Jellyfin 的 `Authorization` 头既无意义、也把凭证多送一处。
    public static func isTMDbImage(_ url: URL?) -> Bool {
        url?.host == "image.tmdb.org"
    }
}
