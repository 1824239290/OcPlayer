import DiagnosticsKit
import Foundation

/// TMDb 客户端错误。
public enum TMDbError: Error, Equatable {
    /// 没配置 key → **整个功能禁用**（不是错误，调用方应静默跳过）。
    case notConfigured
    /// key 无效 / 被拒（401）。与「没有补全数据」区分开——那才是真的没数据。
    case unauthorized
    /// 配额用尽（429）。`retryAfter` 是服务端给的秒数。
    case rateLimited(retryAfter: Double?)
    /// 404：该 id 在 TMDb 不存在（`ProviderIds` 里的脏数据会走到这）。
    case notFound
    /// 其它 HTTP 状态。
    case http(status: Int)
    /// 传输层失败（断网 / 超时）。
    case transport(String)
    /// 响应解不出来（TMDb 改 schema）。
    case decoding(String)

    /// 值不值得重试：限流与传输层可重试，其余（401/404/解码）重试也是白搭。
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport: true
        case .notConfigured, .unauthorized, .notFound, .http, .decoding: false
        }
    }

    var retryAfter: Double? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }
}

/// TMDb 客户端。
///
/// 走共享的 `HTTPClient`（传输日志 / 计时 / 错误映射）+ `RetryPolicy`（指数退避、
/// 尊重 429 的 `Retry-After`），与既有 5 个域客户端同形。
///
/// 两处 TMDb 特有的讲究：
///
/// 1. **语言按字段回退**：TMDb 不做语言回退——`language=zh-CN` 时没有中文翻译的字段
///    直接返回**空串**。所以关键字段（标题 / 简介）为空时会再取一次回退语言补上；
///    非关键字段（如分级）缺了就缺了，不为此多打一次请求。
/// 2. **季一次拿全**：`/tv/{id}/season/{n}` 一次返回整季的所有集，
///    而不是每集一个请求——这是控制配额的关键。
public struct TMDbClient: Sendable {

    public static let baseURL = URL(string: "https://api.themoviedb.org/3")!

    /// 详情一次性带回来的关联块：演员表 / 图片 / 外部 id（IMDb）/ 分级。
    /// 用 `append_to_response` 把 4 个请求压成 1 个。
    static let appendToResponse = "credits,images,external_ids,content_ratings"

    private let credentials: any TMDbCredentialProviding
    private let client: HTTPClient
    private let limiter: TMDbRateLimiter
    private let retryPolicy: RetryPolicy
    private let logger: DiagnosticLogger

    public init(
        session: URLSession,
        credentials: any TMDbCredentialProviding,
        limiter: TMDbRateLimiter = TMDbRateLimiter(),
        retryPolicy: RetryPolicy = RetryPolicy(attempts: 3)
    ) {
        self.credentials = credentials
        self.client = HTTPClient(session: session, category: "TMDb")
        self.limiter = limiter
        self.retryPolicy = retryPolicy
        self.logger = NetworkLog.logger(category: "TMDb")
    }

    /// 是否已配置（未配置时所有方法都抛 `.notConfigured`，调用方应据此整体跳过）。
    public var isConfigured: Bool {
        credentials.apiKey() != nil
    }

    // MARK: - 端点

    /// 电影详情。
    public func movie(id: Int, language: String) async throws -> TMDbEntity {
        try await entity(path: "movie/\(id)", mediaType: .movie, language: language)
    }

    /// 剧集详情。
    public func tv(id: Int, language: String) async throws -> TMDbEntity {
        try await entity(path: "tv/\(id)", mediaType: .tv, language: language)
    }

    /// 一季的全部集（**一次请求**）。
    public func season(tvID: Int, seasonNumber: Int, language: String) async throws -> TMDbSeason {
        let data = try await get(path: "tv/\(tvID)/season/\(seasonNumber)", language: language)
        return try TMDbDecoding.season(data, seasonNumber: seasonNumber, fallbackNumber: seasonNumber)
    }

    /// 标题搜索。
    ///
    /// - Parameter year: 电影用 `year`、剧集用 `first_air_date_year`——**两家参数名不同**，
    ///   传错会被静默忽略（返回一堆同名作品），所以在这里按类型分派。
    public func search(
        query: String,
        mediaType: TMDbMediaType,
        year: Int?,
        language: String
    ) async throws -> [TMDbSearchResult] {
        var items: [URLQueryItem] = [URLQueryItem(name: "query", value: query)]
        if let year {
            switch mediaType {
            case .movie: items.append(URLQueryItem(name: "year", value: String(year)))
            case .tv: items.append(URLQueryItem(name: "first_air_date_year", value: String(year)))
            case .season, .episode: break
            }
        }
        let endpoint = mediaType == .movie ? "search/movie" : "search/tv"
        let data = try await get(path: endpoint, language: language, extraQuery: items)
        return try TMDbDecoding.searchResults(data, mediaType: mediaType)
    }

    // MARK: - 请求

    private func entity(path: String, mediaType: TMDbMediaType, language: String) async throws -> TMDbEntity {
        var primary = try TMDbDecoding.entity(
            try await get(path: path, language: language,
                          extraQuery: [URLQueryItem(name: "append_to_response", value: Self.appendToResponse)]),
            mediaType: mediaType)

        // 关键字段缺翻译（TMDb 返回空串）时，用回退语言补一次。
        // 只在**真的缺**时才多打一个请求——绝大多数中文条目不需要。
        if TMDbLanguage.needsFallback(title: primary.title, overview: primary.overview) {
            let fallback = TMDbLanguage.fallback(for: language)
            if fallback != language,
               let secondary = try? await get(path: path, language: fallback, extraQuery: [
                   URLQueryItem(name: "append_to_response", value: Self.appendToResponse),
               ]) {
                let other = try? TMDbDecoding.entity(secondary, mediaType: mediaType)
                // 逐字段回退：主语言非空即用主语言（**不能整包替换**——
                // 否则中文标题会被英文顶掉）。
                primary.title = TMDbLanguage.pick(primary.title, other?.title)
                primary.overview = TMDbLanguage.pick(primary.overview, other?.overview)
                primary.posterPath = primary.posterPath ?? other?.posterPath
                primary.backdropPath = primary.backdropPath ?? other?.backdropPath
                primary.contentRating = primary.contentRating ?? other?.contentRating
            }
        }
        return primary
    }

    private func get(
        path: String,
        language: String,
        extraQuery: [URLQueryItem] = []
    ) async throws -> Data {
        guard let key = credentials.apiKey() else { throw TMDbError.notConfigured }

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        var query = extraQuery
        query.append(URLQueryItem(name: "language", value: language))
        var headers: [String: String] = ["Accept": "application/json"]

        // v4（JWT）走 Bearer；v3（32 位十六进制）走查询参数。让用户复制哪个都行。
        if key.hasPrefix("eyJ") {
            headers["Authorization"] = "Bearer \(key)"
        } else {
            query.append(URLQueryItem(name: "api_key", value: key))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw TMDbError.transport("URL 拼接失败") }

        let spec = HTTPRequestSpec(url: url, method: "GET", headers: headers)
        return try await limiter.withPermit {
            try await retryPolicy.run {
                let exchange = try await client.exchange(spec)
                switch exchange.statusCode {
                case 200..<300:
                    return exchange.data
                case 401:
                    throw TMDbError.unauthorized
                case 404:
                    throw TMDbError.notFound
                case 429:
                    throw TMDbError.rateLimited(retryAfter: exchange.retryAfter)
                default:
                    throw TMDbError.http(status: exchange.statusCode)
                }
            } shouldRetry: { error in
                (error as? TMDbError)?.isRetryable ?? false
            } retryAfterProvider: { error in
                (error as? TMDbError)?.retryAfter
            } onRetry: { attempt, error in
                logger.debug("TMDb 重试 attempt=\(attempt)", fields: ["error": .string("\(error)")])
            }
        }
    }
}

// MARK: - 语言

enum TMDbLanguage {
    static func fallback(for language: String) -> String {
        language.lowercased().hasPrefix("zh") ? "en-US" : "en-US"
    }

    /// 关键字段是否缺失到需要补一次回退语言。
    static func needsFallback(title: String?, overview: String?) -> Bool {
        (title ?? "").isEmpty || (overview ?? "").isEmpty
    }

    /// 逐字段回退：**主语言非空即用主语言**。
    ///
    /// TMDb 用空串表示「这门语言没这个字段」，所以判定必须是「非空」而不是「非 nil」——
    /// 用 `??` 会把空串当有效值，英文永远补不上。
    static func pick(_ primary: String?, _ fallback: String?) -> String? {
        if let primary, !primary.isEmpty { return primary }
        guard let fallback, !fallback.isEmpty else { return primary }
        return fallback
    }
}

// MARK: - 解码

/// TMDb 响应 → 模型。宽容解码（字段增删不该让整条补全失败）。
enum TMDbDecoding {

    static func entity(_ data: Data, mediaType: TMDbMediaType) throws -> TMDbEntity {
        let raw = try decode(JSONObject.self, from: data)
        guard let id = raw.int("id") else {
            throw TMDbError.decoding("响应缺 id")
        }
        return TMDbEntity(
            id: id,
            mediaType: mediaType,
            title: mediaType == .movie ? raw.string("title") : raw.string("name"),
            originalTitle: mediaType == .movie ? raw.string("original_title") : raw.string("original_name"),
            overview: raw.string("overview"),
            posterPath: raw.string("poster_path"),
            backdropPath: raw.string("backdrop_path"),
            voteAverage: raw.double("vote_average"),
            genres: (raw.array("genres") ?? []).compactMap { $0.string("name") },
            cast: cast(from: raw),
            seasons: seasons(from: raw),
            originalLanguage: raw.string("original_language"),
            imdbID: raw["external_ids"]?.string("imdb_id"),
            contentRating: contentRating(from: raw)
        )
    }

    static func season(_ data: Data, seasonNumber: Int, fallbackNumber: Int) throws -> TMDbSeason {
        let raw = try decode(JSONObject.self, from: data)
        let episodes = (raw.array("episodes") ?? []).compactMap { entry -> EpisodeEntry? in
            guard let number = entry.int("episode_number") else { return nil }
            return EpisodeEntry(
                episodeNumber: number,
                name: entry.string("name"),
                overview: entry.string("overview"),
                stillPath: entry.string("still_path"),
                airDate: entry.string("air_date"),
                runtime: entry.int("runtime"),
                voteAverage: entry.double("vote_average"))
        }
        return TMDbSeason(
            seasonNumber: raw.int("season_number") ?? fallbackNumber,
            name: raw.string("name"),
            overview: raw.string("overview"),
            posterPath: raw.string("poster_path"),
            episodes: episodes)
    }

    static func searchResults(_ data: Data, mediaType: TMDbMediaType) throws -> [TMDbSearchResult] {
        let raw = try decode(JSONObject.self, from: data)
        return (raw.array("results") ?? []).compactMap { item -> TMDbSearchResult? in
            guard let id = item.int("id") else { return nil }
            let dateString = mediaType == .movie ? item.string("release_date") : item.string("first_air_date")
            return TMDbSearchResult(
                id: id,
                mediaType: mediaType,
                title: mediaType == .movie ? item.string("title") : item.string("name"),
                originalTitle: mediaType == .movie
                    ? item.string("original_title") : item.string("original_name"),
                overview: item.string("overview"),
                posterPath: item.string("poster_path"),
                year: year(from: dateString),
                popularity: item.double("popularity"))
        }
    }

    private static func cast(from raw: JSONObject) -> [CastMember] {
        guard let credits = raw["credits"], let list = credits.array("cast") else { return [] }
        // 只取前 20 位：详情页的演员栏本就只展示十几个，
        // 多存等于把 payload 撑大（TMDb 一部片能返回上百位）。
        return list.prefix(20).compactMap { member -> CastMember? in
            guard let id = member.int("id"), let name = member.string("name") else { return nil }
            return CastMember(id: id, name: name,
                              character: member.string("character"),
                              profilePath: member.string("profile_path"))
        }
    }

    private static func seasons(from raw: JSONObject) -> [SeasonSummary] {
        (raw.array("seasons") ?? []).compactMap { entry -> SeasonSummary? in
            guard let number = entry.int("season_number") else { return nil }
            return SeasonSummary(
                seasonNumber: number,
                name: entry.string("name"),
                overview: entry.string("overview"),
                posterPath: entry.string("poster_path"),
                episodeCount: entry.int("episode_count"))
        }
    }

    /// 从 `content_ratings.results` 里按语言取一条（TMDb 返回多国分级）。
    private static func contentRating(from raw: JSONObject) -> String? {
        guard let results = raw["content_ratings"]?.array("results"), !results.isEmpty else { return nil }
        let preferred = raw.string("__language") ?? "US"
        return (results.first { $0.string("iso_3166_1") == "US" }
            ?? results.first { $0.string("iso_3166_1") == preferred }
            ?? results[0]).string("rating")
    }

    private static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private static func decode(_ type: JSONObject.Type, from data: Data) throws -> JSONObject {
        guard let object = JSONObject.parse(data) else {
            throw TMDbError.decoding("响应不是 JSON 对象")
        }
        return object
    }
}

/// 极简 JSON 取值包装。
///
/// 不用 `JSONDecoder` + 一堆 `Decodable` 结构体：TMDb 的响应字段名多且我们只要其中
/// 十几个，写 20 个 struct 的样板反而更容易在字段改名时漏改。这里把「宽容读取」
/// 收成一个类型，取值失败一律返回 nil（上层按缺字段处理）。
struct JSONObject {
    private let storage: [String: Any]

    /// 从原始字节解析；解析失败返回 nil（错误语义归 `TMDbDecoding`）。
    ///
    /// 用 `JSONSerialization` 而非 `JSONDecoder`：后者只认 `Decodable` 类型，
    /// 拿不到 `[String: Any]` 这种无类型字典，而这里正需要「字段名不写死」的宽容读取。
    static func parse(_ data: Data) -> JSONObject? {
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return JSONObject(storage: any)
    }

    subscript(key: String) -> JSONObject? {
        guard let value = storage[key] as? [String: Any] else { return nil }
        return JSONObject(storage: value)
    }

    func string(_ key: String) -> String? {
        guard let value = storage[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        if let value = storage[key] as? Int { return value }
        if let value = storage[key] as? Double { return Int(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = storage[key] as? Double { return value }
        if let value = storage[key] as? Int { return Double(value) }
        return nil
    }

    func array(_ key: String) -> [JSONObject]? {
        guard let list = storage[key] as? [[String: Any]] else { return nil }
        return list.map { JSONObject(storage: $0) }
    }

    init(storage: [String: Any]) {
        self.storage = storage
    }
}
