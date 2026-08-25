import Foundation
import Get

/// Jellyfin 层错误：包一层并给出用户能看懂的话。
/// UI 只需要 `localizedDescription`，具体技术细节留在 `underlying`。
public struct JellyfinError: Error, LocalizedError {
    public enum Kind: Sendable {
        /// URL 填得没法解析。
        case badServerURL
        /// 服务器没响应 / 不是 Jellyfin（`/System/Info/Public` 失败）。
        case serverUnreachable
        /// 401：账号密码错 / token 过期。
        case unauthorized
        /// 403：权限不足 / 账号被禁用。
        case forbidden
        /// Quick Connect：服务器没开（管理员可在控制台关闭）。
        case quickConnectDisabled
        /// Quick Connect：轮询到上限还没授权。
        case quickConnectTimeout
        /// 其它 HTTP 错误。
        case http(status: Int)
        /// 网络层错误（断网、DNS…）。
        case transport(String)
        /// 解码失败等。
        case other(String)
    }

    public let kind: Kind
    public let underlying: (any Error)?

    public init(_ kind: Kind, underlying: (any Error)? = nil) {
        self.kind = kind
        self.underlying = underlying
    }

    /// 把 SDK / URLSession 抛的任意错误归到上面几类。
    /// 注意顺序：`APIError` / `JellyfinError` 是 enum，**先**判原类型，**最后**才桥接成 `NSError`。
    /// 反过来（先 `as NSError`）会让 enum 被桥接掉，`as? APIError` 永远失败，
    /// 401/404 等 HTTP 错误全部漏进 `.other`/transport，登录报错和 Quick Connect 提示都错乱。
    public static func wrap(_ error: any Error) -> JellyfinError {
        if let apiError = error as? APIError {
            return wrapAPI(apiError)
        }
        if let jellyfinError = error as? JellyfinError {
            return jellyfinError
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return wrapTransport(ns)
        }
        return JellyfinError(.other(ns.localizedDescription), underlying: error)
    }

    /// 连不上（DNS / 拒绝连接 / 断网）给出可操作的「检查地址」提示；
    /// 超时、连接中断等其它传输错误带具体细节，方便区分「地址写错」和「网络抽风」。
    private static func wrapTransport(_ ns: NSError) -> JellyfinError {
        switch ns.code {
        case NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet:
            JellyfinError(.serverUnreachable, underlying: ns)
        default:
            JellyfinError(.transport(ns.localizedDescription), underlying: ns)
        }
    }

    private static func wrapAPI(_ error: APIError) -> JellyfinError {
        switch error {
        case let .unacceptableStatusCode(status):
            switch status {
            case 401: JellyfinError(.unauthorized, underlying: error)
            case 403: JellyfinError(.forbidden, underlying: error)
            default: JellyfinError(.http(status: status), underlying: error)
            }
        }
    }

    public var errorDescription: String? {
        switch kind {
        case .badServerURL:
            "服务器地址看起来不对，试试「http://192.168.1.10:8096」这样的。"
        case .serverUnreachable:
            "连不上服务器：确认地址没打错、这台机器能访问到它。"
        case .unauthorized:
            "认证失败：密码不对，或登录已过期需要重新登录。"
        case .forbidden:
            "访问被拒绝：账号权限不足或已被管理员禁用。"
        case .quickConnectDisabled:
            "这台服务器没有开启 Quick Connect（管理员可在 控制台 → 登录 里打开），请用账号密码登录。"
        case .quickConnectTimeout:
            "等了很久都没确认：请重新发起 Quick Connect。"
        case .http(let status):
            "服务器返回了 HTTP \(status)。"
        case .transport(let text):
            "网络错误：\(text)"
        case .other(let text):
            text
        }
    }
}
