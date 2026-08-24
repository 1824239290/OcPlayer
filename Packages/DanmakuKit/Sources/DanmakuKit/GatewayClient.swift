import DiagnosticsKit
import Foundation

/// 网关诊断日志。常规请求只记 path；匹配参数只记形态元数据，绝不记录
/// hash、文件名、URL/query 或凭据（脱敏器对 `api_key` 类 key 另有兜底）。
/// 实现委托 DiagnosticsKit.NetworkLog，成功/失败级别与 cache 字段保留本网关的原有口径。
enum DanmakuNetworkLog {
    static func matchRequested(_ request: MatchRequest) {
        let hashPresent = request.fileHash?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        NetworkLog.report(category: "Danmaku", level: .debug, "匹配参数", fields: [
            "hashPresent": .boolean(hashPresent),
            "mode": .string(request.matchMode?.rawValue ?? "unspecified"),
            "size": request.fileSize.map { .integer($0) } ?? .null,
            "duration": request.videoDuration.map { .integer(Int64($0)) } ?? .null,
        ])
    }

    static func requestStarted(_ path: String) {
        NetworkLog.requestStarted(category: "Danmaku", path: path)
    }

    static func requestSucceeded(_ path: String, cache: String?, duration: TimeInterval) {
        NetworkLog.report(
            category: "Danmaku",
            level: .info,
            "请求成功 path=\(path) cache=\(cache ?? "nil") duration_ms=\(Int(duration * 1000))"
        )
    }

    static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
        NetworkLog.report(
            category: "Danmaku",
            level: .warning,
            "请求失败 path=\(path) error=\(error) duration_ms=\(Int(duration * 1000))"
        )
    }
}

// MARK: - 错误

/// 弹幕网关调用错误。
public enum DandanplayError: Error, Equatable, Sendable {
    /// 网关地址未配置或格式无效。
    case notConfigured
    /// HTTP 401：API key 无效或缺失。
    case unauthorized
    /// HTTP 429：每日额度或限流超限。
    case rateLimited
    /// 弹弹play 业务侧返回 `success=false`（匹配/搜索）。
    case businessError(code: Int, message: String?)
    /// 网关返回了非 JSON 或无法解码的结构。
    case decodingFailed(String)
    /// 网络错误（连接失败、超时等）。
    case network(URLError)
    /// 其他 HTTP 错误状态。
    case httpStatus(Int)
    /// 请求参数不满足网关接口约束。
    case invalidRequest(String)

    public static func == (lhs: DandanplayError, rhs: DandanplayError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.unauthorized, .unauthorized),
             (.rateLimited, .rateLimited):
            return true
        case let (.businessError(lc, lm), .businessError(rc, rm)):
            return lc == rc && lm == rm
        case let (.decodingFailed(l), .decodingFailed(r)):
            return l == r
        case let (.network(l), .network(r)):
            return l.errorCode == r.errorCode
        case let (.httpStatus(l), .httpStatus(r)):
            return l == r
        case let (.invalidRequest(l), .invalidRequest(r)):
            return l == r
        default:
            return false
        }
    }
}

public extension DandanplayError {
    /// 面向用户的稳定文案。需要上下文措辞的调用方（如搜索页）自行覆盖个别 case。
    var userMessage: String {
        switch self {
        case .notConfigured: "弹幕网关未配置"
        case .unauthorized: "网关 API Key 无效"
        case .rateLimited: "弹幕请求额度已用完"
        case .businessError(_, let message): message ?? "弹幕服务返回错误"
        case .decodingFailed: "弹幕服务返回了无法解析的数据"
        case .network: "弹幕网络请求失败"
        case .httpStatus: "弹幕服务暂时不可用"
        case .invalidRequest(let message): message
        }
    }
}

// MARK: - 网关结果

/// 带缓存命中标记的响应包装。`cacheStatus` 读自 `X-Gateway-Cache` 头。
public struct GatewayResult<T: Sendable>: Sendable {
    public let payload: T
    public let cacheStatus: String?
}

// MARK: - 配置

/// 弹幕网关调用配置。
public struct DandanplayConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let apiKey: String
    /// 必须以 `OcPlay/` 开头（网关强制校验），例 `OcPlay/1.0.0 (macOS; arm64)`。
    public let userAgent: String

    public init(baseURL: URL, apiKey: String, userAgent: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userAgent = userAgent
    }
}

// MARK: - 客户端

/// 弹弹play 只读网关客户端。封装 `match` / `search` / `comments` 四个业务接口；
/// 认证走 `X-API-Key` 头，身份标识走 `User-Agent`，AppSecret 永远不进客户端。
///
/// `URLSession` 可注入（测试用 mock 协议）。
public struct DanmakuGatewayClient: Sendable {
    public let configuration: DandanplayConfiguration
    private let session: URLSession

    public init(configuration: DandanplayConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? .shared
    }

    // MARK: 接口

    /// `POST /v1/match` — 用 MD5 及所选模式需要的文件名/大小/时长匹配剧集。
    public func match(_ request: MatchRequest) async throws -> GatewayResult<MatchResponse> {
        DanmakuNetworkLog.matchRequested(request)
        return try await post("/v1/match", body: validatedMatchRequest(request))
    }

    /// `GET /v1/search/anime` — 按标题搜索作品。
    public func searchAnime(keyword: String) async throws -> GatewayResult<SearchAnimeResponse> {
        try await get("/v1/search/anime", query: ["keyword": keyword])
    }

    /// `GET /v1/search/episodes` — 按作品名 / TMDB ID 搜索分集（手动匹配用）。
    public func searchEpisodes(
        anime: String? = nil,
        tmdbId: Int? = nil,
        tmdbIdType: Int = 0,
        episode: String? = nil
    ) async throws -> GatewayResult<SearchEpisodesResponse> {
        var query: [String: String] = [:]
        if let anime, !anime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query["anime"] = anime
        }
        if let tmdbId {
            guard tmdbId >= 1 else {
                throw DandanplayError.invalidRequest("tmdbId must be positive")
            }
            query["tmdbId"] = String(tmdbId)
        }
        guard query["anime"] != nil || query["tmdbId"] != nil else {
            throw DandanplayError.invalidRequest("anime or tmdbId is required")
        }
        guard tmdbIdType == 0 || tmdbIdType == 1 else {
            throw DandanplayError.invalidRequest("tmdbIdType must be 0 or 1")
        }
        if tmdbId != nil { query["tmdbIdType"] = String(tmdbIdType) }
        if let episode, !episode.isEmpty { query["episode"] = episode }
        return try await get("/v1/search/episodes", query: query)
    }

    /// `GET /v1/comments/{episodeId}` — 取某集弹幕。
    /// 默认 `withRelated=true`（合并第三方来源）、`chConvert=0`（不繁简转换），对齐网关默认。
    public func comments(episodeId: Int64) async throws -> GatewayResult<CommentResponse> {
        guard episodeId >= 0 else {
            throw DandanplayError.invalidRequest("episodeId must be non-negative")
        }
        return try await get("/v1/comments/\(episodeId)", query: ["withRelated": "true", "chConvert": "0"])
    }

    // MARK: 内部

    private func get<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> GatewayResult<T> {
        let baseURL = try validatedBaseURL()
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw DandanplayError.notConfigured }
        return try await send(url: url, method: "GET", body: nil)
    }

    private func post<T: Decodable & Sendable, B: Encodable & Sendable>(
        _ path: String,
        body: B
    ) async throws -> GatewayResult<T> {
        let url = try validatedBaseURL().appendingPathComponent(path)
        let bodyData = try JSONEncoder().encode(body)
        return try await send(url: url, method: "POST", body: bodyData)
    }

    private func validatedBaseURL() throws -> URL {
        let url = configuration.baseURL
        guard url.scheme?.lowercased() == "https",
              !(url.host?.isEmpty ?? true),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw DandanplayError.invalidRequest("baseURL must be an HTTPS origin") }
        return url
    }

    private func validatedMatchRequest(_ request: MatchRequest) throws -> MatchRequest {
        var request = request
        request.fileName = request.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.fileName?.isEmpty == true { request.fileName = nil }
        request.fileHash = request.fileHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if request.fileHash?.isEmpty == true { request.fileHash = nil }

        guard let hash = request.fileHash else {
            throw DandanplayError.invalidRequest("fileHash 是生产匹配接口的必填参数")
        }
        let isASCIIHexMD5 = hash.utf8.count == 32 && hash.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
        if !isASCIIHexMD5 {
            throw DandanplayError.invalidRequest("fileHash 必须是 32 位十六进制 MD5")
        }
        if let size = request.fileSize, size < 0 {
            throw DandanplayError.invalidRequest("fileSize 不能小于 0")
        }
        if let duration = request.videoDuration, duration <= 0 {
            throw DandanplayError.invalidRequest("videoDuration 必须大于 0")
        }
        switch request.matchMode {
        case .hashAndFileName where request.fileName == nil:
            throw DandanplayError.invalidRequest("hashAndFileName 需要 fileHash 和 fileName")
        case .fileNameOnly where request.fileName == nil:
            throw DandanplayError.invalidRequest("fileNameOnly 需要 fileHash 和 fileName")
        default:
            break
        }
        return request
    }

    private func send<T: Decodable & Sendable>(
        url: URL,
        method: String,
        body: Data?
    ) async throws -> GatewayResult<T> {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = body }

        let logPath = url.path
        DanmakuNetworkLog.requestStarted(logPath)
        let start = Date()

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let cache = http?.value(forHTTPHeaderField: "X-Gateway-Cache")
            let duration = Date().timeIntervalSince(start)

            switch status {
            case 200..<300:
                // match/search 带 ResponseBase 基座先校验 success；comments 不带基座直接解码。
                if let base = try? JSONDecoder().decode(ResponseBase.self, from: data),
                   !base.success {
                    DanmakuNetworkLog.requestFailed(logPath, error: DandanplayError.businessError(
                        code: base.errorCode ?? -1, message: base.errorMessage), duration: duration)
                    throw DandanplayError.businessError(code: base.errorCode ?? -1, message: base.errorMessage)
                }
                do {
                    let payload = try JSONDecoder().decode(T.self, from: data)
                    DanmakuNetworkLog.requestSucceeded(logPath, cache: cache, duration: duration)
                    return GatewayResult(payload: payload, cacheStatus: cache)
                } catch {
                    DanmakuNetworkLog.requestFailed(logPath, error: error, duration: duration)
                    throw DandanplayError.decodingFailed("\(error)")
                }
            case 401:
                DanmakuNetworkLog.requestFailed(logPath, error: DandanplayError.unauthorized, duration: duration)
                throw DandanplayError.unauthorized
            case 429:
                DanmakuNetworkLog.requestFailed(logPath, error: DandanplayError.rateLimited, duration: duration)
                throw DandanplayError.rateLimited
            default:
                DanmakuNetworkLog.requestFailed(logPath, error: DandanplayError.httpStatus(status), duration: duration)
                throw DandanplayError.httpStatus(status)
            }
        } catch let error as DandanplayError {
            throw error
        } catch let error as URLError {
            DanmakuNetworkLog.requestFailed(logPath, error: error, duration: Date().timeIntervalSince(start))
            throw DandanplayError.network(error)
        } catch {
            DanmakuNetworkLog.requestFailed(logPath, error: error, duration: Date().timeIntervalSince(start))
            throw DandanplayError.decodingFailed("\(error)")
        }
    }
}

/// match/search 响应共享的 ResponseBase 基座，用于在解码 payload 前先校验 `success`。
private struct ResponseBase: Decodable {
    let success: Bool
    let errorCode: Int?
    let errorMessage: String?
}
