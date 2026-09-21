import Foundation

/// Emby 的裸 HTTP 会话。
///
/// 刻意**不**依赖 `jellyfin-sdk-swift`：Emby 的响应值域超出 SDK 的枚举，
/// 强解会整包炸（见 `MediaServer` 与 `EmbyDTOs` 的文档注释）。这里只做四件事：
/// 拼 URL、注入认证头、校验状态码、解成宽松 DTO。
///
/// token 走 `Authorization` 头，**不进 URL**（也就不会进诊断日志）。
final class EmbySession: @unchecked Sendable {
    let baseURL: URL
    let accessToken: String?

    /// 已登录档案的 id；nil 表示这是**匿名**会话（探活 / 登录阶段）。
    /// 只有已登录会话的 401 才发 `MediaServerAuthentication` —— 登录接口自身的
    /// 401 是密码错误，发通知会把用户从登录页踢回登录页。
    private let profileID: String?

    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        baseURL: URL,
        accessToken: String?,
        profileID: String? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.profileID = profileID

        // .default 是进程级共享单例，直接改会影响全 App 的会话；copy 一份再调。
        // request 30s：服务器半死时不干等；resource 300s：字幕 / 图片这类资源留足。
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)

        let decoder = JSONDecoder()
        // Emby 的 wire 字段是 PascalCase，首字母降下来即可对上 DTO 属性名。
        decoder.keyDecodingStrategy = .embyFirstLetterLowered
        self.decoder = decoder
    }

    /// Emby 用自己的 `Emby` scheme（Jellyfin 是 `MediaBrowser`）。
    var authorizationHeader: String {
        ClientIdentity.authorizationHeader(scheme: "Emby", token: accessToken)
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
                payload = try JSONEncoder().encode(body)
            } catch {
                throw JellyfinError(.other("Emby 请求体编码失败：\(error)"), underlying: error)
            }
        } else {
            payload = nil
        }
        return try await data(path, method: method, query: query, body: payload, timeout: timeout)
    }

    func data(
        _ path: String,
        method: String,
        query: [(String, String)] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            NetworkLog.Emby.requestFailed(path, error: wrapped, duration: Date().timeIntervalSince(start))
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
    private func url(path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinError(.other("Emby 地址拼接失败：\(path)"))
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            // 用数组而不是字典：`includeItemTypes=Movie,Series` 这类同名多值要保序。
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw JellyfinError(.other("Emby 地址拼接失败：\(path)"))
        }
        return url
    }
}
