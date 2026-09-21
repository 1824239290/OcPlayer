import Foundation
import Get
import JellyfinAPI

/// Jellyfin 的登录会话：持有指向该服务器的匿名 SDK 客户端，
/// Quick Connect 和账号密码都从它走。
public final class JellyfinLoginSession: ServerLoginSession {
    public let baseURL: URL
    public let serverName: String
    public let serverVersion: String?
    public let serverID: String?

    let client: JellyfinClient

    init(baseURL: URL, info: EmbyPublicSystemInfoDTO, client: JellyfinClient) {
        self.baseURL = baseURL
        self.serverName = info.serverName ?? "Jellyfin"
        self.serverVersion = info.version
        self.serverID = info.id
        self.client = client
    }

    public var kind: ServerKind { .jellyfin }

    /// Quick Connect 是 Jellyfin 独有的实现，这里恒为真。
    public var supportsQuickConnect: Bool { true }

    /// Quick Connect 事件流（内置轮询，取消流即取消轮询）。
    public var quickConnectEvents: AsyncThrowingStream<QuickConnectEvent, Error> {
        AsyncThrowingStream { continuation in
            let upstream = client.quickConnect.connect(poll: 3, max: 60)
            let task = Task {
                do {
                    for try await event in upstream {
                        // SDK 事件 → 中立事件，SDK 类型到此为止。
                        switch event {
                        case let .polling(code): continuation.yield(.polling(code))
                        case let .authenticated(secret): continuation.yield(.authenticated(secret))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if case let APIError.unacceptableStatusCode(status) = error, status == 404 {
                        continuation.finish(throwing: JellyfinError(.quickConnectDisabled, underlying: error))
                    } else if let jellyfinError = error as? JellyfinError, case .http(404) = jellyfinError.kind {
                        continuation.finish(throwing: JellyfinError(.quickConnectDisabled, underlying: jellyfinError.underlying ?? error))
                    } else {
                        continuation.finish(throwing: JellyfinError.wrapPreservingCancellation(error))
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 账号密码登录。
    ///
    /// 密码错误的 HTTP 状态码 Jellyfin 是 401/403，Emby 老版本可能是 400；
    /// 登录场景下把 400 也归成「账号密码不对」的提示，避免报成莫名的 HTTP 400。
    ///
    /// **响应体走宽松解码**（`LoginResult.parse`），不复用 SDK 的
    /// `AuthenticationResult`：登录只需要 AccessToken / User.Id / User.Name 三样。
    public func signIn(username: String, password: String) async throws -> LoginResult {
        do {
            let request = Request<Data>(
                path: "/Users/AuthenticateByName",
                method: "POST",
                body: LoginRequestBody(username: username, password: password),
                id: "AuthenticateUserByName"
            )
            let data = try await client.send(request).value
            return try LoginResult.parse(data)
        } catch let error as JellyfinError {
            throw error
        } catch APIError.unacceptableStatusCode(400) {
            throw JellyfinError(.unauthorized)
        } catch {
            throw JellyfinError.wrapPreservingCancellation(error)
        }
    }

    public func signIn(quickConnectSecret: String) async throws -> LoginResult {
        do {
            return try LoginResult(await client.signIn(quickConnectSecret: quickConnectSecret))
        } catch let error as JellyfinError {
            throw error
        } catch {
            throw JellyfinError.wrapPreservingCancellation(error)
        }
    }

    public func finish(_ result: LoginResult, store: ServerStore) throws -> any MediaServer {
        let profile = makeProfile(userID: result.userID, userName: result.userName)
        store.activate(profile, token: result.token)
        return JellyfinServer(
            profile: profile,
            client: JellyfinServer.makeClient(baseURL: baseURL, token: result.token)
        )
    }
}

/// 登录请求体。Jellyfin/Emby 的约定字段名就是 `Username` / `Pw`。
struct LoginRequestBody: Encodable {
    let username: String
    let password: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .pw)
    }

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}
