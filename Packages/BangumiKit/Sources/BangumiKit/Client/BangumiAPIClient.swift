import DiagnosticsKit
import Foundation

/// 网络层诊断日志。只记请求路径，任何 token 都由红actor 兜底，绝不进日志。
/// 实现委托 DiagnosticsKit.NetworkLog（按 category 共享 logger），保留公开 API 形状。
public enum BangumiNetworkLog {
    public static let logger = NetworkLog.logger(category: "Bangumi")

    static func logPath(for url: URL?) -> String {
        NetworkLog.logPath(for: url)
    }
}

/// 请求是否带鉴权。
public enum BangumiAuthMode: Sendable {
    case auto
    case disabled
    case required
}

private struct CredentialSnapshot: Sendable {
    let auth: BangumiAuth
    let generation: UInt64
}

private enum CredentialCommit: Sendable {
    case oauth(exchangeGeneration: UInt64)
    case refresh(credentialGeneration: UInt64)
}

private struct RequestSession {
    let session: URLSession
    let credentialGeneration: UInt64?
}

private enum SessionError: Error {
    case authenticationRequired(credentialGeneration: UInt64)
}

/// 网关统一错误信封：`{"success": false, "error": {"code", "message"}}`。
private struct GatewayErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String?
    }

    let success: Bool
    let error: Payload?
}

/// Bangumi 底层 HTTP 客户端：只负责 OAuth 凭证生命周期和 HTTP 请求。
///
/// 业务逻辑（收藏同步、章节更新等）在 `BangumiService` 层，不直接进这里。
/// generation 代际管理是整个凭证系统的核心：任何登录/刷新/登出都会推进
/// `authGeneration`，在途请求醒来后发现代际不匹配就自我作废，避免陈旧凭证覆盖新凭证。
public actor BangumiAPIClient {
    public static let shared = BangumiAPIClient()

    /// 401 触发时发的通知（object 是 NSNumber 包着的 generation，供 UI 判断是否仍为当前凭证）。
    public static let authenticationRequiredNotification = Notification.Name(
        "BangumiAPIClientAuthenticationRequired")

    private let store: BangumiStore
    private let userAgent: String
    /// 网关 OAuth 配置。由 App 层在启动 / 网关设置变更时注入（`configureGateway`）：
    /// token 交换与刷新都要经网关，凭证不进客户端。
    private var gateway: BangumiGatewayConfiguration?
    /// 测试注入的 URLSession 构造（mock 协议）；nil 用生产配置。
    private let sessionFactory: (@Sendable (String?) -> URLSession)?

    private var auth: BangumiAuth?
    private var anonymousSession: URLSession?
    private var authorizedSession: URLSession?

    private var authGeneration: UInt64 = 0
    private var authorizedSessionGeneration: UInt64?
    private var oauthExchangeGeneration: UInt64 = 0
    private var refreshTask: Task<CredentialSnapshot, Error>?
    private var refreshGeneration: UInt64 = 0
    /// OAuth 授权流的 CSRF 防护：buildOAuthURL 时生成，回调换 token 时校验后清空。
    /// 放 actor 内存即可（build → 打开 → 回调是瞬时流程）；App 在授权页停留期间
    /// 被重启会丢 state，校验失败是安全侧失败，符合 OAuth state 语义。
    private var pendingOAuthState: String?

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(
        store: BangumiStore = .shared,
        gateway: BangumiGatewayConfiguration? = nil,
        userAgent: String = "OcPlayer/0.1 (BangumiKit)",
        sessionFactory: (@Sendable (String?) -> URLSession)? = nil
    ) {
        self.store = store
        self.gateway = gateway
        self.userAgent = userAgent
        self.sessionFactory = sessionFactory
    }

    /// App 层注入网关配置（启动时 + 设置变更时各推一次）。
    public func configureGateway(_ configuration: BangumiGatewayConfiguration?) {
        gateway = configuration
    }

    // MARK: - 公开接口

    public func isAuthenticated() -> Bool {
        store.isAuthenticated
    }

    /// 向网关要授权地址。`client_id` / `redirect_uri` 都在网关侧，
    /// 客户端只生成 state 并暂存，回调换 token 时校验。
    public func buildOAuthURL() async throws -> URL {
        // state 防 CSRF：生成后存内存，回调换 token 时校验（见 exchangeForAccessToken）。
        let state = UUID().uuidString
        pendingOAuthState = state
        let data = try await gatewayRequest(
            path: "/v1/bangumi/oauth/authorize", method: "GET", query: [("state", state)])
        let payload: BangumiAuthorizeResponse = try decodeResponse(data)
        guard let url = URL(string: payload.authorizeUrl), !payload.authorizeUrl.isEmpty else {
            throw BangumiError(notice: "网关返回的授权地址无效")
        }
        return url
    }

    public func exchangeForAccessToken(code: String, state: String) async throws -> UInt64 {
        defer { pendingOAuthState = nil }
        guard let expected = pendingOAuthState, state == expected else {
            throw BangumiError(notice: "授权校验失败，请重新发起登录")
        }
        let exchangeGeneration = beginOAuthExchange()
        let data = try await gatewayRequest(
            path: "/v1/bangumi/oauth/token", method: "POST",
            body: .object(["code": .string(code)]))
        let credentials = try saveAuthResponse(
            data: data, commit: .oauth(exchangeGeneration: exchangeGeneration))
        return credentials.generation
    }

    public func clearCredentials() -> UInt64 {
        invalidateCredentials()
    }

    public func clearCredentials(ifCurrent expectedGeneration: UInt64) -> UInt64? {
        guard expectedGeneration == authGeneration else { return nil }
        return invalidateCredentials()
    }

    public func isCurrentCredentialGeneration(_ generation: UInt64) -> Bool {
        generation == authGeneration
    }

    /// 解码响应（snake_case → camelCase）。
    public func decodeResponse<T: Decodable>(_ data: Data) throws -> T {
        try Self.jsonDecoder.decode(T.self, from: data)
    }

    // MARK: - 请求

    /// 重试策略：3 次尝试、指数退避带抖动、429 的 Retry-After 优先（封顶 60s）。
    /// 传输与计时日志由共享执行器（DiagnosticsKit.HTTPClient）负责；
    /// 这里只留 Bangumi 自己的语义：会话选择、401 代次守卫、状态码分类。
    private static let requestRetryPolicy = RetryPolicy(attempts: 3)

    public func request(
        url: URL, method: String, body: BangumiJSONValue? = nil, auth: BangumiAuthMode = .auto,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await Self.requestRetryPolicy.run {
            var authed: Bool
            switch auth {
            case .auto: authed = isAuthenticated()
            case .required: authed = true
            case .disabled: authed = false
            }

            let requestSession: RequestSession
            do {
                requestSession = try await getSession(authorized: authed)
            } catch SessionError.authenticationRequired(let credentialGeneration) {
                await notifyAuthenticationRequired(ifCurrent: credentialGeneration)
                throw BangumiError.requireLogin
            }

            var spec = HTTPRequestSpec(url: url, method: method)
            spec.headers["Content-Type"] = "application/json"
            for (field, value) in headers {
                spec.headers[field] = value
            }
            if let body {
                spec.body = try JSONEncoder().encode(body)
            }

            let exchange: HTTPExchange
            do {
                exchange = try await HTTPClient(
                    session: requestSession.session, category: "Bangumi"
                ).exchange(spec)
            } catch let transport as HTTPTransportError {
                switch transport {
                case .url(let urlError):
                    throw BangumiError(networkError: urlError as NSError)
                case .nonHTTP:
                    throw BangumiError(message: "api response nil")
                case .other(let description):
                    throw BangumiError(request: description)
                case .status(let code):
                    // exchange 不会为状态码抛 .status（只是日志记号）；防御兜底。
                    throw BangumiError(code: code, response: "", requestID: nil)
                }
            }

            let httpResponse = exchange.response
            let requestID = httpResponse.allHeaderFields["x-request-id"] as? String

            if httpResponse.statusCode < 400 {
                return exchange.data
            } else if httpResponse.statusCode == 429 {
                throw BangumiError.rateLimited(retryAfter: exchange.retryAfter)
            } else if httpResponse.statusCode == 401 {
                if let requestAuthGeneration = requestSession.credentialGeneration {
                    guard requestAuthGeneration == authGeneration else {
                        throw BangumiError(ignore: "Discarded stale unauthorized response")
                    }
                    await notifyAuthenticationRequired(ifCurrent: requestAuthGeneration)
                }
                throw BangumiError.requireLogin
            } else if httpResponse.statusCode == 403 {
                // 保留响应体：网关的 403 靠 `error.code` 区分原因（SCOPE_REQUIRED /
                // OCPLAY_USER_AGENT_REQUIRED），丢了 body 就只剩笼统文案。
                // 面向用户的文案与旧行为一致（`.forbidden` 的 userMessage 同字面）。
                throw BangumiError(code: 403, response: exchange.bodyText, requestID: requestID)
            } else {
                throw BangumiError(
                    code: httpResponse.statusCode,
                    response: exchange.bodyText,
                    requestID: requestID)
            }
        } shouldRetry: { error in
            (error as? BangumiError)?.isRetryable ?? false
        } retryAfterProvider: { error in
            if case .rateLimited(let retryAfter) = error as? BangumiError { return retryAfter }
            return nil
        } onRetry: { attempt, _ in
            BangumiNetworkLog.logger.warning(
                "重试 \(method) \(url.absoluteString) (尝试 \(attempt + 1)/\(Self.requestRetryPolicy.attempts))")
        }
    }

    // MARK: - 网关 OAuth

    /// 网关 OAuth 请求：认证走 `X-API-Key`，身份标识走 `OcPlay/` User-Agent
    /// （会话默认的 Bangumi UA 被逐请求覆盖），不带本地 access token。
    /// 网关错误信封里的业务码在这里转成语义化错误，调用方不必认识网关码。
    private func gatewayRequest(
        path: String, method: String, query: [(String, String)] = [], body: BangumiJSONValue? = nil
    ) async throws -> Data {
        guard let gateway else {
            throw BangumiError(notice: "尚未配置弹幕网关，无法登录 Bangumi")
        }
        guard var components = URLComponents(url: gateway.baseURL, resolvingAgainstBaseURL: false)
        else { throw BangumiError(notice: "网关地址无效") }
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw BangumiError(notice: "网关地址无效") }

        do {
            return try await request(
                url: url, method: method, body: body, auth: .disabled,
                headers: ["X-API-Key": gateway.apiKey, "User-Agent": gateway.userAgent])
        } catch let error as BangumiError {
            throw Self.mapGatewayOAuthError(error)
        }
    }

    private static func mapGatewayOAuthError(_ error: BangumiError) -> BangumiError {
        // 401 是「网关 API Key 无效」，不是 Bangumi 登录态失效，别报成「请重新登录」。
        if case .requireLogin = error {
            return .notice("网关 API Key 无效，请检查设置")
        }
        guard let body = error.responseBody,
              let envelope = try? JSONDecoder().decode(
                GatewayErrorEnvelope.self, from: Data(body.utf8)),
              let code = envelope.error?.code
        else { return error }

        switch code {
        case "BANGUMI_OAUTH_REJECTED":
            // 授权码过期/已用、refresh token 失效：本地凭证已废，清掉重新登录。
            return .requireLogin
        case "SCOPE_REQUIRED":
            return .notice("网关 API Key 缺少 bgm:oauth 权限")
        case "OCPLAY_USER_AGENT_REQUIRED":
            return .notice("网关拒绝了请求标识，请更新 App 后重试")
        case "GATEWAY_NOT_CONFIGURED":
            return .notice("网关尚未配置 Bangumi 登录")
        default:
            // 429 / 502 等保持原样：重试与退避语义由 BangumiError.isRetryable 决定。
            return error
        }
    }

    // MARK: - 会话

    private func getSession(authorized: Bool) async throws -> RequestSession {
        if !authorized {
            return RequestSession(session: try getAnonymousSession(), credentialGeneration: nil)
        }
        return try await getAuthorizedSession()
    }

    private func getAnonymousSession() throws -> URLSession {
        if let session = anonymousSession { return session }
        let session = makeSession(accessToken: nil)
        anonymousSession = session
        return session
    }

    private func getAuthorizedSession() async throws -> RequestSession {
        if let auth,
           !auth.isExpired(),
           let session = authorizedSession,
           let sessionGeneration = authorizedSessionGeneration,
           sessionGeneration == authGeneration {
            return RequestSession(session: session, credentialGeneration: sessionGeneration)
        }

        for _ in 0..<2 {
            let attemptedGeneration = authGeneration
            let credentials: CredentialSnapshot
            do {
                credentials = try await getAccessToken()
            } catch BangumiError.requireLogin {
                throw SessionError.authenticationRequired(credentialGeneration: attemptedGeneration)
            }
            guard credentials.generation == authGeneration else { continue }
            if let session = authorizedSession,
               authorizedSessionGeneration == credentials.generation {
                return RequestSession(session: session, credentialGeneration: credentials.generation)
            }
            let session = makeSession(accessToken: credentials.auth.accessToken)
            authorizedSession = session
            authorizedSessionGeneration = credentials.generation
            return RequestSession(session: session, credentialGeneration: credentials.generation)
        }

        throw BangumiError(ignore: "Credentials changed while building an authorized session")
    }

    private func makeSession(accessToken: String?) -> URLSession {
        if let sessionFactory { return sessionFactory(accessToken) }
        return URLSession(configuration: buildSessionConfig(accessToken: accessToken))
    }

    private func buildSessionConfig(accessToken: String?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        var headers: [AnyHashable: Any] = ["User-Agent": userAgent]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        config.httpAdditionalHeaders = headers
        return config
    }

    private func getAccessToken() async throws -> CredentialSnapshot {
        if let auth {
            if auth.isExpired() {
                return try await performTokenRefresh(auth: auth)
            }
            return CredentialSnapshot(auth: auth, generation: authGeneration)
        } else {
            guard let storedAuth = store.auth else {
                throw BangumiError.requireLogin
            }
            auth = storedAuth
            if storedAuth.isExpired() {
                return try await performTokenRefresh(auth: storedAuth)
            }
            return CredentialSnapshot(auth: storedAuth, generation: authGeneration)
        }
    }

    /// 单飞去重的 token 刷新：并发请求同时撞上过期时只发一次刷新，其余等待同一个 Task。
    private func performTokenRefresh(auth: BangumiAuth) async throws -> CredentialSnapshot {
        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        refreshGeneration &+= 1
        let refreshGen = refreshGeneration
        let credentialGeneration = authGeneration

        let task = Task<CredentialSnapshot, Error> {
            do {
                return try await refreshAccessToken(auth: auth, expectedGeneration: credentialGeneration)
            } catch is CancellationError {
                if self.refreshGeneration != refreshGen {
                    throw BangumiError(ignore: "Token refresh cancelled")
                }
                throw BangumiError(notice: "令牌刷新超时，请稍后再试")
            } catch BangumiError.requireLogin {
                guard credentialGeneration == self.authGeneration else {
                    throw BangumiError(ignore: "Discarded stale token refresh failure")
                }
                throw BangumiError.requireLogin
            } catch {
                throw error
            }
        }

        refreshTask = task

        // 15 秒超时看门狗：刷新卡住时取消，避免请求永久挂起。
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            task.cancel()
        }

        defer {
            timeoutTask.cancel()
            if refreshGeneration == refreshGen {
                refreshTask = nil
            }
        }

        return try await task.value
    }

    private func refreshAccessToken(
        auth: BangumiAuth, expectedGeneration: UInt64
    ) async throws -> CredentialSnapshot {
        let data: Data
        do {
            data = try await gatewayRequest(
                path: "/v1/bangumi/oauth/refresh", method: "POST",
                body: .object(["refresh_token": .string(auth.refreshToken)]))
        } catch let error as BangumiError {
            if case .ignore = error, Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        return try saveAuthResponse(
            data: data, commit: .refresh(credentialGeneration: expectedGeneration),
            fallbackRefreshToken: auth.refreshToken)
    }

    // MARK: - 凭证生命周期

    private func beginOAuthExchange() -> UInt64 {
        oauthExchangeGeneration &+= 1
        return oauthExchangeGeneration
    }

    private func saveAuthResponse(
        data: Data, commit: CredentialCommit, fallbackRefreshToken: String? = nil
    ) throws -> CredentialSnapshot {
        let response: BangumiTokenResponse = try decodeResponse(data)
        let auth = BangumiAuth(response: response, fallbackRefreshToken: fallbackRefreshToken)
        let encoded = try JSONEncoder().encode(auth)
        try Task.checkCancellation()
        guard let credentials = storeCredentials(auth, encodedData: encoded, commit: commit) else {
            throw BangumiError(ignore: "Discarded stale token response")
        }
        return credentials
    }

    private func storeCredentials(
        _ auth: BangumiAuth, encodedData: Data, commit: CredentialCommit
    ) -> CredentialSnapshot? {
        switch commit {
        case .oauth(let exchangeGeneration):
            guard exchangeGeneration == oauthExchangeGeneration else { return nil }
            oauthExchangeGeneration &+= 1
            refreshGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
        case .refresh(let credentialGeneration):
            guard credentialGeneration == authGeneration else { return nil }
        }
        authGeneration &+= 1
        authorizedSession?.invalidateAndCancel()
        authorizedSession = nil
        authorizedSessionGeneration = nil
        store.auth = auth
        self.auth = auth
        return CredentialSnapshot(auth: auth, generation: authGeneration)
    }

    @discardableResult
    private func invalidateCredentials() -> UInt64 {
        authGeneration &+= 1
        oauthExchangeGeneration &+= 1
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        authorizedSession?.invalidateAndCancel()
        authorizedSession = nil
        authorizedSessionGeneration = nil
        auth = nil
        store.auth = nil
        return authGeneration
    }

    /// 通知 UI「这一代凭证需要重新登录」。
    ///
    /// 只比对代际，**不看 `isAuthenticated`**：凭证已经被清掉、只剩标记位残留时，
    /// 恰恰最需要这条通知把 UI 拉回未登录态。
    private func notifyAuthenticationRequired(ifCurrent generation: UInt64) async {
        guard generation == authGeneration else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.authenticationRequiredNotification,
                object: NSNumber(value: generation))
        }
    }
}


/// JSON 请求体值（Sendable）：替代 body: Any? 的非 Sendable 签名。
public enum BangumiJSONValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: BangumiJSONValue])
    case array([BangumiJSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }
}
