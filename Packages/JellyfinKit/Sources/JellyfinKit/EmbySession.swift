import Foundation

/// Emby 的裸 HTTP 会话。
///
/// 刻意**不**依赖 `jellyfin-sdk-swift`：Emby 的响应值域超出 SDK 的枚举，
/// 强解会整包炸（见 `MediaServer` 与 `EmbyDTOs` 的文档注释）。这里只做四件事：
/// 拼 URL、注入认证头、校验状态码、解成宽松 DTO。
///
/// token 走 `Authorization` 头，**不进 URL**（也就不会进诊断日志）。
final class EmbySession: @unchecked Sendable {
    /// 请求体编码器（**复用**）。
    ///
    /// 实测每次现建 `JSONEncoder` 多花 **2.08 µs**（5.68 vs 3.60 µs，小的 Codable 体）；
    /// 而 Bangumi 那条路径还在**重试闭包内部**，一次失败就重复构造。
    /// `JSONEncoder` 是类（引用类型），复用没有线程安全问题 —— 它不持有可变状态。
    private static let encoder = JSONEncoder()
    /// 固定地址（匿名探活 / 登录阶段，以及测试）。有 `directory` 时它只作初始值，
    /// 真正生效的地址由决议器给。
    private let fixedBaseURL: URL
    /// 地址决议器：nil = 固定地址（探活 / 登录阶段还没有档案、也没得选）。
    private let directory: ServerEndpointDirectory?

    /// 当前生效地址。请求、图片、播放流地址全部从这里派生 —— 换地址对上层透明。
    var baseURL: URL { directory?.currentURL ?? fixedBaseURL }

    let accessToken: String?

    /// 登录该账号的稳定标识（`ServerProfile.userID`）。只用于**认证头里的 `UserId`**，
    /// 进而决定图片缓存的身份——见 `ClientIdentity.authorizationHeader(scheme:userId:token:)`。
    /// nil = 匿名会话（探活 / 登录阶段）。
    let userID: String?

    /// 已登录档案的 id；nil 表示这是**匿名**会话（探活 / 登录阶段）。
    /// 只有已登录会话的 401 才发 `MediaServerAuthentication` —— 登录接口自身的
    /// 401 是密码错误，发通知会把用户从登录页踢回登录页。
    private let profileID: String?

    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        baseURL: URL,
        accessToken: String?,
        userID: String? = nil,
        profileID: String? = nil,
        sessionConfiguration: URLSessionConfiguration = .default,
        directory: ServerEndpointDirectory? = nil
    ) {
        self.fixedBaseURL = baseURL
        self.directory = directory
        self.accessToken = accessToken
        self.userID = userID
        self.profileID = profileID

        // .default 是进程级共享单例，直接改会影响全 App 的会话；copy 一份再调。
        // request 30s：服务器半死时不干等；resource 300s：字幕 / 图片这类资源留足。
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        // 登录 / 探活阶段的 UA（会话创建时刻的偏好值）；已登录会话的每条请求在
        // `data()` 里按**当时**的偏好重设，设置里改完即时生效。
        // 合并而不是整体赋值：调用方传进来的 sessionConfiguration 可能自带
        // 额外的 httpAdditionalHeaders，直接赋值会静默吃掉它们。
        if let userAgent = ClientIdentity.customUserAgent {
            var additionalHeaders = configuration.httpAdditionalHeaders ?? [:]
            additionalHeaders["User-Agent"] = userAgent
            configuration.httpAdditionalHeaders = additionalHeaders
        }
        self.session = URLSession(configuration: configuration)

        let decoder = JSONDecoder()
        // Emby 的 wire 字段是 PascalCase，首字母降下来即可对上 DTO 属性名。
        decoder.keyDecodingStrategy = .embyFirstLetterLowered
        self.decoder = decoder
    }

    /// Emby 用自己的 `Emby` scheme（Jellyfin 是 `MediaBrowser`）。
    var authorizationHeader: String {
        ClientIdentity.authorizationHeader(scheme: "Emby", userId: userID, token: accessToken)
    }

    /// `timeout` 是**这条请求**的读写空闲上限，覆盖会话默认值。给「尽力而为、
    /// 拿不到也就算了」的补充请求用（如逐剧扫描），免得它们按 30s 的默认上限
    /// 把整条链路拖住。
    func get<T: Decodable>(
        _ path: String,
        query: [(String, String)] = [],
        timeout: TimeInterval? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        try await request(path, method: "GET", query: query, timeout: timeout)
    }

    func post<T: Decodable>(
        _ path: String,
        query: [(String, String)] = [],
        body: (any Encodable)? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        try await request(path, method: "POST", query: query, body: body)
    }

    /// 只关心成功与否、不需要响应体的写操作（标记已看 / 取消已看）。
    @discardableResult
    func postIgnoringBody(_ path: String, query: [(String, String)] = []) async throws -> Data {
        try await data(path, method: "POST", query: query, body: nil)
    }

    @discardableResult
    func deleteIgnoringBody(_ path: String, query: [(String, String)] = []) async throws -> Data {
        try await data(path, method: "DELETE", query: query, body: nil)
    }

    /// 用本层的宽松解码器解一段已经拿到的响应体。
    ///
    /// 调用方自己读了 `Data` 又需要容错解码时用它 —— **不要另建 `JSONDecoder`**：
    /// 本层的解码器带 Emby 的键名策略，裸解码器会把 `Played` 之类解不出来。
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw JellyfinError(.other("Emby 响应解析失败：\(error)"), underlying: error)
        }
    }

    func request<T: Decodable>(
        _ path: String,
        method: String,
        query: [(String, String)] = [],
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let raw = try await requestData(path, method: method, query: query, body: body, timeout: timeout)
        do {
            return try decoder.decode(T.self, from: raw)
        } catch {
            throw JellyfinError(.other("Emby 响应解析失败（\(path)）：\(error)"), underlying: error)
        }
    }

    /// 编码请求体后发出去，返回**原始响应体** —— 登录这类要自己宽松解析的
    /// 场景用（`LoginResult.parse`）。
    func requestData(
        _ path: String,
        method: String,
        query: [(String, String)] = [],
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let payload: Data?
        if let body {
            do {
                payload = try Self.encoder.encode(body)
            } catch {
                throw JellyfinError(.other("Emby 请求体编码失败：\(error)"), underlying: error)
            }
        } else {
            payload = nil
        }
        return try await data(path, method: method, query: query, body: payload, timeout: timeout)
    }

    /// 发请求。**地址决议、换址与退避重试都在这一层**：它是 Emby 侧唯一的发送口，
    /// 浏览 / 详情 / 字幕下载全从这走，上层不必知道「地址刚换过」。
    ///
    /// 重试语义与 `JellyfinServer.send` 对齐（此前 Emby 侧只有换址那一次重试，
    /// 服务器回 502/503 或瞬时断连时用户只能看着转圈到超时）：幂等的浏览类
    /// 请求（GET）按 `browseRetryPolicy` 退避重试，写操作不重试（重放会把一次
    /// 用户操作变成两次）；判据也是同一份（`isIdempotent` / `isRetryable` /
    /// `RetryPolicy`，全在 JellyfinKit 内共享）。
    func data(
        _ path: String,
        method: String,
        query: [(String, String)] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let policy = JellyfinServer.isIdempotent(method)
            ? JellyfinServer.browseRetryPolicy : JellyfinServer.noRetryPolicy
        var lastError: (any Error)?
        for attempt in 1...policy.attempts {
            // 首启 / 网络变化后这里会等一次探活；平时是同步读缓存。
            _ = await directory?.resolvedURL()
            let attemptURL = baseURL
            do {
                return try await send(path, method: method, query: query, body: body, timeout: timeout)
            } catch let failure as JellyfinError {
                // 取消照抛：那是「调用方不要了」，不是可重试的失败。
                if JellyfinError.isCancellation(failure) { throw failure }
                lastError = failure
                // 传输层失败先怀疑「这条地址现在不通」：重新探活，换了地址就在新地址上
                // 立刻再试一次（出门那条路：局域网断了 → Tailscale）。
                // 换址判断必须排在重试闸门之前（同 JellyfinServer.send 的教训：
                // 先过闸门的话 break 会把换址一起吃掉）。
                if failure.isAddressFailure, let directory,
                   attempt < policy.attempts, await directory.reportFailure(of: attemptURL) {
                    NetworkLog.logger.info(
                        "地址不可用，换地址后重试 \(method) \(path)",
                        fields: ["from": .string(attemptURL.absoluteString),
                                 "to": .string(baseURL.absoluteString)])
                    continue
                }
                guard attempt < policy.attempts, JellyfinServer.isRetryable(failure) else { break }
                let delay = policy.backoffNanoseconds(attempt: attempt)
                // 与 Jellyfin 侧同一取舍：重试日志用 .info（默认档只落 info 及以上，
                // debug 进不了诊断包），这是「瞬态失败已自愈」的唯一可见证据。
                NetworkLog.logger.info(
                    "重试 \(method) \(path)（第 \(attempt + 1)/\(policy.attempts) 次）",
                    fields: ["attempt": .integer(Int64(attempt + 1))])
                // 同 JellyfinServer.send：取消照抛，别让退避被 `try?` 吞掉后续打必败请求。
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? JellyfinError(.other("请求失败"))
    }

    /// 单次发送：拼 URL、注入认证头、校验状态码、记日志。
    private func send(
        _ path: String,
        method: String,
        query: [(String, String)],
        body: Data?,
        timeout: TimeInterval?
    ) async throws -> Data {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userAgent = ClientIdentity.customUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JellyfinError(.other("Emby 返回了非 HTTP 响应"))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw JellyfinError.status(http.statusCode)
            }
            NetworkLog.Emby.requestSucceeded(path, duration: Date().timeIntervalSince(start))
            return data
        } catch {
            let wrapped = JellyfinError.wrapPreservingCancellation(error)
            if JellyfinError.isCancellation(wrapped) {
                // 取消不是故障，不记「请求失败」（.error 档会把换季/离页的正常取消
                // 刷成一片红）：info 级留痕供归因，与 Jellyfin 路径同口径（见
                // `JellyfinServer.send` 的取消分支注释）。
                NetworkLog.Emby.logger.info(
                    "请求被取消（任务取消，非故障）\(method) \(path)",
                    fields: ["duration_ms": .integer(Int64(Date().timeIntervalSince(start) * 1000))])
            } else {
                NetworkLog.Emby.requestFailed(path, error: wrapped, duration: Date().timeIntervalSince(start))
            }
            await notifyIfTokenExpired(wrapped)
            throw wrapped
        }
    }

    /// token 失效且包内没有重登兜底：发通知把 UI 拉回重登流程，别让后续请求
    /// 持续裸报 `.unauthorized`。与 Jellyfin 侧同口径（主线程投递）。
    private func notifyIfTokenExpired(_ error: any Error) async {
        guard let profileID,
              let jellyfinError = error as? JellyfinError,
              case .unauthorized = jellyfinError.kind
        else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: MediaServerAuthentication.authenticationRequired,
                object: profileID)
        }
    }

    /// 拼绝对地址。图片 / 播放流地址这类要交给内核或图片加载器的 URL 也走这里，
    /// 保证前缀拼接只有一处实现。
    func absoluteURL(path: String, query: [(String, String)] = []) throws -> URL {
        try url(path: path, query: query)
    }

    /// 拼绝对地址。`baseURL` 可能带子路径（Emby 档案是 `/emby`），
    /// 所以拼在它**后面**而不是覆盖它 —— 一处前缀全链路生效。
    ///
    /// 实现委托 `ServerURLBuilder`：登录页的海报墙要在没有会话时复原同一条 URL
    /// （只为了算缓存键），两处必须逐字节一致。
    private func url(path: String, query: [(String, String)]) throws -> URL {
        guard let url = ServerURLBuilder.url(base: baseURL, path: path, query: query) else {
            throw JellyfinError(.other("Emby 地址拼接失败：\(path)"))
        }
        return url
    }
}
