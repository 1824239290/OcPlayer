import Foundation

/// 共享 HTTP 执行层。
///
/// Bangumi / MoviePilot / 弹弹play 网关三个客户端各自手写同一套
/// 「组 URLRequest → session.data → URLError 分类 → HTTP 状态分支 → 计时日志」，
/// 收敛到这里：单发（`exchange`）与重试（`withRetry`）拆开，各域只保留
/// 自己真正不同的部分（鉴权头注入、401 重登、业务错误映射）。
///
/// 日志走 `NetworkLog`（同 subsystem、按 category 分路），仍是同一份 diagnostics.jsonl。

// MARK: - 请求描述

/// 一次 HTTP 请求的纯值描述（URL 已由调用方拼好）。
public struct HTTPRequestSpec: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// nil = 跟随会话配置。
    public var timeout: TimeInterval?

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public func makeURLRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout {
            request.timeoutInterval = timeout
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        return request
    }
}

// MARK: - 结果与错误

/// 一次完整交换（任何 HTTP 状态都正常返回，状态语义归调用方）。
public struct HTTPExchange: Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public var statusCode: Int { response.statusCode }
    /// 响应体的 UTF-8 文本（错误分支常用）。
    public var bodyText: String { String(data: data, encoding: .utf8) ?? "" }
    /// 429 的 Retry-After（秒；只认秒数写法，HTTP-date 少见且解析收益低）。
    public var retryAfter: Double? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
    }
}

/// 传输层错误（HTTP 状态不算错误——`exchange` 任何状态都返回 HTTPExchange）。
public enum HTTPTransportError: Error, Sendable {
    /// URL 层错误（已按 NSURLError 分类语义归并）。
    case url(URLError)
    /// 响应不是 HTTPURLResponse（理论上 URLSession 不会给）。
    case nonHTTP
    /// HTTP 状态 >=400（仅日志用；状态语义归调用方）。
    case status(Int)
    /// 非 URL 层的其他错误。
    case other(String)

    /// URLError 语义类别（断网/超时/证书…），调 `NetworkErrorClassifier`。
    public var classifiedKind: NetworkErrorClassifier.Kind? {
        guard case .url(let error) = self else { return nil }
        return NetworkErrorClassifier.kind(for: error.errorCode)
    }
}

// MARK: - 执行器

public struct HTTPClient: Sendable {
    public let session: URLSession
    /// 诊断日志 category（Jellyfin / Bangumi / MoviePilot / Danmaku…）。
    public let category: String

    public init(session: URLSession, category: String) {
        self.session = session
        self.category = category
    }

    /// 单发：请求构造 + 发送 + 计时日志 + 传输错误映射。不重试、不分类状态码。
    @discardableResult
    public func exchange(_ spec: HTTPRequestSpec) async throws -> HTTPExchange {
        try await exchange(urlRequest: spec.makeURLRequest(), logURL: spec.url)
    }

    /// 单发（外部已组好 URLRequest 的场景，如定制 URL 拼接 / 签名头）。
    @discardableResult
    public func exchange(urlRequest: URLRequest, logURL: URL? = nil) async throws -> HTTPExchange {
        let path = NetworkLog.logPath(for: logURL ?? urlRequest.url)
        NetworkLog.requestStarted(category: category, path: path)
        let start = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            NetworkLog.requestFailed(
                category: category, path: path, error: error,
                duration: start.duration(to: .now).timeInterval)
            throw HTTPTransportError.url(error)
        } catch {
            NetworkLog.requestFailed(
                category: category, path: path, error: error,
                duration: start.duration(to: .now).timeInterval)
            throw HTTPTransportError.other("\(error)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            NetworkLog.requestFailed(
                category: category, path: path, error: HTTPTransportError.nonHTTP,
                duration: start.duration(to: .now).timeInterval)
            throw HTTPTransportError.nonHTTP
        }

        let duration = start.duration(to: .now).timeInterval
        if httpResponse.statusCode < 400 {
            NetworkLog.requestSucceeded(category: category, path: path, duration: duration)
        } else {
            // 状态语义归调用方（401 重登 / 429 限流 / 业务错误各不相同），
            // 但日志要把 >=400 记成失败级，别把错误响应写成「请求成功」。
            NetworkLog.requestFailed(
                category: category, path: path,
                error: HTTPTransportError.status(httpResponse.statusCode),
                duration: duration, level: .warning)
        }
        return HTTPExchange(data: data, response: httpResponse)
    }
}

// MARK: - 重试

/// 指数退避 + 抖动的重试策略。429 且服务端给了 Retry-After（秒）时以其为准。
public struct RetryPolicy: Sendable {
    /// 总尝试次数（含首发）。1 = 不重试。
    public var attempts: Int
    /// 指数底数（秒）：第 n 次重试前等 base^(n-1) × jitter。
    public var base: Double
    /// 抖动区间（乘数）。
    public var jitter: ClosedRange<Double>
    /// Retry-After 封顶秒数，防异常大数把调用挂死。
    public var retryAfterCeiling: Double

    public init(
        attempts: Int = 3,
        base: Double = 2,
        jitter: ClosedRange<Double> = 0.5...1.5,
        retryAfterCeiling: Double = 60
    ) {
        self.attempts = max(1, attempts)
        self.base = base
        self.jitter = jitter
        self.retryAfterCeiling = retryAfterCeiling
    }

    /// 第 attempt 次（1 起算）重试前的等待纳秒；`retryAfter` 为服务端给的秒数。
    public func backoffNanoseconds(attempt: Int, retryAfter: Double? = nil) -> UInt64 {
        let baseDelay = pow(base, Double(max(0, attempt - 1)))
        var seconds = baseDelay * Double.random(in: jitter)
        if let retryAfter, retryAfter > 0 {
            seconds = min(retryAfter, retryAfterCeiling)
        }
        return UInt64((seconds * 1_000_000_000).rounded())
    }
}

public extension RetryPolicy {
    /// 带重试执行。`shouldRetry` 判断某次错误是否值得再试（网络层错误、429、5xx 由各域
    /// 按自己的错误类型给）；`retryAfterProvider` 从错误里取 Retry-After（有就遵守）。
    /// 取消类错误不重试、直接上抛。
    @discardableResult
    func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T,
        shouldRetry: (Error) -> Bool,
        retryAfterProvider: (Error) -> Double? = { _ in nil },
        onRetry: ((Int, Error) -> Void)? = nil
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                guard attempt < attempts, shouldRetry(error) else { throw error }
                onRetry?(attempt, error)
                let delay = backoffNanoseconds(attempt: attempt, retryAfter: retryAfterProvider(error))
                try await Task.sleep(nanoseconds: delay)
            }
        }
        // 循环结构上不可达（末次必 return/throw），兜底防漏。
        if let lastError { throw lastError }
        throw CancellationError()
    }
}
