import Foundation
import JellyfinKit

/// 缓存租户 = 一台服务器上的一个用户。
///
/// **用 `ServerProfile.id`（`serverID:userID`）而不是 `baseURL`**：一台服务器可以有
/// 多条地址（局域网 / Tailscale / 反代）且会自动择优换址（`ServerEndpointDirectory`），
/// 拿 URL 当键会把同一台服务器按地址分裂成好几份缓存——换一次网络，首页就"空"了。
///
/// 换服务器 / 换用户 = 不同租户，互不可见（同一台服务器上换账号也要隔离：
/// 各自的观看进度不同）。
public struct TenantID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 从服务器档案派生。id 为空（异常档案）时退回 `kind:userID`，
    /// 保证仍是一个稳定、可用的键，而不是所有档案挤进同一个空串租户。
    public init(profile: ServerProfile) {
        let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            self.rawValue = "\(profile.kind.rawValue):\(profile.userID)"
        } else {
            self.rawValue = id
        }
    }

    public var description: String { rawValue }
}
