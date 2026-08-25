import Foundation

/// MoviePilot 服务器与账号设置的本地存取。
///
/// 地址 / 用户名 / 密码 / token 全部存 UserDefaults（项目统一不用 Keychain，
/// 见 CLAUDE.md「安全约束」；自用 App 的既有取舍）。密码用于 token 过期后
/// 静默重登（MoviePilot 的 JWT 有效期 8 天且没有刷新端点）。
///
/// 地址以原始字符串保存（设置页可存中间态），读取时再规范化；
/// 与弹幕网关不同，这里**允许 http**——MoviePilot 极常见于局域网 `http://IP:端口`
/// 部署，App 已开 `NSAllowsLocalNetworking` 放行本地明文。
///
/// 测试可注入 `UserDefaults`（suiteName 隔离）。
public final class MoviePilotStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let lock = NSLock()

    private static let serverKey = "dev.jumusu.ocplayer.moviepilot.serverURL"
    private static let usernameKey = "dev.jumusu.ocplayer.moviepilot.username"
    private static let passwordKey = "dev.jumusu.ocplayer.moviepilot.password"
    private static let tokenKey = "dev.jumusu.ocplayer.moviepilot.accessToken"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 原始存取

    /// 设置页直接绑定的原始地址字符串。nil = 从未填写；空串清空。
    public var serverURLString: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.string(forKey: Self.serverKey)
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lock.lock()
            defer { lock.unlock() }
            if value.isEmpty {
                defaults.removeObject(forKey: Self.serverKey)
            } else {
                defaults.set(value, forKey: Self.serverKey)
            }
        }
    }

    public var username: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.string(forKey: Self.usernameKey) ?? ""
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                defaults.removeObject(forKey: Self.usernameKey)
            } else {
                defaults.set(value, forKey: Self.usernameKey)
            }
        }
    }

    /// 明文密码，仅用于 401 后静默重登。退出登录时清除。
    public var password: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.string(forKey: Self.passwordKey) ?? ""
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                defaults.removeObject(forKey: Self.passwordKey)
            } else {
                defaults.set(value, forKey: Self.passwordKey)
            }
        }
    }

    public var accessToken: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.string(forKey: Self.tokenKey)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Self.tokenKey)
            } else {
                defaults.removeObject(forKey: Self.tokenKey)
            }
        }
    }

    // MARK: - 派生

    /// 规范化后的服务器根地址；未填或非法时 nil。
    public var baseURL: URL? {
        Self.normalizedURL(from: serverURLString ?? "")
    }

    /// 地址有效（http/https origin）且账号密码齐全。有 token 不要求——
    /// 配好凭据后登录是下一步。
    public var isConfigured: Bool {
        baseURL != nil && !username.isEmpty && !password.isEmpty
    }

    /// 本地有 token（可能已过期，过期靠 401 触发静默重登）。
    public var hasToken: Bool {
        !(accessToken ?? "").isEmpty
    }

    // MARK: - 复合操作

    /// 设置页保存新凭据：旧 token 必然失效，一并清掉。
    public func updateCredentials(serverURLString: String, username: String, password: String) {
        lock.lock()
        defer { lock.unlock() }
        let server = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.isEmpty {
            defaults.removeObject(forKey: Self.serverKey)
        } else {
            defaults.set(server, forKey: Self.serverKey)
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty {
            defaults.removeObject(forKey: Self.usernameKey)
        } else {
            defaults.set(user, forKey: Self.usernameKey)
        }
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass.isEmpty {
            defaults.removeObject(forKey: Self.passwordKey)
        } else {
            defaults.set(pass, forKey: Self.passwordKey)
        }
        defaults.removeObject(forKey: Self.tokenKey)
    }

    /// 退出登录：清 token 和密码，保留地址与用户名方便下次登录。
    public func clearSession() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.passwordKey)
    }

    /// 全部清空（卸载式清理）。
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.passwordKey)
        defaults.removeObject(forKey: Self.tokenKey)
    }

    // MARK: - 地址规范化

    /// 解析 + 规范化：缺 scheme（无 `://`）补 `http://`（局域网部署为主）；
    /// 只接受 http/https origin（无路径、无认证段、无 query / fragment）。
    public static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: URL?
        if trimmed.contains("://") {
            candidate = URL(string: trimmed)
        } else {
            candidate = URL(string: "http://\(trimmed)")
        }
        guard let candidate,
              let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !(candidate.host?.isEmpty ?? true),
              candidate.path.isEmpty || candidate.path == "/",
              candidate.user == nil,
              candidate.password == nil,
              candidate.query == nil,
              candidate.fragment == nil
        else { return nil }
        return candidate
    }
}
