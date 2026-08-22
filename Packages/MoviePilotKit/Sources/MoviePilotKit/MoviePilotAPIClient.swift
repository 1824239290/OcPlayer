import DiagnosticsKit
import Foundation

/// v3 的 `ResponseAPIRouter` 会把大多数路由的返回**自动包进** `{success, message, data}`
/// 信封（用户信息、媒体搜索、下载列表都中招）；少数端点又是裸返回（显式声明
/// Response 的、raw 标记的、OAuth2 token）。与其逐端点猜，运行时探测统一剥壳：
/// 顶层是对象且**同时带 `success` 和 `data`** 才剥一层，其余原样返回——裸数组、
/// 裸对象都不满足条件，天然不受影响。
enum MPEnvelope {
    static func unwrap(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains("success"),
              let inner = object["data"]
        else { return data }
        return (try? JSONSerialization.data(withJSONObject: inner)) ?? data
    }
}

/// MoviePilot 网络层诊断日志。只记请求路径与错误摘要，token / 密码绝不进日志。
public enum MoviePilotNetworkLog {
    public static let logger = DiagnosticLogger(subsystem: "dev.jumusu.OcPlayer", category: "MoviePilot")

    static func requestStarted(_ path: String) {
        logger.debug("请求开始 path=\(path)")
    }

    static func requestSucceeded(_ path: String, duration: TimeInterval) {
        logger.debug("请求成功 path=\(path) duration_ms=\(Int(duration * 1000))")
    }

    static func requestFailed(_ path: String, error: Error, duration: TimeInterval) {
        logger.error("请求失败 path=\(path) error=\(error) duration_ms=\(Int(duration * 1000))")
    }

    static func logPath(for url: URL?) -> String {
        guard let url else { return "?" }
        return url.path.isEmpty ? url.absoluteString : url.path
    }
}

/// MoviePilot 底层 HTTP 客户端：登录换 token、401 静默重登、带鉴权的请求。
///
/// MoviePilot 是密码登录换 JWT（8 天有效期，**没有刷新端点**），所以凭证生命周期
/// 比 Bangumi 简单得多：带鉴权的请求撞 401 时用存下的密码重登一次并重放请求，
/// 重登也失败（密码改了）才清 token、广播通知，要求用户重新登录。
/// generation 代际照抄 Bangumi 的思路：登录 / 登出推进代际，在途请求醒来发现
/// 代际不匹配就自我作废，避免陈旧凭证覆盖新凭证。
public actor MoviePilotAPIClient {

    public static let shared = MoviePilotAPIClient()

    /// token 失效且静默重登失败时发（object 是 NSNumber 包着的 generation，
    /// 供 UI 判断是否仍是当前凭证）。
    public static let authenticationRequiredNotification = Notification.Name(
        "MoviePilotAPIClientAuthenticationRequired")

    private let store: MoviePilotStore
    private let session: URLSession
    /// SSE 流式搜索专用：`timeoutIntervalForResource` 不能按请求覆盖，而站点
    /// 聚合搜索整场可以跑几分钟，普通会话 30s 就会把流掐断。
    private let streamSession: URLSession

    private var authGeneration: UInt64 = 0
    /// 单飞的静默重登：并发请求同时撞 401 时只登一次，其余等同一个 Task。
    private var reloginTask: Task<String, Error>?
    private var reloginGeneration: UInt64 = 0

    public init(
        store: MoviePilotStore = MoviePilotStore(),
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.store = store
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "User-Agent": "OcPlayer/0.1 (MoviePilotKit)",
        ]
        self.session = URLSession(configuration: configuration)

        // 流式会话：请求间空闲 30s 超时（心跳 15s 兜着），整场 5 分钟上限。
        // cookie 存储跟随原配置（默认共享，登录种的 resource cookie 全局可见）。
        let streamConfiguration =
            (sessionConfiguration.copy() as? URLSessionConfiguration) ?? configuration
        streamConfiguration.timeoutIntervalForRequest = 30
        streamConfiguration.timeoutIntervalForResource = 300
        self.streamSession = URLSession(configuration: streamConfiguration)
    }

    // MARK: - 登录态

    public func isAuthenticated() -> Bool {
        store.hasToken
    }

    public func currentGeneration() -> UInt64 {
        authGeneration
    }

    public func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == authGeneration
    }

    /// 登录：读 store 里的地址与账号密码，换 token、返回当前用户。
    /// 成功会推进代际，作废旧 token 与在途请求。
    @discardableResult
    public func login() async throws -> MPUser {
        guard !store.username.isEmpty, !store.password.isEmpty else {
            throw MoviePilotError.notConfigured
        }
        cancelRelogin()
        bumpGeneration()
        let token = try await postLogin(username: store.username, password: store.password)
        store.accessToken = token
        bumpGeneration()
        // 拿新 token 直接取用户信息（不经重登路径——token 就是刚换的）。
        let request = MPRequest(path: "/api/v1/user/current")
        let data = MPEnvelope.unwrap(try await sendOnce(request, token: token))
        do {
            return try Self.decoder.decode(MPUser.self, from: data)
        } catch {
            // 别映射成 badRequest——那是「请求参数有误」，会把解析问题误导成参数问题。
            throw MoviePilotError.generic("登录成功但用户信息解析失败：\(error)")
        }
    }

    /// 当前用户（带鉴权；token 过期走静默重登）。
    @discardableResult
    public func currentUser() async throws -> MPUser {
        let data = MPEnvelope.unwrap(
            try await requestData(MPRequest(path: "/api/v1/user/current")))
        return try Self.decoder.decode(MPUser.self, from: data)
    }

    /// 退出登录：清 token 与密码，作废在途请求。
    @discardableResult
    public func signOut() -> UInt64 {
        cancelRelogin()
        store.clearSession()
        bumpGeneration()
        return authGeneration
    }

    /// 收到 401 通知侧的配合接口：只在代际仍匹配时清 token。
    public func clearSession(ifCurrent expectedGeneration: UInt64) -> UInt64? {
        guard expectedGeneration == authGeneration else { return nil }
        store.accessToken = nil
        bumpGeneration()
        return authGeneration
    }

    // MARK: - 通用请求（阶段二搜索/下载复用）

    public struct MPRequest: Sendable {
        public var path: String
        public var method: String
        public var query: [URLQueryItem]
        /// JSON body（DTO 直接传，编码为 application/json）。
        public var jsonBody: (any Sendable & Encodable)?
        /// form-urlencoded body（登录接口用）。
        public var formBody: [String: String]?
        public var authorized: Bool
        public var timeout: TimeInterval?

        public init(
            path: String,
            method: String = "GET",
            query: [URLQueryItem] = [],
            jsonBody: (any Sendable & Encodable)? = nil,
            formBody: [String: String]? = nil,
            authorized: Bool = true,
            timeout: TimeInterval? = nil
        ) {
            self.path = path
            self.method = method
            self.query = query
            self.jsonBody = jsonBody
            self.formBody = formBody
            self.authorized = authorized
            self.timeout = timeout
        }
    }

    /// 发请求并解码 JSON。带鉴权的请求 401 时静默重登 + 重放一次。
    public func request<T: Decodable>(_ request: MPRequest) async throws -> T {
        let data = try await requestData(request)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// 发请求返回原始 data（非 JSON 响应用）。
    public func requestData(_ request: MPRequest) async throws -> Data {
        if request.authorized {
            guard let token = store.accessToken, !token.isEmpty else {
                throw MoviePilotError.requireLogin
            }
            return try await send(request, token: token)
        } else {
            return try await sendOnce(request, token: nil)
        }
    }

    // MARK: - 内部

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func bumpGeneration() {
        authGeneration &+= 1
    }

    private func cancelRelogin() {
        reloginGeneration &+= 1
        reloginTask?.cancel()
        reloginTask = nil
    }

    /// 登录接口本体（不带 Bearer 头：拿旧 token 撞新登录没有意义）。
    private func postLogin(username: String, password: String) async throws -> String {
        let request = MPRequest(
            path: "/api/v1/login/access-token",
            method: "POST",
            formBody: ["username": username, "password": password],
            authorized: false
        )
        let data = try await sendOnce(request, token: nil)
        do {
            let response = try JSONDecoder().decode(MPTokenResponse.self, from: data)
            guard !response.accessToken.isEmpty else {
                throw MoviePilotError.generic("服务器返回了空 token")
            }
            return response.accessToken
        } catch let error as MoviePilotError {
            throw error
        } catch {
            throw MoviePilotError.badRequest("登录响应解析失败：\(error)")
        }
    }

    /// 带鉴权请求的发送：401（requireLogin）→ 静默重登 → 重放一次。
    private func send(_ request: MPRequest, token: String) async throws -> Data {
        do {
            return try await sendOnce(request, token: token)
        } catch MoviePilotError.requireLogin {
            let newToken = try await silentRelogin()
            return try await sendOnce(request, token: newToken)
        }
    }

    /// 单次发送。4xx/5xx 一律映射成 `MoviePilotError` 抛出（401 → requireLogin）。
    private func sendOnce(_ request: MPRequest, token: String?) async throws -> Data {
        let urlRequest = try makeURLRequest(request, token: token)
        let url = urlRequest.url

        let path = MoviePilotNetworkLog.logPath(for: url)
        MoviePilotNetworkLog.requestStarted(path)
        let start = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            let duration = start.duration(to: .now).timeInterval
            MoviePilotNetworkLog.requestFailed(path, error: error, duration: duration)
            throw MoviePilotError(networkError: error)
        } catch {
            let duration = start.duration(to: .now).timeInterval
            MoviePilotNetworkLog.requestFailed(path, error: error, duration: duration)
            throw MoviePilotError(request: "\(error)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoviePilotError.generic("服务器响应异常")
        }
        let duration = start.duration(to: .now).timeInterval

        guard httpResponse.statusCode >= 400 else {
            MoviePilotNetworkLog.requestSucceeded(path, duration: duration)
            return data
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let error = MoviePilotError(
            code: httpResponse.statusCode,
            response: MoviePilotErrorBody.message(from: data) ?? bodyText
        )
        MoviePilotNetworkLog.requestFailed(path, error: error, duration: duration)
        throw error
    }

    /// URL + URLRequest 组装（普通请求与 SSE 流共用）。
    private func makeURLRequest(_ request: MPRequest, token: String?) throws -> URLRequest {
        guard let baseURL = store.baseURL else {
            throw MoviePilotError.notConfigured
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        let prefix = components.path == "/" ? "" : components.path
        components.path = prefix + request.path
        if !request.query.isEmpty {
            components.queryItems = request.query
        }
        guard let url = components.url else {
            throw MoviePilotError.generic("请求地址拼装失败：\(request.path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        if let token {
            urlRequest.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let formBody = request.formBody {
            var bodyComponents = URLComponents()
            bodyComponents.queryItems = formBody.map { URLQueryItem(name: $0.key, value: $0.value) }
            urlRequest.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
            urlRequest.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else if let jsonBody = request.jsonBody {
            urlRequest.httpBody = try JSONEncoder().encode(jsonBody)
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    // MARK: - 静默重登

    /// 401 后用存的密码重登。成功返回新 token（已落库并推进代际——这一步在
    /// 单飞 Task 里做，恰好一次）；密码错误 → 清 token、广播通知、抛 requireLogin；
    /// 网络故障 → 原样抛网络错误，不动 token（可能只是暂时连不上，下次再试）。
    private func silentRelogin() async throws -> String {
        if let existing = reloginTask {
            return try await existing.value
        }
        guard !store.username.isEmpty, !store.password.isEmpty else {
            // 没存密码就没法静默重登（比如退出登录后残留请求）。
            store.accessToken = nil
            throw MoviePilotError.requireLogin
        }

        let generation = authGeneration
        reloginGeneration &+= 1
        let myRelogin = reloginGeneration

        let task = Task<String, Error> {
            let token = try await self.performRelogin()
            guard generation == self.authGeneration else {
                throw MoviePilotError(ignore: "静默重登结果已过期")
            }
            self.store.accessToken = token
            self.bumpGeneration()
            return token
        }
        reloginTask = task
        defer {
            if reloginGeneration == myRelogin {
                reloginTask = nil
            }
        }

        do {
            return try await task.value
        } catch let error as MoviePilotError {
            switch error {
            case .requireLogin, .badRequest:
                // 密码已改 / 账号被停：token 作废，通知 UI 重新登录。
                if generation == authGeneration {
                    store.accessToken = nil
                    await notifyAuthenticationRequired(ifCurrent: generation)
                }
                throw MoviePilotError.requireLogin
            default:
                throw error
            }
        }
    }

    private func performRelogin() async throws -> String {
        try await postLogin(username: store.username, password: store.password)
    }

    private func notifyAuthenticationRequired(ifCurrent generation: UInt64) async {
        guard generation == authGeneration else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.authenticationRequiredNotification,
                object: NSNumber(value: generation)
            )
        }
    }

    // MARK: - SSE 流式搜索

    /// 按标题流式搜站点资源（MP 网页端同款路径）。每个事件回调一次
    /// 「当前累计结果 + 进度」，结束时返回最终列表；边搜边出，不用等全场跑完。
    ///
    /// 鉴权靠登录时种的 `MoviePilot` resource cookie（默认 cookie 存储自动携带），
    /// cookie 过期（30 分钟无 JWT 请求）时 401 → 静默重登刷新 cookie → 重试一次。
    @discardableResult
    public func searchTorrentsByTitleStream(
        keyword: String,
        sites: [Int] = [],
        onUpdate: (@Sendable ([MPTorrent], MPSearchProgress) -> Void)? = nil
    ) async throws -> [MPTorrent] {
        do {
            return try await runStreamSearch(keyword: keyword, sites: sites, onUpdate: onUpdate)
        } catch MoviePilotError.requireLogin {
            // cookie 过期：静默重登会顺带种新 cookie，重放一次。
            _ = try await silentRelogin()
            return try await runStreamSearch(keyword: keyword, sites: sites, onUpdate: onUpdate)
        }
    }

    private func runStreamSearch(
        keyword: String,
        sites: [Int],
        onUpdate: (@Sendable ([MPTorrent], MPSearchProgress) -> Void)?
    ) async throws -> [MPTorrent] {
        var query = [
            URLQueryItem(name: "keyword", value: keyword),
        ]
        // 服务端格式：逗号分隔的站点 id（_parse_site_list）；不传 = 全部站点。
        if !sites.isEmpty {
            query.append(URLQueryItem(
                name: "sites", value: sites.map(String.init).joined(separator: ",")))
        }
        let request = MPRequest(
            path: "/api/v1/search/title/stream",
            query: query,
            authorized: false
        )
        let urlRequest = try makeURLRequest(request, token: nil)
        MoviePilotNetworkLog.requestStarted(MoviePilotNetworkLog.logPath(for: urlRequest.url))

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await streamSession.bytes(for: urlRequest)
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            throw MoviePilotError(networkError: error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoviePilotError.generic("服务器响应异常")
        }
        guard httpResponse.statusCode < 400 else {
            // 流式接口的 401 是 resource cookie 过期，统一按 requireLogin 抛，
            // 由上层走静默重登重试。
            throw MoviePilotError(code: httpResponse.statusCode, response: "SSE 搜索鉴权失败")
        }

        // SSE：一行一个 `data: {json}`（MP 的事件 JSON 不换行），空行分隔事件。
        var torrents: [MPTorrent] = []
        var seen: Set<String> = []
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let progress = MPSearchProgress(
                text: object["text"] as? String,
                finished: object["finished"] as? Int ?? 0,
                total: object["total"] as? Int ?? 0,
                totalItems: object["total_items"] as? Int ?? 0
            )
            // 事件里的每条资源装在 context 下：torrent_info 是数据本体，
            // meta_info 是识别结果（筛选要用），一并收进 MPTorrent。
            let contexts = (object["items"] as? [[String: Any]] ?? [])

            // 任何携带 items 的事件（append / replace / done）都要入列：
            // done 也可能捎带最后一批资源。
            func collect(reset: Bool) {
                if reset {
                    torrents = []
                    seen = []
                }
                for context in contexts {
                    guard let torrentRaw = context["torrent_info"] as? [String: Any] else { continue }
                    let meta = (context["meta_info"] as? [String: Any])?
                        .mapValues(JSONValue.init(any:))
                    let torrent = MPTorrent(
                        raw: torrentRaw.mapValues(JSONValue.init(any:)),
                        meta: meta
                    )
                    if seen.insert(torrent.id).inserted {
                        torrents.append(torrent)
                    }
                }
            }

            switch object["type"] as? String {
            case "append":
                collect(reset: false)
            case "replace":
                collect(reset: true)
            case "error":
                throw MoviePilotError.generic(progress.text ?? "站点搜索失败")
            case "done", "finish", "finished":
                collect(reset: false)
                onUpdate?(torrents, progress)
                MoviePilotNetworkLog.requestSucceeded(
                    "/api/v1/search/title/stream",
                    duration: 0
                )
                return torrents
            default:
                // heartbeat / 纯进度事件。
                break
            }
            onUpdate?(torrents, progress)
        }
        // 服务端关流没发 done（超时截断等）：按已收到的返回。
        return torrents
    }
}

/// 流式搜索的进度快照（服务端事件的进度字段）。
public struct MPSearchProgress: Sendable, Equatable {
    /// 人类可读进度文案，如「正在搜索xxx，已完成 3 / 31 个请求 …」。
    public let text: String?
    public let finished: Int
    public let total: Int
    public let totalItems: Int
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
