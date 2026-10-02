import DiagnosticsKit
import Foundation

/// 多源共用的一个社区标注区间（秒）。`startSeconds` 为 nil 表示起点未标注
/// （消费侧回落到 0）。
public struct ExternalSkipInterval: Sendable, Equatable {
    public let startSeconds: Double?
    public let endSeconds: Double

    public init(startSeconds: Double?, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// 区间合理性钳制（对齐 AniSkip 提示转换的判据）：超长/过短/倒挂的区间按
    /// 坏数据处理，是错季匹配与脏标注的防护。返回 nil 表示不可用。
    func clamped() -> ExternalSkipInterval? {
        let start = max(0, startSeconds ?? 0)
        let end = endSeconds
        guard end >= 10, end <= 1_800, start < end - 1, end - start <= 400 else { return nil }
        return ExternalSkipInterval(startSeconds: start, endSeconds: end)
    }
}

// MARK: - anime-skip

/// anime-skip 社区时间戳客户端（GraphQL，https://api.anime-skip.com）。
///
/// 数据模型是 **start-point 链**：每个时间戳只标「某段从这里开始」，类型为
/// Intro / Mixed Intro / New Intro / Recap / Credits / Canon …。相邻两个时间戳
/// 恰好构成一个区间，所以 Intro 区间 = 第一个 Intro 类时间戳 → 下一时间戳。
///
/// 认证只要一个注册过的 `X-Client-ID` 请求头（app 设置里填，留空则整个源禁用；
/// 存 UserDefaults，与 dandanplay API Key 同一先例）。show 定位走 AniList 外部
/// ID（复用 AniSkip 链路已解析的 anilistID，不新增 ID 解析成本）。
public struct AnimeSkipClient: Sendable {
    private let clientID: String
    private let session: URLSession

    public init(clientID: String, session: URLSession? = nil) {
        self.clientID = clientID
        self.session = session ?? DanmakuNetworking.makeSession()
    }

    /// 某集的 Intro 区间。查不到（show/集/时间戳任一缺失）返回 nil；网络/协议
    /// 错误抛 `AnimeSkipError`。
    public func introInterval(
        anilistID: Int, seasonNumber: Int?, episodeNumber: Int
    ) async throws -> ExternalSkipInterval? {
        let response = try await Self.request(
            clientID: clientID, session: session,
            query: """
            query ($service: ExternalService!, $id: String!) {
              findShowsByExternalId(service: $service, serviceId: $id) {
                episodes { season number timestamps { at type { name } } }
              }
            }
            """,
            variables: ["service": "ANILIST", "id": String(anilistID)])
        let shows = response.data?.findShowsByExternalId ?? []
        let episodes = shows.flatMap { $0.episodes ?? [] }
        guard let interval = Self.introInterval(
            from: episodes, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        else { return nil }
        return interval.clamped()
    }

    // MARK: 内部

    public enum AnimeSkipError: Error, Sendable {
        case http(Int)
        case decoding(String)
        case transport(String)
    }

    private static func request(
        clientID: String, session: URLSession, query: String, variables: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.anime-skip.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OcPlayer (https://github.com/1824239290/OcPlayer)", forHTTPHeaderField: "User-Agent")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        request.httpBody = try JSONEncoder().encode(
            GraphQLRequestBody(query: query, variables: variables))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnimeSkipError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnimeSkipError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AnimeSkipError.decoding("\(error)")
        }
    }

    private struct GraphQLRequestBody: Encodable {
        let query: String
        let variables: [String: String]
    }

    struct Response: Decodable {
        let data: DataPayload?
        let errors: [GraphQLError]?
        struct DataPayload: Decodable {
            let findShowsByExternalId: [Show]?
        }
        struct GraphQLError: Decodable {
            let message: String
        }
        struct Show: Decodable {
            let episodes: [Episode]?
        }
        struct Episode: Decodable {
            let season: String?
            let number: String?
            let timestamps: [Timestamp]?
        }
        struct Timestamp: Decodable {
            let at: Double?
            let type: TypePayload?
            struct TypePayload: Decodable {
                let name: String?
            }
        }
    }

    /// Intro 类型的 start-point 名（anime-skip 的三档主题标注）。
    static let introTypeNames: Set<String> = ["Intro", "Mixed Intro", "New Intro"]

    /// 从全集时间戳链里重建目标集的 Intro 区间。
    ///
    /// - show 条目可能拆多份（S1 / Cour 2 各一条），这里拿到的是扁平全集;
    /// - 集匹配：集号按 Int 宽松比（wire 上是字符串），季号精确匹配优先、
    ///   缺失时退到首个集号命中;
    /// - 区间：排序后第一个 Intro 类时间戳 → 下一时间戳（任何类型）。社区
    ///   标注偶有前后两段主题,取第一段;脏标注由调用方的区间钳制兜底。
    static func introInterval(
        from episodes: [Response.Episode], seasonNumber: Int?, episodeNumber: Int
    ) -> ExternalSkipInterval? {
        let candidates = episodes.filter { episode in
            episode.number.flatMap(Int.init) == episodeNumber
        }
        let expectedSeason = seasonNumber ?? 1
        let episode = candidates.first { $0.season == String(expectedSeason) }
            ?? candidates.first
        let stamped = (episode?.timestamps ?? []).compactMap { ts -> (Double, String?)? in
            guard let at = ts.at else { return nil }
            return (at, ts.type?.name)
        }.sorted { $0.0 < $1.0 }
        guard stamped.count >= 2,
              let startIndex = stamped.firstIndex(where: {
                  Self.introTypeNames.contains($0.1 ?? "")
              }),
              startIndex + 1 < stamped.count
        else { return nil }
        return ExternalSkipInterval(
            startSeconds: stamped[startIndex].0, endSeconds: stamped[startIndex + 1].0)
    }
}

// MARK: - anime-skip 设置

/// anime-skip 的 `X-Client-ID` 设置。存 UserDefaults（与 dandanplay API Key 同一
/// 先例：发行包统一 ad-hoc 签名，不引入 Keychain）。**留空 = 整个源禁用**。
/// UserDefaults 本身线程安全(系统保证),@unchecked 豁免其非 Sendable 标注。
public final class AnimeSkipSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let clientIDKey = "dev.jumusu.ocplayer.animeskip.clientID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 规范化后的 client ID（去首尾空白）；未填/空串返回 nil。
    public var clientID: String? {
        get {
            let raw = defaults.string(forKey: Self.clientIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            let raw = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                defaults.removeObject(forKey: Self.clientIDKey)
            } else {
                defaults.set(raw, forKey: Self.clientIDKey)
            }
        }
    }
}

// MARK: - TheIntroDB

/// TheIntroDB 社区时间戳客户端（https://theintrodb.org，REST，**免鉴权**）。
///
/// `GET /v3/media?tmdb_id=&season=&episode=` 返回该集各类型段（intro / recap /
/// credits / preview）的数组，每段 `{start_ms, end_ms}`（均可为 null）。注意
/// tmdb_id 必须是**剧集级** ID——Jellyfin 集条目 ProviderIds 里的 Tmdb 是集级
/// ID，不能直接用（要用 series 级查询换出来）。
public struct TheIntroDBClient: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? DanmakuNetworking.makeSession()
    }

    /// 某集的 Intro 区间。无数据（404 / 空）返回 nil。
    public func introInterval(
        tmdbID: Int, seasonNumber: Int?, episodeNumber: Int
    ) async throws -> ExternalSkipInterval? {
        var components = URLComponents(url: URL(string: "https://api.theintrodb.org/v3/media")!, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "tmdb_id", value: String(tmdbID)),
            URLQueryItem(name: "season", value: String(seasonNumber ?? 1)),
            URLQueryItem(name: "episode", value: String(episodeNumber)),
        ]
        guard let url = components?.url else {
            throw AnimeSkipClient.AnimeSkipError.decoding("TheIntroDB URL 组装失败")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OcPlayer (https://github.com/1824239290/OcPlayer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnimeSkipClient.AnimeSkipError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 404 = 该集无收录,常态而非错误。
            throw AnimeSkipClient.AnimeSkipError.http(http.statusCode)
        }
        struct Response: Decodable {
            let intro: [Segment]?
            struct Segment: Decodable {
                let start_ms: Int?
                let end_ms: Int?
            }
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AnimeSkipClient.AnimeSkipError.decoding("\(error)")
        }
        // 多段 intro（拆分式片头）取第一段;端点缺失的段按坏数据处理。
        guard let segment = decoded.intro?.first,
              let startMS = segment.start_ms, let endMS = segment.end_ms
        else { return nil }
        return ExternalSkipInterval(
            startSeconds: Double(startMS) / 1_000, endSeconds: Double(endMS) / 1_000
        ).clamped()
    }
}
