import DiagnosticsKit
import Foundation

/// 网络层诊断日志。只记请求路径，任何 token 都由红actor 兜底，绝不进日志。
/// 实现委托 DiagnosticsKit.NetworkLog（按 category 共享 logger），保留公开 API 形状。
public enum BangumiNetworkLog {
    public static let logger = NetworkLog.logger(category: "Bangumi")

    static func requestStarted(_ path: String) {
        NetworkLog.requestStarted(category: "Bangumi", path: path)
    }

    static func requestSucceeded(_ path: String, duration: TimeInterval) {
        NetworkLog.requestSucceeded(category: "Bangumi", path: path, duration: duration)
    }

    static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
        NetworkLog.requestFailed(category: "Bangumi", path: path, error: error, duration: duration)
    }

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

private struct OAuthErrorResponse: Decodable {
    let error: String
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
    private let appInfo: BangumiAppInfo
    private let userAgent: String
    private let authDomain: BangumiURL.AuthDomain

    private var auth: BangumiAuth?
    private var anonymousSession: URLSession?
    private var authorizedSession: URLSession?

    private var authGeneration: UInt64 = 0
    private var authorizedSessionGeneration: UInt64?
    private var oauthExchangeGeneration: UInt64 = 0
    private var refreshTask: Task<CredentialSnapshot, Error>?
    private var refreshGeneration: UInt64 = 0

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(
        store: BangumiStore = .shared,
        appInfo: BangumiAppInfo? = nil,
        userAgent: String = "OcPlayer/0.1 (BangumiKit)",
        authDomain: BangumiURL.AuthDomain = .origin
    ) {
        self.store = store
        self.appInfo = appInfo ?? Self.readAppInfoFromBundle()
        self.userAgent = userAgent
        self.authDomain = authDomain
    }

    /// 从 Info.plist 读取 OAuth 凭证（BANGUMI_APP_ID / BANGUMI_APP_SECRET），
    /// 缺失时返回空凭证（登录不可用但请求匿名接口不受影响）。
    private static func readAppInfoFromBundle() -> BangumiAppInfo {
        guard let info = Bundle.main.infoDictionary,
              let clientId = info["BANGUMI_APP_ID"] as? String, !clientId.isEmpty,
              let clientSecret = info["BANGUMI_APP_SECRET"] as? String, !clientSecret.isEmpty
        else {
            return BangumiAppInfo(clientId: "", clientSecret: "", callbackURL: "")
        }
        let callback = info["BANGUMI_OAUTH_CALLBACK"] as? String ?? "ocplayer://oauth/callback"
        return BangumiAppInfo(clientId: clientId, clientSecret: clientSecret, callbackURL: callback)
    }

    // MARK: - 公开接口

    public func isAuthenticated() -> Bool {
        store.isAuthenticated
    }

    public func oauthBase() -> String {
        BangumiURL.auth(path: "/oauth", authDomain: authDomain).absoluteString
    }

    public func buildOAuthURL() -> URL {
        let baseURL = URL(string: "\(oauthBase())/authorize")!
        return baseURL.appending(queryItems: [
            URLQueryItem(name: "client_id", value: appInfo.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: appInfo.callbackURL),
        ])
    }

    public func hasValidAppInfo() -> Bool {
        !appInfo.clientId.isEmpty && !appInfo.clientSecret.isEmpty
    }

    public func exchangeForAccessToken(code: String) async throws -> UInt64 {
        let exchangeGeneration = beginOAuthExchange()
        let url = URL(string: "\(oauthBase())/access_token")!
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": appInfo.clientId,
            "client_secret": appInfo.clientSecret,
            "code": code,
            "redirect_uri": appInfo.callbackURL,
        ]
        let data = try await request(url: url, method: "POST", body: body, auth: .disabled)
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

    public func request(
        url: URL, method: String, body: Any? = nil, auth: BangumiAuthMode = .auto
    ) async throws -> Data {
        let maxRetries = 2
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                BangumiNetworkLog.logger.warning(
                    "重试 \(method) \(url.absoluteString) (尝试 \(attempt + 1)/\(maxRetries + 1))")
            }

            let start = ContinuousClock.now
            var authed: Bool
            switch auth {
            case .auto: authed = isAuthenticated()
            case .required: authed = true
            case .disabled: authed = false
            }
            BangumiNetworkLog.requestStarted(BangumiNetworkLog.logPath(for: url))

            let requestSession: RequestSession
            do {
                requestSession = try await getSession(authorized: authed)
            } catch SessionError.authenticationRequired(let credentialGeneration) {
                await notifyAuthenticationRequired(ifCurrent: credentialGeneration)
                throw BangumiError.requireLogin
            }

            var request = URLRequest(url: url)
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpMethod = method
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await requestSession.session.data(for: request)
            } catch let error as NSError where error.domain == NSURLErrorDomain {
                let duration = start.duration(to: .now)
                BangumiNetworkLog.requestFailed(
                    BangumiNetworkLog.logPath(for: url), error: error,
                    duration: duration.timeInterval)
                let err = BangumiError(networkError: error)
                if err.isRetryable && attempt < maxRetries {
                    lastError = err
                    continue
                }
                throw err
            } catch {
                let duration = start.duration(to: .now)
                BangumiNetworkLog.requestFailed(
                    BangumiNetworkLog.logPath(for: url), error: error,
                    duration: duration.timeInterval)
                throw BangumiError(request: "\(error)")
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw BangumiError(message: "api response nil")
            }
            let duration = start.duration(to: .now)
            let requestID = httpResponse.allHeaderFields["x-request-id"] as? String

            if httpResponse.statusCode < 400 {
                BangumiNetworkLog.requestSucceeded(
                    BangumiNetworkLog.logPath(for: url), duration: duration.timeInterval)
                return data
            } else if httpResponse.statusCode == 429 {
                let err = BangumiError(notice: "请求过于频繁，请稍后再试")
                BangumiNetworkLog.requestFailed(
                    BangumiNetworkLog.logPath(for: url), error: err,
                    duration: duration.timeInterval)
                if attempt < maxRetries {
                    lastError = err
                    continue
                }
                throw err
            } else if httpResponse.statusCode == 401 {
                if let requestAuthGeneration = requestSession.credentialGeneration {
                    guard requestAuthGeneration == authGeneration else {
                        throw BangumiError(ignore: "Discarded stale unauthorized response")
                    }
                    await notifyAuthenticationRequired(ifCurrent: requestAuthGeneration)
                }
                throw BangumiError.requireLogin
            } else if httpResponse.statusCode == 403 {
                throw BangumiError(notice: "请求被拒绝，请检查权限")
            } else {
                let errorText = String(data: data, encoding: .utf8) ?? ""
                let err = BangumiError(
                    code: httpResponse.statusCode, response: errorText, requestID: requestID)
                BangumiNetworkLog.requestFailed(
                    BangumiNetworkLog.logPath(for: url), error: err,
                    duration: duration.timeInterval)
                if err.isRetryable && attempt < maxRetries {
                    lastError = err
                    continue
                }
                throw err
            }
        }

        if let lastError { throw lastError }
        throw BangumiError(request: "Request failed without an error")
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
        let session = URLSession(configuration: buildSessionConfig(accessToken: nil))
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
            let session = URLSession(
                configuration: buildSessionConfig(accessToken: credentials.auth.accessToken))
            authorizedSession = session
            authorizedSessionGeneration = credentials.generation
            return RequestSession(session: session, credentialGeneration: credentials.generation)
        }

        throw BangumiError(ignore: "Credentials changed while building an authorized session")
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
        let url = URL(string: "\(oauthBase())/access_token")!
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": appInfo.clientId,
            "client_secret": appInfo.clientSecret,
            "refresh_token": auth.refreshToken,
            "redirect_uri": appInfo.callbackURL,
        ]
        let data: Data
        do {
            data = try await request(url: url, method: "POST", body: body, auth: .disabled)
        } catch let error as BangumiError {
            if case .badRequest(let response) = error,
               let responseData = response.data(using: .utf8),
               let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: responseData),
               oauthError.error == "invalid_grant" {
                throw BangumiError.requireLogin
            }
            if case .ignore = error, Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        return try saveAuthResponse(
            data: data, commit: .refresh(credentialGeneration: expectedGeneration))
    }

    // MARK: - 凭证生命周期

    private func beginOAuthExchange() -> UInt64 {
        oauthExchangeGeneration &+= 1
        return oauthExchangeGeneration
    }

    private func saveAuthResponse(data: Data, commit: CredentialCommit) throws -> CredentialSnapshot {
        let response: BangumiTokenResponse = try decodeResponse(data)
        let auth = BangumiAuth(response: response)
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
