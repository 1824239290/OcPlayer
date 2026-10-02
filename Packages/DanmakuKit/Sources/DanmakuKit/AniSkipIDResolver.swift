import CryptoKit
import DiagnosticsKit
import Foundation

/// 一次 MAL ID 解析所需的番剧身份信息（全部可选，至少要有一项可解析的线索）。
public struct AniSkipAnimeIdentity: Sendable, Equatable {
    /// 直接来自 Jellyfin ProviderIds 的 MyAnimeList ID（零网络，最优先）。
    public let malID: Int?
    /// ProviderIds 里的 AniList ID（一次 GraphQL 换算成 MAL）。
    public let anilistID: Int?
    /// 主标题（优先弹幕匹配出的 dandanplay 标题——与弹幕库同一套命名）。
    public let title: String?
    /// 备选标题（媒体库原生标题、Bangumi 日文名等），主标题搜不中时依次尝试。
    /// dandanplay 的简体中文标题在 AniList 上常常零召回（原生标题用字不同，
    /// 实测「二十世纪电气目录」搜「二十世紀電氣目録 -ユーレカ・エヴリカ-」条目
    /// 返回空），单一中文标题会把整条 AniSkip 路径卡死在 ID 解析上。
    public let alternativeTitles: [String]
    /// 季数 / 年份：进缓存键做区分（不同季是不同 MAL 条目），搜索暂不用于消歧。
    public let seasonNumber: Int?
    public let year: Int?

    public init(
        malID: Int? = nil,
        anilistID: Int? = nil,
        title: String? = nil,
        alternativeTitles: [String] = [],
        seasonNumber: Int? = nil,
        year: Int? = nil
    ) {
        self.malID = malID
        self.anilistID = anilistID
        self.title = title
        self.alternativeTitles = alternativeTitles
        self.seasonNumber = seasonNumber
        self.year = year
    }

    /// AniList 搜索候选：主标题在前，按归一形态去重滤空（全半角/大小写/标点
    /// 视为同一标题，避免同一标题搜两遍白耗限流额度）。
    var searchTitles: [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for candidate in [title] + alternativeTitles {
            let trimmed = (candidate ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = DanmakuFilenameParser.comparableTitle(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            titles.append(trimmed)
        }
        return titles
    }
}

/// 一次身份解析的结果。`anilistID` 供 anime-skip 这类按 AniList 索引的源复用;
/// **两者都为 nil 才算解析失败**(负缓存)——AniList 条目可能只有 id 没有 idMal,
/// 此时 AniSkip 查不了,但 anime-skip 还能用。
public struct AniSkipResolvedIDs: Sendable, Equatable {
    public let malID: Int?
    public let anilistID: Int?

    public init(malID: Int?, anilistID: Int?) {
        self.malID = malID
        self.anilistID = anilistID
    }

    public var isEmpty: Bool { malID == nil && anilistID == nil }
}

/// `mal-id-mappings.json` 的单条记录。`malID` 与 `anilistID` 都为 nil 是负缓存
/// (搜不中),7 天后允许重试——AniList 在长尾番上的收录会变,死缓存会永久错过
/// 新数据。`anilistID` 为旧文件兼容字段(缺 key 解码为 nil)。
public struct AniSkipIDRecord: Codable, Sendable, Equatable {
    public let malID: Int?
    public let anilistID: Int?
    public let resolvedAt: Date

    public init(malID: Int?, anilistID: Int? = nil, resolvedAt: Date) {
        self.malID = malID
        self.anilistID = anilistID
        self.resolvedAt = resolvedAt
    }

    /// 双 ID 全空 = 负缓存记录。
    var isEmpty: Bool { malID == nil && anilistID == nil }
}

/// AniList GraphQL 只读客户端（无需鉴权；限流 90 req/min，远低于我们的节奏）。
struct AniListClient: Sendable {
    let session: URLSession

    /// 搜索响应里的一条候选条目。字段全可缺（GraphQL 只返回所请求的字段，
    /// 测试响应可以只带 idMal）。
    struct SearchMedia: Sendable {
        let anilistID: Int?
        let idMal: Int?
        let native: String?
        let romaji: String?
        let english: String?
        let synonyms: [String]

        var allTitles: [String] {
            [native, romaji, english].compactMap { $0 } + synonyms
        }
    }

    /// 命中规则（进日志，排查「为什么认成了这一条」）。
    enum MatchRule: String, Sendable {
        /// 归一化后与标题/别名完全一致。
        case exact
        /// 归一化后被候选标题包含（原生标题带副标题装饰的集，如
        /// 「二十世紀電氣目録」⊂「二十世紀電氣目録ユーレカエヴリカ」）。
        case contained
        /// 兜底：第一个带 idMal 的条目（信任 AniList 搜索的相关性排序）。
        case firstWithID
    }

    /// 标题/AniList ID → MAL ID。搜不到或网络失败返回空结果（调用方降级，不抛错：
    /// 映射失败只意味着跳片头少一路数据源，不该打断弹幕装载）。
    ///
    /// AniList 的 `search` 是模糊匹配、无精确模式（官方文档明说标题不唯一），
    /// 因此按官方推荐做客户端过滤：先在候选里找归一化相等/包含的条目，全部
    /// 落空再退到「第一个带 idMal」的旧行为。多候选标题按序尝试，任一命中短路。
    func resolveIDs(anilistID: Int?, searchTitles: [String]) async -> AniSkipResolvedIDs {
        if let anilistID {
            return await lookupIDs(anilistID: anilistID)
        }
        var firstFallback: SearchMedia?
        for title in searchTitles {
            guard let media = await searchMedia(title: title) else { continue }
            if let hit = Self.bestMatch(in: media, for: title) {
                let hitMedia = hit.media
                NetworkLog.report(
                    category: "AniList", level: .info,
                    "AniList 搜索命中",
                    fields: [
                        "title": .string(title),
                        "malID": hitMedia.idMal.map { .integer(Int64($0)) } ?? .null,
                        "anilistID": hitMedia.anilistID.map { .integer(Int64($0)) } ?? .null,
                        "rule": .string(hit.rule.rawValue),
                    ])
                return AniSkipResolvedIDs(malID: hitMedia.idMal, anilistID: hitMedia.anilistID)
            }
            // 兜底候选按标题优先级取第一个：精确匹配优先于兜底，所以不能
            // 在这里直接 return——后面的标题可能给出更可靠的精确命中。
            if firstFallback == nil, let fallback = media.first(where: { $0.idMal != nil }) {
                firstFallback = fallback
            }
        }
        guard let fallback = firstFallback else { return AniSkipResolvedIDs(malID: nil, anilistID: nil) }
        NetworkLog.report(
            category: "AniList", level: .info,
            "AniList 搜索无精确匹配，取首个带 idMal 的条目",
            fields: [
                "malID": fallback.idMal.map { .integer(Int64($0)) } ?? .null,
                "anilistID": fallback.anilistID.map { .integer(Int64($0)) } ?? .null,
                "rule": .string(MatchRule.firstWithID.rawValue),
            ])
        return AniSkipResolvedIDs(malID: fallback.idMal, anilistID: fallback.anilistID)
    }

    /// 客户端标题匹配：归一化相等 > 归一化包含 > nil。只在 idMal 非空的条目里选。
    static func bestMatch(
        in media: [SearchMedia], for title: String
    ) -> (media: SearchMedia, rule: MatchRule)? {
        let query = DanmakuFilenameParser.comparableTitle(title)
        guard !query.isEmpty else { return nil }
        var contained: SearchMedia?
        for candidate in media {
            guard candidate.idMal != nil else { continue }
            for name in candidate.allTitles {
                let normalized = DanmakuFilenameParser.comparableTitle(name)
                if normalized.isEmpty { continue }
                if normalized == query {
                    return (candidate, .exact)
                }
                // 包含匹配要求查询词 ≥6 个字母/数字：「Re」这类短词会命中所有候选。
                if contained == nil, query.count >= 6, normalized.contains(query) {
                    contained = candidate
                }
            }
        }
        guard let contained else { return nil }
        return (contained, .contained)
    }

    // MARK: 内部

    /// AniList ID 直查（一次 GraphQL 换算）。id 与 idMal 都取回。
    private func lookupIDs(anilistID: Int) async -> AniSkipResolvedIDs {
        struct Response: Decodable {
            struct Media: Decodable {
                let id: Int?
                let idMal: Int?
            }
            struct DataPayload: Decodable {
                let media: Media?
                enum CodingKeys: String, CodingKey { case media = "Media" }
            }
            let data: DataPayload?
        }
        guard let decoded: Response = await exchange(
            query: "query ($id: Int) { Media(id: $id) { id idMal } }",
            variables: ["id": String(anilistID)],
            as: Response.self
        ) else { return AniSkipResolvedIDs(malID: nil, anilistID: nil) }
        // AniList ID 是调用方给的（信任），换算只补 idMal。
        return AniSkipResolvedIDs(malID: decoded.data?.media?.idMal, anilistID: anilistID)
    }

    /// 单标题搜索。nil = 网络/协议层失败（已记日志）；空数组 = 搜索无结果。
    private func searchMedia(title: String) async -> [SearchMedia]? {
        struct Response: Decodable {
            struct Media: Decodable {
                let id: Int?
                let idMal: Int?
                let title: Title?
                let synonyms: [String]?
                struct Title: Decodable {
                    let native: String?
                    let romaji: String?
                    let english: String?
                }
            }
            struct Page: Decodable { let media: [Media]? }
            struct DataPayload: Decodable {
                let page: Page?
                enum CodingKeys: String, CodingKey { case page = "Page" }
            }
            let data: DataPayload?
        }
        guard let decoded: Response = await exchange(
            query: """
            query ($search: String) { Page(perPage: 10) { media(search: $search, type: ANIME) \
            { id idMal title { native romaji english } synonyms } } }
            """,
            variables: ["search": title],
            as: Response.self
        ) else { return nil }
        let media = (decoded.data?.page?.media ?? []).map { item in
            SearchMedia(
                anilistID: item.id,
                idMal: item.idMal,
                native: item.title?.native,
                romaji: item.title?.romaji,
                english: item.title?.english,
                synonyms: item.synonyms ?? []
            )
        }
        if media.isEmpty {
            NetworkLog.report(
                category: "AniList", level: .debug,
                "AniList 搜索无结果",
                fields: ["title": .string(title)])
        }
        return media
    }

    /// POST 一个 GraphQL 请求并解码。非 2xx / 传输失败 / 解码失败都记 warning 后
    /// 返回 nil——映射失败只降级这一路数据源，调用方不抛错。
    private func exchange<Response: Decodable>(
        query: String,
        variables: [String: String],
        as type: Response.Type
    ) async -> Response? {
        let body: Data
        do {
            body = try JSONEncoder().encode(
                GraphQLRequestBody(query: query, variables: variables))
        } catch {
            NetworkLog.report(category: "AniList", level: .warning, "GraphQL 请求体编码失败: \(error)")
            return nil
        }
        let spec = HTTPRequestSpec(
            url: URL(string: "https://graphql.anilist.co")!,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                // AniList 拒绝无 UA / 默认 urllib 型请求。
                "User-Agent": "OcPlayer (https://github.com/1824239290/OcPlayer)",
            ],
            body: body
        )
        let exchange: HTTPExchange
        do {
            exchange = try await HTTPClient(session: session, category: "AniList").exchange(spec)
        } catch {
            NetworkLog.report(category: "AniList", level: .warning, "GraphQL 请求失败: \(error)")
            return nil
        }
        guard (200..<300).contains(exchange.statusCode) else {
            NetworkLog.report(
                category: "AniList", level: .warning,
                "GraphQL HTTP \(exchange.statusCode) body=\(exchange.bodyText.prefix(160))")
            return nil
        }
        do {
            return try JSONDecoder().decode(Response.self, from: exchange.data)
        } catch {
            NetworkLog.report(category: "AniList", level: .warning, "GraphQL 解码失败: \(error)")
            return nil
        }
    }
}

/// AniList GraphQL 请求体。
private struct GraphQLRequestBody: Encodable {
    let query: String
    let variables: [String: String]
}

/// MAL ID 解析器：ProviderIds 直取 → 缓存 → AniList（按 ID 换算 / 多候选标题搜索）。
///
/// 结果永久缓存（`AniSkipIDStore`），负缓存 7 天过期重试。解析器只做「番剧 → MAL ID」
/// 这一件事，AniSkip 区间查询由 `AniSkipClient` 负责。
public actor AniSkipIDResolver {
    private let store: AniSkipIDStore
    private let client: AniListClient
    /// 时间注入（测试负缓存过期用）。
    private let now: @Sendable () -> Date

    public init(store: AniSkipIDStore, session: URLSession? = nil) {
        self.store = store
        self.client = AniListClient(session: session ?? DanmakuNetworking.makeSession())
        self.now = { Date() }
    }

    /// 测试注入时钟。
    init(store: AniSkipIDStore, session: URLSession? = nil, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.client = AniListClient(session: session ?? DanmakuNetworking.makeSession())
        self.now = now
    }

    /// 负缓存有效期：搜不中的番 7 天后重试。
    static let negativeCacheLifetime: TimeInterval = 7 * 24 * 3600

    /// 解析番剧身份。无任何线索或解析失败返回空结果（`isEmpty`）。
    ///
    /// `forceRefresh` 绕过正/负缓存全新解析（「重新匹配」的语义：用户显式要求
    /// 重来——旧正缓存可能本身就是错季错番；AniList 限流 90 req/min，多花
    /// 1-3 个请求无压力）。
    public func resolve(
        for identity: AniSkipAnimeIdentity, forceRefresh: Bool = false
    ) async -> AniSkipResolvedIDs {
        // 直取路径零成本，不走缓存。
        if let malID = identity.malID, malID >= 1 {
            return AniSkipResolvedIDs(malID: malID, anilistID: identity.anilistID)
        }
        let titles = identity.searchTitles
        guard identity.anilistID != nil || !titles.isEmpty else {
            NetworkLog.report(
                category: "AniSkip", level: .debug,
                "MAL ID 解析无线索（无 ID、无标题），跳过")
            return AniSkipResolvedIDs(malID: nil, anilistID: nil)
        }
        let key = Self.cacheKey(for: identity)
        if !forceRefresh, let record = await store.record(for: key) {
            if !record.isEmpty {
                return AniSkipResolvedIDs(malID: record.malID, anilistID: record.anilistID)
            }
            if now().timeIntervalSince(record.resolvedAt) < Self.negativeCacheLifetime {
                NetworkLog.report(
                    category: "AniSkip", level: .debug,
                    "MAL ID 负缓存命中，7 天内不重试 AniList")
                return AniSkipResolvedIDs(malID: nil, anilistID: nil)
            }
        }
        let resolved = await client.resolveIDs(
            anilistID: identity.anilistID, searchTitles: titles)
        await store.setRecord(
            AniSkipIDRecord(
                malID: resolved.malID, anilistID: resolved.anilistID, resolvedAt: now()),
            for: key)
        if resolved.isEmpty {
            NetworkLog.report(
                category: "AniSkip", level: .info,
                "MAL ID 解析失败（全部候选落空），负缓存 7 天后重试",
                fields: ["candidateCount": .integer(Int64(titles.count))])
        } else {
            NetworkLog.report(
                category: "AniSkip", level: .info,
                "番剧 ID 解析成功",
                fields: [
                    "malID": resolved.malID.map { .integer(Int64($0)) } ?? .null,
                    "anilistID": resolved.anilistID.map { .integer(Int64($0)) } ?? .null,
                ])
        }
        return resolved
    }

    /// 缓存键：身份线索的规范化拼接。直取的 malID 不入缓存，故键里不含它。
    ///
    /// `v2|` 前缀：v1 时代单一中文标题搜空就写负缓存，曾把几部 2026 夏番整季
    /// 挡在 AniSkip 之外；多候选实现后键升版，旧负缓存（含错录）整体作废，
    /// 不做迁移——文件可随时重建。
    static func cacheKey(for identity: AniSkipAnimeIdentity) -> String {
        let parts = [
            identity.anilistID.map(String.init) ?? "-",
            (identity.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            identity.seasonNumber.map(String.init) ?? "-",
            identity.year.map(String.init) ?? "-",
        ]
        let raw = "v2|" + parts.joined(separator: "|")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// `aniskip-ids.json`：MAL ID 解析结果的永久缓存（actor 隔离，原子写，写穿内存缓存）。
/// 文件可由解析随时重建：损坏视为空并允许覆盖（与 mapping 的保守策略不同）。
public actor AniSkipIDStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cached: [String: AniSkipIDRecord]?
    private var loaded = false

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func record(for key: String) -> AniSkipIDRecord? {
        load()[key]
    }

    public func setRecord(_ record: AniSkipIDRecord, for key: String) {
        var map = load()
        map[key] = record
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: url(), options: .atomic)
        cached = map
        loaded = true
    }

    private func url() -> URL {
        directory.appendingPathComponent("aniskip-ids.json")
    }

    private func load() -> [String: AniSkipIDRecord] {
        if loaded, let cached { return cached }
        let fileURL = url()
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let map = try? decoder.decode([String: AniSkipIDRecord].self, from: data)
        else {
            // 文件缺失 / 损坏也按「空」定下来并置 loaded：否则每次 record(for:) 都要重碰
            // 一遍文件系统（fileExists + 读 + 解码）。本文件只有本 actor 会写，损坏就是
            // 当空用、下次 setRecord 整体覆盖（见类型注释）。
            cached = [:]
            loaded = true
            return [:]
        }
        cached = map
        loaded = true
        return map
    }
}
