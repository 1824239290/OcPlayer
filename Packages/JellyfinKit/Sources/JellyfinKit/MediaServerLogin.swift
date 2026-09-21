import CoreModel
import Foundation
import JellyfinAPI

/// 登录成功的产出（对 SDK `AuthenticationResult` 的收口：App 层不 import JellyfinAPI）。
public struct LoginResult: Sendable {
    public let token: String
    public let userID: String
    public let userName: String?

    /// 宽松解码路径（`parse`）与 SDK 路径（`init(_:)`）都汇到这里。
    public init(token: String, userID: String, userName: String?) {
        self.token = token
        self.userID = userID
        self.userName = userName
    }

    init(_ result: AuthenticationResult) throws {
        guard let token = result.accessToken, let userID = result.user?.id else {
            throw JellyfinError(.unauthorized)
        }
        self.init(token: token, userID: userID, userName: result.user?.name)
    }

    /// 从登录响应原始 JSON 抽必要字段；多余字段与类型波动全部忽略。
    ///
    /// **两家的顶层与 `User` 对象字段名一致**（`AccessToken` / `User.Id`），所以
    /// 这条宽松解析两边共用：只做「拿到什么算什么」的容错，类型不对的字段当 nil
    /// 处理，不炸整包。Emby 的 `User` 对象里带 Jellyfin schema 没有的字段
    /// （如 UserPolicy 变体），强类型解码会整包炸出 "The data couldn't be read
    /// because it is missing"，而登录只需要这三样。
    public static func parse(_ data: Data) throws -> LoginResult {
        let object = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw JellyfinError(.unauthorized)
        }
        guard let token = nonEmptyString(dict["AccessToken"]) else {
            // 没带 token 的「成功」响应等于没登录成。
            throw JellyfinError(.unauthorized)
        }
        let user = dict["User"] as? [String: Any]
        guard let userID = user.flatMap({ nonEmptyString($0["Id"]) }) else {
            throw JellyfinError(.unauthorized)
        }
        return LoginResult(token: token, userID: userID, userName: user?["Name"] as? String)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Quick Connect 事件（对 SDK `QuickConnect.Event` 的收口：App 层不必 import
/// JellyfinAPI，也不该知道这个类型来自哪家 SDK）。
public enum QuickConnectEvent: Equatable, Sendable {
    /// 正在轮询，展示这个配对码。
    case polling(String)
    /// 用户在手机上确认了，用这个 secret 换 token。
    case authenticated(String)
}

/// `startLogin` 之后、拿到 token 之前的中间态。
///
/// 按服务器产品分两个实现：Jellyfin 走 SDK 客户端（Quick Connect 是它的实现），
/// Emby 走裸传输。App 只认这个协议 —— 除 `quickConnectEvents` 外不接触任何一家的
/// wire 类型。
///
/// `AnyObject` 约束是必须的：App 用 `===` 判定「这个回调还属于当前登录会话吗」。
public protocol ServerLoginSession: AnyObject, Sendable {
    var baseURL: URL { get }
    var serverName: String { get }
    var serverVersion: String? { get }
    /// 探活拿到的服务器 ID；缺失时由 baseURL 兜底。
    var serverID: String? { get }
    var kind: ServerKind { get }

    /// Quick Connect 是 Jellyfin 自己的实现，Emby 没有这个端点；
    /// UI 与登录流程按这个开关隐藏 / 跳过 QC。
    var supportsQuickConnect: Bool { get }

    /// Quick Connect 事件流（内置轮询，取消流即取消轮询）。
    /// 只在 `supportsQuickConnect` 为真时有意义。
    var quickConnectEvents: AsyncThrowingStream<QuickConnectEvent, Error> { get }

    /// 账号密码登录。
    func signIn(username: String, password: String) async throws -> LoginResult
    /// Quick Connect：消费 `quickConnectEvents` 的 `.authenticated(secret:)` 后调这里。
    func signIn(quickConnectSecret: String) async throws -> LoginResult

    /// 登录成功 → 落档案 + token，返回可用的服务器会话。
    func finish(_ result: LoginResult, store: ServerStore) throws -> any MediaServer
}

extension ServerLoginSession {
    /// 档案 id = `serverID:userID`，同一服务器换账号 = 不同 profile。
    func makeProfile(userID: String, userName: String?) -> ServerProfile {
        let resolvedServerID = serverID ?? baseURL.host(percentEncoded: false) ?? baseURL.absoluteString
        return ServerProfile(
            id: "\(resolvedServerID):\(userID)",
            serverName: serverName,
            baseURL: baseURL,
            userID: userID,
            userName: userName,
            serverVersion: serverVersion,
            kind: kind
        )
    }
}

/// 登录流程的入口：探活定产品，再返回对应产品的登录会话。
public enum MediaServerLogin {

    /// 校验地址并创建登录会话。`urlString` 允许「192.168.1.10:8096」这种不带
    /// scheme 的写法。`sessionConfiguration` 是测试注入口（塞 URLProtocol mock），
    /// 业务代码不用传。
    public static func start(
        urlString rawURL: String,
        preferredScheme: ServerScheme? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> any ServerLoginSession {
        let url = try normalizeServerURL(rawURL, preferredScheme: preferredScheme)

        // 探活走**裸传输**而不是 SDK：`/System/Info/Public` 两家同形且响应只有
        // 四个字段，宽松 DTO 足够 —— 这样 Emby 的整条登录链路都不碰 SDK，
        // 也不受 SDK 强类型枚举的约束。
        let probe = EmbySession(baseURL: url, accessToken: nil, sessionConfiguration: sessionConfiguration)
        let info: EmbyPublicSystemInfoDTO
        do {
            info = try await probe.get("/System/Info/Public", as: EmbyPublicSystemInfoDTO.self)
        } catch {
            throw JellyfinError.wrapPreservingCancellation(error)
        }

        switch detectKind(productName: info.productName, version: info.version) {
        case .emby:
            // Emby 的 API 固定挂在 `/emby` 前缀下（Jellyfin 在根路径）。探活先用
            // 原地址（Emby 对无前缀的 `/System/Info/Public` 同样响应），识别出
            // Emby 后会话与落盘的 baseURL 都切到带 `/emby` 的地址。
            let resolved = embyAPIBaseURL(from: url)
            return EmbyLoginSession(
                baseURL: resolved,
                info: info,
                session: EmbySession(
                    baseURL: resolved,
                    accessToken: nil,
                    sessionConfiguration: sessionConfiguration
                )
            )
        case .jellyfin:
            return JellyfinLoginSession(
                baseURL: url,
                info: info,
                client: JellyfinServer.makeClient(
                    baseURL: url,
                    token: nil,
                    sessionConfiguration: sessionConfiguration
                )
            )
        }
    }

    /// 从探活结果判服务器类型。
    ///
    /// `ProductName` 最可靠：Emby 报 "Emby Server"、Jellyfin 报 "Jellyfin Server"。
    /// 没有 ProductName 时看主版本 —— Emby 是 4.x，Jellyfin 是 10.x。
    public static func detectKind(productName: String?, version: String?) -> ServerKind {
        if let product = productName?.lowercased() {
            if product.contains("jellyfin") { return .jellyfin }
            if product.contains("emby") { return .emby }
        }
        if let version, version.hasPrefix("4.") { return .emby }
        return .jellyfin
    }

    /// 给 Emby 地址追加 `/emby` API 前缀；已含该前缀则仅归一掉尾斜杠后返回。
    public static func embyAPIBaseURL(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if !path.lowercased().hasSuffix("/emby") {
            path += "/emby"
        }
        components?.path = path
        return components?.url ?? url
    }

    /// 「host:port」→「scheme://host:port/」(去尾斜杠),统一成确定性的 scheme。
    /// 优先级：**用户手写的 `http(s)://` 前缀 > `preferredScheme` > 默认 http**。
    public static func normalizeServerURL(
        _ raw: String,
        preferredScheme: ServerScheme? = nil
    ) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JellyfinError(.badServerURL) }
        if text.range(of: "://") == nil {
            // 没手写前缀才用 preferredScheme;都没有回退 http(局域网部署为主)。
            text = (preferredScheme?.schemeString ?? "http") + "://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host(percentEncoded: false), !host.isEmpty,
              url.scheme == "http" || url.scheme == "https"
        else { throw JellyfinError(.badServerURL) }
        return url
    }
}
