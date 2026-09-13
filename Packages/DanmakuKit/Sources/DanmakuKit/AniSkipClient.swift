import DiagnosticsKit
import Foundation

/// AniSkip 区间类型。API 的 `types` 取值（服务端校验枚举，见 2026-09-13 探针）。
public enum AniSkipIntervalType: String, Sendable, Equatable {
    case opening = "op"
    case ending = "ed"
    case mixedOpening = "mixed-op"
    case mixedEnding = "mixed-ed"
    case recap
}

/// 一段社区标注的区间（秒）。AniSkip 只存 `(start, end)`，类型由 `skipType` 区分。
public struct AniSkipInterval: Sendable, Equatable {
    public let type: AniSkipIntervalType
    public let startSeconds: Double
    public let endSeconds: Double
}

/// AniSkip 调用错误。无数据（404 `found:false`）不是错误——客户端归一化为 nil。
public enum AniSkipError: Error, Sendable {
    case invalidRequest(String)
    case network(URLError)
    case httpStatus(Int)
    case decodingFailed(String)
}

/// AniSkip 只读客户端（https://api.aniskip.com，众包 OP/ED 区间 + 社区投票背书）。
///
/// `GET /v2/skip-times/{malId}/{episodeNumber}?types=…&episodeLength={秒|0}`。
/// 只认 MAL ID（AniList ID 直接查不命中，已实测）；`episodeLength` 是过滤条件，
/// 传了不匹配的长度结果为空——知道真实时长就传（白赚一道正确性校验），未知传 0。
///
/// `URLSession` 可注入（测试用 mock 协议）；瞬态错误（超时/断网、5xx、429）
/// 走共享 `RetryPolicy` 重试，口径与 `DandanplayError.isRetryable` 一致。
/// 限流 120 请求/窗口（实测响应头），一集一查的节奏远用不满。
public struct AniSkipClient: Sendable {
    private let baseURL: URL
    private let userAgent: String
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public init(
        baseURL: URL = URL(string: "https://api.aniskip.com")!,
        userAgent: String = "OcPlayer (https://github.com/1824239290/OcPlayer)",
        session: URLSession? = nil,
        retryPolicy: RetryPolicy = RetryPolicy()
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.session = session ?? DanmakuNetworking.makeSession()
        self.retryPolicy = retryPolicy
    }

    /// 取某集的社区标注区间。无数据返回 nil；网络/协议错误抛 `AniSkipError`。
    /// - Parameters:
    ///   - malID: MyAnimeList 番剧 ID（按季分条目，集数为条目内集数）。
    ///   - episodeNumber: 条目内集数（我们侧的 season-relative 集数同口径）。
    ///   - episodeLengthSeconds: 已知集时长传真实值（服务端按它过滤），未知传 nil（→0）。
    public func skipTimes(
        malID: Int,
        episodeNumber: Int,
        episodeLengthSeconds: Int?
    ) async throws -> [AniSkipInterval]? {
        guard malID >= 1, episodeNumber >= 1 else {
            throw AniSkipError.invalidRequest("malID 与 episodeNumber 必须为正")
        }
        var components = URLComponents(
            url: baseURL.appending(path: "/v2/skip-times/\(malID)/\(episodeNumber)"),
            resolvingAgainstBaseURL: false
        )
        let types = [
            AniSkipIntervalType.opening, .ending, .mixedOpening, .mixedEnding,
        ].map(\.rawValue)
        components?.queryItems = types.map { URLQueryItem(name: "types", value: $0) }
            + [URLQueryItem(name: "episodeLength", value: String(max(0, episodeLengthSeconds ?? 0)))]
        guard let url = components?.url else {
            throw AniSkipError.decodingFailed("AniSkip URL 组装失败")
        }

        let spec = HTTPRequestSpec(url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"])
        let exchange: HTTPExchange = try await retryPolicy.run {
            try await Self.performExchange(spec: spec, session: session)
        } shouldRetry: { error in
            Self.isRetryable(error)
        } onRetry: { attempt, error in
            NetworkLog.report(
                category: "AniSkip", level: .debug,
                "请求重试 尝试=\(attempt + 1)/\(retryPolicy.attempts) error=\(error)")
        }
        if exchange.statusCode == 404 {
            // 无数据是常态（长尾番/新番未收录），归一化为 nil 而非错误。
            return nil
        }
        guard (200..<300).contains(exchange.statusCode) else {
            throw AniSkipError.httpStatus(exchange.statusCode)
        }
        return try Self.decode(exchange.data)
    }

    // MARK: 内部

    private static func performExchange(spec: HTTPRequestSpec, session: URLSession) async throws -> HTTPExchange {
        do {
            return try await HTTPClient(session: session, category: "AniSkip").exchange(spec)
        } catch let transport as HTTPTransportError {
            switch transport {
            case .url(let urlError):
                throw AniSkipError.network(urlError)
            case .nonHTTP:
                throw AniSkipError.decodingFailed("非 HTTP 响应")
            // exchange 对 >=400 正常返回不抛，这个分支理论不可达，兜底防漏。
            case .status, .other:
                throw AniSkipError.decodingFailed("非 HTTP 层错误")
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let skipError = error as? AniSkipError else { return false }
        switch skipError {
        case .network(let urlError):
            switch NetworkErrorClassifier.kind(for: urlError.errorCode) {
            case .timedOut, .noConnection:
                return true
            default:
                return false
            }
        case .httpStatus(let code):
            return code == 502 || code == 503 || code == 504 || code == 429
        case .decodingFailed, .invalidRequest:
            return false
        }
    }

    private static func decode(_ data: Data) throws -> [AniSkipInterval]? {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Interval: Decodable {
                    let startTime: Double
                    let endTime: Double
                }
                let interval: Interval
                let skipType: String
            }
            let found: Bool
            let results: [Result]?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AniSkipError.decodingFailed("\(error)")
        }
        guard response.found else { return nil }
        // 未知 skipType 容错跳过（服务端将来加类型不炸旧客户端）。
        return (response.results ?? []).compactMap { result in
            guard let type = AniSkipIntervalType(rawValue: result.skipType) else { return nil }
            return AniSkipInterval(
                type: type,
                startSeconds: result.interval.startTime,
                endSeconds: result.interval.endTime
            )
        }
    }
}

// MARK: - 区间 → 片头提示

public extension DanmakuIntroHint {
    /// AniSkip 区间 → 片头提示。OP/mixed-op 的结束点即「跳过片头」目标；起点直接用
    /// 区间起点——AniSkip 存的是精确 OP 区间，有冷开场/前情的集天然不从 0 起
    /// （如 OP 在 638–728s 的集，按钮只在 OP 区间内出现），比弹幕的最早报点估计更准。
    /// 没有 OP 区间（只有 ED/recap）构不成片头提示。
    init?(aniskipIntervals intervals: [AniSkipInterval]) {
        guard let opening = intervals.first(where: {
            $0.type == .opening || $0.type == .mixedOpening
        }) else { return nil }
        let end = opening.endSeconds
        let start = max(0, opening.startSeconds)
        // 合理性钳制看的是 OP 区间长度（冷开场集的结束点绝对值可以很大）：
        // 超长/过短/倒挂的区间按坏数据处理，是错季匹配时的防护。
        guard end >= 10, end <= 1_800, start < end - 1, end - start <= 400
        else { return nil }
        self.init(
            startSeconds: start,
            endSeconds: end,
            evidenceCount: 1,
            source: .aniskip
        )
    }
}
