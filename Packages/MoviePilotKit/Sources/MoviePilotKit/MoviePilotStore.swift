import DiagnosticsKit
import Foundation

/// MoviePilot 服务器与账号设置的本地存取。
///
/// ## 存哪儿
///
/// - **非机密**（服务器地址、用户名、"记住密码"开关）：UserDefaults。
/// - **机密**（访问令牌、以及用户显式选择记住的密码）：`CredentialFileStore`
///   —— 排除备份的文件，不随 iCloud / iTunes 备份离开设备。
///
/// 不用 Keychain：本包 ad-hoc 签名，每次构建 cdhash 都变，会带来开发期授权弹框、
/// CI 无人应答、以及重签名后凭据读不出来三个问题。详见 `CredentialFileStore`。
///
/// ## 密码默认不落盘
///
/// `rememberPassword` 默认 **false**：密码只保留在本次运行的**内存**里
/// （`sessionPassword`），够支撑「JWT 过期后静默重登」在当前会话内生效。
/// 重启之后内存值没了，若用户没打开开关，401 会走既有的 `requireLogin` 路径提示
/// 重新登录 —— 代价是 MoviePilot 的 JWT 有效期 8 天且没有刷新端点，最多每 8 天
/// 需要重新输一次密码。
///
/// 这么取舍的原因：密码是这一堆凭据里**唯一不可更换**的（token 失效能重登，
/// 密码泄露通常要连带改别处），而它此前是明文躺在 `UserDefaults` 里的。
///
/// 地址以原始字符串保存（设置页可存中间态），读取时再规范化；
/// 与弹幕网关不同，这里**允许 http**——MoviePilot 极常见于局域网 `http://IP:端口`
/// 部署，App 已开 `NSAllowsLocalNetworking` 放行本地明文。
///
/// 测试可注入 `UserDefaults`（suiteName 隔离）与 `credentialsDirectory`（临时目录）。
public final class MoviePilotStore: @unchecked Sendable {

    /// 全局唯一实例：协调器与 APIClient 共用同一份 store（此前两边各 `MoviePilotStore()`，
    /// 两个实例只靠同一份 UserDefaults 碰巧同步——收敛成单一实例，消除双写时序差）。
    public static let shared = MoviePilotStore()

    private let defaults: UserDefaults
    private let credentials: CredentialFileStore
    private let lock = NSLock()

    /// 本次运行内的密码。
    ///
    /// 即使没打开「记住密码」也要留住它：用户刚在设置页输完密码并登录成功，
    /// 8 天后 JWT 过期时（同一进程还活着）仍应能静默重登。进程重启后自然消失。
    private var sessionPassword: String?

    private static let serverKey = "dev.jumusu.ocplayer.moviepilot.serverURL"
    private static let usernameKey = "dev.jumusu.ocplayer.moviepilot.username"
    /// 「记住密码」开关（非机密，留在 UserDefaults）。默认 **关**。
    public static let rememberPasswordKey = "dev.jumusu.ocplayer.moviepilot.rememberPassword"
    /// 旧键：老版本把密码明文放在 UserDefaults。**只删不迁**——见类型注释。
    private static let legacyPasswordKey = "dev.jumusu.ocplayer.moviepilot.password"
    /// 旧键：老版本把访问令牌放在 UserDefaults。迁移到凭据文件。
    private static let legacyTokenKey = "dev.jumusu.ocplayer.moviepilot.accessToken"
    /// 凭据文件内的键名。
    private static let passwordKey = "moviepilot.password"
    private static let tokenKey = "moviepilot.token"

    public init(defaults: UserDefaults = .standard, credentialsDirectory: URL? = nil) {
        self.defaults = defaults
        // 生产用全局单例（多个域包共用一个文件）；测试传临时目录拿到隔离实例。
        self.credentials = credentialsDirectory.map { CredentialFileStore(directory: $0) } ?? .shared

        // 一次性清理：老版本的明文密码**不迁移**（默认关），直接删掉。
        // 它已经在 UserDefaults/备份里躺过，留着只是让暴露继续。
        if !defaults.bool(forKey: Self.rememberPasswordKey) {
            defaults.removeObject(forKey: Self.legacyPasswordKey)
        }
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

    /// 是否记住密码（跨启动）。默认关。
    ///
    /// 关闭时立即把已落盘的密码删掉——否则「开关关了但密码还在文件里」，
    /// 与开关的语义不符。
    public var rememberPassword: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.bool(forKey: Self.rememberPasswordKey)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue, forKey: Self.rememberPasswordKey)
            if !newValue {
                credentials.removeValue(forKey: Self.passwordKey)
            } else if let sessionPassword, !sessionPassword.isEmpty {
                // 打开开关时把当前会话已输入的密码落盘，省得用户重输一遍。
                credentials.setString(sessionPassword, forKey: Self.passwordKey)
            }
        }
    }

    /// 密码，仅用于 401 后静默重登。
    ///
    /// - 取值顺序：本次会话内存值 → 凭据文件（仅当「记住密码」打开）。
    /// - 原样存取、**不做 trim**：含首尾空格的密码被 trim 后登录永远失败且无提示
    ///   （用户名/地址可以 trim，密码不是标识符）。判空用原始值。
    public var password: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let sessionPassword { return sessionPassword }
            guard defaults.bool(forKey: Self.rememberPasswordKey) else { return "" }
            return credentials.string(forKey: Self.passwordKey) ?? ""
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            sessionPassword = newValue.isEmpty ? nil : newValue
            if newValue.isEmpty {
                credentials.removeValue(forKey: Self.passwordKey)
            } else if defaults.bool(forKey: Self.rememberPasswordKey) {
                credentials.setString(newValue, forKey: Self.passwordKey)
            } else {
                // 没打开开关：确保文件里没有残留（用户可能刚把开关关掉）。
                credentials.removeValue(forKey: Self.passwordKey)
            }
        }
    }

    public var accessToken: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let token = credentials.string(forKey: Self.tokenKey) { return token }
            // 迁移：老版本的令牌在 UserDefaults。搬到文件并删旧键，
            // 使令牌从下一次备份起不再出现（已进过备份的历史无法追回）。
            guard let legacy = defaults.string(forKey: Self.legacyTokenKey) else { return nil }
            credentials.setString(legacy, forKey: Self.tokenKey)
            defaults.removeObject(forKey: Self.legacyTokenKey)
            return legacy
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue, !newValue.isEmpty {
                credentials.setString(newValue, forKey: Self.tokenKey)
            } else {
                credentials.removeValue(forKey: Self.tokenKey)
            }
            defaults.removeObject(forKey: Self.legacyTokenKey)
        }
    }

    // MARK: - 派生

    /// 规范化后的服务器根地址；未填或非法时 nil。
    public var baseURL: URL? {
        Self.normalizedURL(from: serverURLString ?? "")
    }

    /// 地址有效（http/https origin）且账号可用。
    ///
    /// 密码**不是**必需项：没打开「记住密码」时，重启后密码是空的，但令牌可能仍有效
    /// （JWT 8 天）。此时集成显然是配置好的——若这里要求密码非空，
    /// `MoviePilotHomeView` 会对着一个能正常用的账号显示「未配置」空态。
    public var isConfigured: Bool {
        baseURL != nil && !username.isEmpty && (!password.isEmpty || hasToken)
    }

    /// 本地有 token（可能已过期，过期靠 401 触发静默重登）。
    public var hasToken: Bool {
        !(accessToken ?? "").isEmpty
    }

    // MARK: - 复合操作

    /// 设置页保存新凭据：旧 token 必然失效，一并清掉。
    ///
    /// 密码原样写入（不 trim，见 `password`）；地址与用户名仍 trim。
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
        setPasswordUnlocked(password)
        credentials.removeValue(forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.legacyTokenKey)
    }

    /// 密码写入的唯一实现（**必须在 `lock` 内调用**）。
    private func setPasswordUnlocked(_ value: String) {
        sessionPassword = value.isEmpty ? nil : value
        if value.isEmpty || !defaults.bool(forKey: Self.rememberPasswordKey) {
            credentials.removeValue(forKey: Self.passwordKey)
        } else {
            credentials.setString(value, forKey: Self.passwordKey)
        }
    }

    // MARK: - 凭据快照

    /// 四键原值的快照（`nil` = 该键不存在），用于「先落盘验证、失败回滚」。
    /// 原样存取：地址与 token 保留「键不存在」语义，密码不做 trim。
    public struct CredentialSnapshot: Sendable, Equatable {
        public let serverURLString: String?
        public let username: String
        public let password: String
        public let accessToken: String?

        public init(serverURLString: String?, username: String, password: String, accessToken: String?) {
            self.serverURLString = serverURLString
            self.username = username
            self.password = password
            self.accessToken = accessToken
        }
    }

    /// 读取当前凭据快照（持锁一次性取四键，避免中间态）。
    public func credentialSnapshot() -> CredentialSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CredentialSnapshot(
            serverURLString: defaults.string(forKey: Self.serverKey),
            username: defaults.string(forKey: Self.usernameKey) ?? "",
            password: passwordUnlocked(),
            accessToken: accessTokenUnlocked()
        )
    }

    /// 按快照回滚四键：`nil` / 空串删键，其余原样写回（不 trim）。
    public func restore(_ snapshot: CredentialSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        if let server = snapshot.serverURLString, !server.isEmpty {
            defaults.set(server, forKey: Self.serverKey)
        } else {
            defaults.removeObject(forKey: Self.serverKey)
        }
        if snapshot.username.isEmpty {
            defaults.removeObject(forKey: Self.usernameKey)
        } else {
            defaults.set(snapshot.username, forKey: Self.usernameKey)
        }
        setPasswordUnlocked(snapshot.password)
        if let token = snapshot.accessToken, !token.isEmpty {
            credentials.setString(token, forKey: Self.tokenKey)
        } else {
            credentials.removeValue(forKey: Self.tokenKey)
        }
        defaults.removeObject(forKey: Self.legacyTokenKey)
    }

    /// 退出登录：清 token 和密码，保留地址与用户名方便下次登录。
    ///
    /// 密码连**本次会话的内存副本**一起清（`sessionPassword = nil`）：
    /// 「退出登录」的语义是交还凭据，留一份内存副本与它矛盾。
    public func clearSession() {
        lock.lock()
        defer { lock.unlock() }
        sessionPassword = nil
        credentials.removeValue(forKey: Self.passwordKey)
        credentials.removeValue(forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.legacyPasswordKey)
        defaults.removeObject(forKey: Self.legacyTokenKey)
    }

    /// 全部清空（卸载式清理）。
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        sessionPassword = nil
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.legacyPasswordKey)
        defaults.removeObject(forKey: Self.legacyTokenKey)
        credentials.removeValue(forKey: Self.passwordKey)
        credentials.removeValue(forKey: Self.tokenKey)
    }

    // MARK: - 锁内读取（供快照用）

    /// **必须在 `lock` 内调用**。
    private func passwordUnlocked() -> String {
        if let sessionPassword { return sessionPassword }
        guard defaults.bool(forKey: Self.rememberPasswordKey) else { return "" }
        return credentials.string(forKey: Self.passwordKey) ?? ""
    }

    /// **必须在 `lock` 内调用**（含旧键迁移）。
    private func accessTokenUnlocked() -> String? {
        if let token = credentials.string(forKey: Self.tokenKey) { return token }
        guard let legacy = defaults.string(forKey: Self.legacyTokenKey) else { return nil }
        credentials.setString(legacy, forKey: Self.tokenKey)
        defaults.removeObject(forKey: Self.legacyTokenKey)
        return legacy
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
