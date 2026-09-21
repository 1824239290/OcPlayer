import Foundation

/// Emby 的登录会话：持有指向该服务器的匿名裸传输会话。
///
/// 与 `JellyfinLoginSession` 实现同一条 `ServerLoginSession` 契约，但不碰 SDK ——
/// 探活、账号密码登录、落档案全走 `EmbySession` + 宽松解析。
public final class EmbyLoginSession: ServerLoginSession {
    public let baseURL: URL
    public let serverName: String
    public let serverVersion: String?
    public let serverID: String?

    private let session: EmbySession

    init(baseURL: URL, info: EmbyPublicSystemInfoDTO, session: EmbySession) {
        self.baseURL = baseURL
        self.serverName = info.serverName ?? "Emby"
        self.serverVersion = info.version
        self.serverID = info.id
        self.session = session
    }

    public var kind: ServerKind { .emby }

    /// Emby 没有 Quick Connect 端点 —— UI 据此只显示账号密码表单。
    public var supportsQuickConnect: Bool { false }

    /// Emby 永远不会有事件；返回一个立刻结束的空流，让调用方不必分叉。
    public var quickConnectEvents: AsyncThrowingStream<QuickConnectEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    /// 账号密码登录。响应体走宽松解析（`LoginResult.parse`）：Emby 的 `User`
    /// 对象里带 Jellyfin schema 没有的字段，强类型解码会整包炸。
    ///
    /// 密码错误的 HTTP 状态码 Emby 老版本可能返回 400，这里与 Jellyfin 侧同口径
    /// 归成「账号密码不对」，避免报成莫名的 HTTP 400。
    public func signIn(username: String, password: String) async throws -> LoginResult {
        let body = LoginRequestBody(username: username, password: password)
        do {
            let data = try await session.requestData(
                "/Users/AuthenticateByName",
                method: "POST",
                body: body
            )
            return try LoginResult.parse(data)
        } catch let error as JellyfinError {
            if case .http(400) = error.kind { throw JellyfinError(.unauthorized) }
            throw error
        } catch {
            throw JellyfinError.wrapPreservingCancellation(error)
        }
    }

    /// Emby 没有 Quick Connect，这条路径不该被走到。
    public func signIn(quickConnectSecret: String) async throws -> LoginResult {
        throw JellyfinError(.quickConnectDisabled)
    }

    public func finish(_ result: LoginResult, store: ServerStore) throws -> any MediaServer {
        let profile = makeProfile(userID: result.userID, userName: result.userName)
        store.activate(profile, token: result.token)
        return EmbyServer(
            profile: profile,
            session: EmbySession(baseURL: baseURL, accessToken: result.token, profileID: profile.id)
        )
    }
}
