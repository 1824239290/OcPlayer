import CryptoKit
import DiagnosticsKit
import Foundation

/// 一次 MAL ID 解析所需的番剧身份信息（全部可选，至少要有一项可解析的线索）。
public struct AniSkipAnimeIdentity: Sendable, Equatable {
    /// 直接来自 Jellyfin ProviderIds 的 MyAnimeList ID（零网络，最优先）。
    public let malID: Int?
    /// ProviderIds 里的 AniList ID（一次 GraphQL 换算成 MAL）。
    public let anilistID: Int?
    /// 标题搜索兜底（优先弹幕匹配出的 dandanplay 标题——常带季标记，搜索命中率高）。
    public let title: String?
    /// 季数 / 年份：进缓存键做区分（不同季是不同 MAL 条目），搜索暂不用于消歧。
    public let seasonNumber: Int?
    public let year: Int?

    public init(malID: Int? = nil, anilistID: Int? = nil, title: String? = nil,
                seasonNumber: Int? = nil, year: Int? = nil) {
        self.malID = malID
        self.anilistID = anilistID
        self.title = title
        self.seasonNumber = seasonNumber
        self.year = year
    }
}

/// `mal-id-mappings.json` 的单条记录。`malID == nil` 是负缓存（搜不中），
/// 7 天后允许重试——AniList 在长尾番上的收录会变，死缓存会永久错过新数据。
public struct AniSkipIDRecord: Codable, Sendable, Equatable {
    public let malID: Int?
    public let resolvedAt: Date

    public init(malID: Int?, resolvedAt: Date) {
        self.malID = malID
        self.resolvedAt = resolvedAt
    }
}

/// AniList GraphQL 只读客户端（无需鉴权；限流 90 req/min，远低于我们的节奏）。
struct AniListClient: Sendable {
    let session: URLSession

    /// 标题/AniList ID → MAL ID。搜不到或网络失败返回 nil（调用方降级，不抛错：
    /// 映射失败只意味着跳片头少一路数据源，不该打断弹幕装载）。
    func malID(anilistID: Int?, searchTitle: String?) async -> Int? {
        let query: String
        let variables: [String: String]
        if let anilistID {
            query = "query ($id: Int) { Media(id: $id) { id idMal } }"
            variables = ["id": String(anilistID)]
        } else if let searchTitle, !searchTitle.isEmpty {
            query = """
            query ($search: String) { Page(perPage: 5) { media(search: $search, type: ANIME) { id idMal } } }
            """
            variables = ["search": searchTitle]
        } else {
            return nil
        }

        let body: Data
        do {
            struct GraphQLRequest: Encodable {
                let query: String
                let variables: [String: String]
            }
            body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
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

        struct Response: Decodable {
            // GraphQL 字段名按查询原样返回：Media(id:) 顶层是 "Media"，搜索顶层是 "Page"。
            struct Media: Decodable { let idMal: Int? }
            struct Page: Decodable { let media: [Media]? }
            struct DataPayload: Decodable {
                let media: Media?
                let page: Page?
                enum CodingKeys: String, CodingKey {
                    case media = "Media"
                    case page = "Page"
                }
            }
            let data: DataPayload?
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: exchange.data)
            if let media = decoded.data?.media {
                return media.idMal
            }
            // 搜索取首个带 idMal 的条目。已知局限：标题搜索不分季，长篇/同多季
            // 同名番可能命中别的季；OP 时长在季间通常一致，错季代价可接受，
            // 详见接入设计（episodeLength 过滤 + 区间合理性钳制兜底）。
            if let page = decoded.data?.page {
                return page.media?.compactMap(\.idMal).first
            }
            return nil
        } catch {
            NetworkLog.report(category: "AniList", level: .warning, "GraphQL 解码失败: \(error)")
            return nil
        }
    }
}

/// MAL ID 解析器：ProviderIds 直取 → 缓存 → AniList（按 ID 换算 / 标题搜索）。
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

    /// 解析 MAL ID。无任何线索或解析失败返回 nil。
    public func malID(for identity: AniSkipAnimeIdentity) async -> Int? {
        // 直取路径零成本，不走缓存。
        if let malID = identity.malID, malID >= 1 {
            return malID
        }
        let key = Self.cacheKey(for: identity)
        if let record = await store.record(for: key) {
            if let malID = record.malID {
                return malID
            }
            if now().timeIntervalSince(record.resolvedAt) < Self.negativeCacheLifetime {
                return nil
            }
        }
        let resolved = await client.malID(
            anilistID: identity.anilistID,
            searchTitle: identity.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await store.setRecord(AniSkipIDRecord(malID: resolved, resolvedAt: now()), for: key)
        return resolved
    }

    /// 缓存键：身份线索的规范化拼接。直取的 malID 不入缓存，故键里不含它。
    static func cacheKey(for identity: AniSkipAnimeIdentity) -> String {
        let raw = [
            identity.anilistID.map(String.init) ?? "-",
            (identity.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            identity.seasonNumber.map(String.init) ?? "-",
            identity.year.map(String.init) ?? "-",
        ].joined(separator: "|")
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
