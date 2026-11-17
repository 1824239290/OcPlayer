import Foundation
import OcPlayerCore

/// Anonymous login transport. Credential storage and UI session identity stay
/// with the platform; password exchange and Quick Connect polling run in Core.
final class RustServerLogin: @unchecked Sendable {
    private let core: OcpCoreClient

    init?(configuration: URLSessionConfiguration) {
        guard OcpCoreFeature.isEnabled, OcpCoreFeature.supportsNativeTransport(configuration),
              let core = try? OcpCoreClient() else { return nil }
        self.core = core
    }

    private func call(_ method: String, baseURL: URL, kind: ServerKind,
                      arguments: [String: Any] = [:]) async throws -> OcpResponse {
        var profile: [String: Any] = [
            "id": "login", "kind": kind.rawValue, "baseURL": baseURL.absoluteString,
            "authorizationHeader": ClientIdentity.authorizationHeader(scheme: kind == .emby ? "Emby" : "MediaBrowser"),
        ]
        if let agent = ClientIdentity.customUserAgent { profile["userAgent"] = agent }
        var values = arguments
        values["profile"] = profile
        let payload = try JSONSerialization.data(withJSONObject: values)
        let response = try await core.callAsync(method, argumentsJSON: String(decoding: payload, as: UTF8.self))
        guard response.ok else {
            let underlying = NSError(domain: "OcPlayerCore.ServerLogin", code: Int(response.code),
                                     userInfo: [NSLocalizedDescriptionKey: response.message])
            switch response.code {
            case 1003: throw CancellationError()
            case 1002: throw JellyfinError(.badServerURL, underlying: underlying)
            case 2001: throw JellyfinError(.unauthorized, underlying: underlying)
            case 2003: throw JellyfinError(.forbidden, underlying: underlying)
            case 2401: throw JellyfinError(.quickConnectDisabled, underlying: underlying)
            case 2402: throw JellyfinError(.quickConnectTimeout, underlying: underlying)
            case 1522: throw JellyfinError(.serverUnreachable, underlying: underlying)
            case 1521, 1523: throw JellyfinError(.transport(response.message), underlying: underlying)
            case 1700...2199: throw JellyfinError.status(Int(response.code) - 1600, underlying: underlying)
            default: throw JellyfinError(.other(response.message), underlying: underlying)
            }
        }
        return response
    }

    func probe(baseURL: URL) async throws -> EmbyPublicSystemInfoDTO {
        try await call("server.probe", baseURL: baseURL, kind: .jellyfin).data.decode()
    }

    private struct Credentials: Decodable {
        let token: String
        let userId: String
        let userName: String?
        let primaryImageTag: String?
        var result: LoginResult { .init(token: token, userID: userId, userName: userName, primaryImageTag: primaryImageTag) }
    }

    func signIn(baseURL: URL, kind: ServerKind, username: String, password: String) async throws -> LoginResult {
        try await call("server.login", baseURL: baseURL, kind: kind,
                       arguments: ["username": username, "password": password]).data.decode(Credentials.self).result
    }

    func signIn(baseURL: URL, secret: String) async throws -> LoginResult {
        try await call("server.loginQuickConnect", baseURL: baseURL, kind: .jellyfin,
                       arguments: ["secret": secret]).data.decode(Credentials.self).result
    }

    private struct Pairing: Decodable { let code: String?; let secret: String? }

    func quickConnectEvents(baseURL: URL, pollInterval: Double = 3, maxPolls: Int = 60,
                            failureTolerance: Int = 5) -> AsyncThrowingStream<QuickConnectEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pairing = try await call("server.quickConnect.initiate", baseURL: baseURL, kind: .jellyfin).data.decode(Pairing.self)
                    guard let code = pairing.code, let secret = pairing.secret else { throw JellyfinError(.other("Quick Connect 响应缺少配对信息")) }
                    try Task.checkCancellation()
                    continuation.yield(.polling(code))
                    let state = try await call("server.quickConnect.wait", baseURL: baseURL, kind: .jellyfin,
                                               arguments: ["secret": secret, "pollInterval": pollInterval,
                                                           "maxPolls": maxPolls, "failureTolerance": failureTolerance]).data.decode(Pairing.self)
                    try Task.checkCancellation()
                    guard let authorized = state.secret else { throw JellyfinError(.other("Quick Connect 响应缺少授权信息")) }
                    continuation.yield(.authenticated(authorized))
                    continuation.finish()
                } catch where JellyfinError.isCancellation(error) { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
