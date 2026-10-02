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
/// ## UserDefaults 的写入只在主线程上做
///
/// 后台线程写 `UserDefaults` 会与 SwiftUI 的 `@AppStorage` 观察者互锁、把 App 卡死；
/// 本类型所有写入都收在 `mutateDefaults(_:)` 里兜住（那里有完整的锁环说明）。
/// 真值（地址 / 用户名 / 开关）的调用点一律在主线程。
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
            mutateDefaults { $0.removeObject(forKey: Self.legacyPasswordKey) }
        }
    }

    // MARK: - UserDefaults 写入（唯一落点）

    /// 写 `UserDefaults` 的唯一落点：**绝不在后台线程上写**。
    ///
    /// ## 为什么
    ///
    /// `UserDefaults` 的每次写入都会同步发一条变更通知，而 SwiftUI 给 `@AppStorage`
    /// 挂的 `UserDefaultObserver` 是在**发通知的那个线程**上响应它的——响应体里要
    /// `Update.begin()`，即申请 SwiftUI 的 UI 更新锁（`MovableLock`）。主线程渲染时
    /// 正持着那把锁，而同一时刻它完全可能在读本类型的属性、等下面这把 `lock`：
    /// 后台线程「持 `lock` 等 UI 锁」、主线程「持 UI 锁等 `lock`」，互等即永久卡死
    /// （不是慢，不会自己恢复）。
    ///
    /// 这不是推演。2026-10-02「设置 → 退出 MoviePilot」每次必卡，`sample` 实录：
    /// 主线程停在 `SettingsView.body` 读 `serverURLString` 的 `NSLock` 上，后台
    /// `MoviePilotAPIClient.signOut()` 的 actor 线程停在 `clearSession()` 里
    /// `defaults.removeObject` 触发的 `Update.begin()` 上。**删一个不存在的键也发这条
    /// 通知**（当时两个 legacy 键都早已不在），所以它无条件必现。
    ///
    /// 对照：Bangumi 侧踩不到这个坑——`BangumiContext` 是 `@MainActor`，它的 store
    /// 写入天然在主线程；本类型的写入要经过 actor（`MoviePilotAPIClient`），必须在
    /// 这里兜住。改这个方法之前先想清楚上面这条环。
    ///
    /// ## 后台调用怎么办
    ///
    /// 不阻塞、也不丢弃：投到主线程补做（补做时照常持锁，与主线程上的写入口径一致）。
    /// 能从后台走到这里的只有「历史残留键清理」这类没有时效要求的写入；**真值**
    /// （地址 / 用户名 / 密码 / 开关）的调用点都在主线程上（`MoviePilotCoordinator`
    /// 与设置页），从后台写它们不受支持——真需要时请把调用点收进 `@MainActor`。
    private func mutateDefaults(_ body: @escaping @Sendable (UserDefaults) -> Void) {
        if Thread.isMainThread {
            body(defaults)
        } else {
            DispatchQueue.main.async { [self] in
                lock.lock()
                defer { lock.unlock() }
                body(defaults)
            }
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
                mutateDefaults { $0.removeObject(forKey: Self.serverKey) }
            } else {
                mutateDefaults { $0.set(value, forKey: Self.serverKey) }
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
                mutateDefaults { $0.removeObject(forKey: Self.usernameKey) }
            } else {
                mutateDefaults { $0.set(value, forKey: Self.usernameKey) }
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
            mutateDefaults { $0.set(newValue, forKey: Self.rememberPasswordKey) }
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

    /// 本会话内明确作废过令牌（登出 / 换凭据 / 清会话）。
    ///
    /// 旧 UserDefaults 键的删除走 `mutateDefaults`，在后台线程上会被**推迟**到主线程；
    /// 这个窗口里若来一次读，凭证已空而旧键还在，迁移分支就会把刚作废的旧令牌搬回
    /// 凭据文件——等于登出静默失败。这把闩一次性立起、不再复位：此后读路径一律不认
    /// 旧键（真的重新登录会往凭据文件写新令牌，走的是更前面的早返回）。
    private var legacyTokenRevoked = false

    /// 清令牌的唯一实现（**必须在 `lock` 内调用**）：凭据文件 + 旧 UserDefaults 键一起清。
    private func clearTokenUnlocked() {
        legacyTokenRevoked = true
        credentials.removeValue(forKey: Self.tokenKey)
        mutateDefaults { $0.removeObject(forKey: Self.legacyTokenKey) }
    }

    /// 读取当前令牌（**必须在 `lock` 内调用**）：优先凭据文件；旧 UserDefaults 键只在
    /// 本会话没作废过令牌时迁移（见 `legacyTokenRevoked`）。
    private func accessTokenUnlocked() -> String? {
        if let token = credentials.string(forKey: Self.tokenKey) { return token }
        guard !legacyTokenRevoked else { return nil }
        // 迁移：老版本的令牌在 UserDefaults。搬到文件并删旧键，
        // 使令牌从下一次备份起不再出现（已进过备份的历史无法追回）。
        guard let legacy = defaults.string(forKey: Self.legacyTokenKey) else { return nil }
        credentials.setString(legacy, forKey: Self.tokenKey)
        mutateDefaults { $0.removeObject(forKey: Self.legacyTokenKey) }
        return legacy
    }

    public var accessToken: String? {
        get { lock.withLock { accessTokenUnlocked() } }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue, !newValue.isEmpty {
                credentials.setString(newValue, forKey: Self.tokenKey)
                mutateDefaults { $0.removeObject(forKey: Self.legacyTokenKey) }
            } else {
                clearTokenUnlocked()
            }
        }
    }

    // MARK: - 派生

    /// 规范化后的服务器根地址；未填或非法时 nil。
    public var baseURL: URL? {
        Self.normalizedURL(from: serverURLString ?? "")
    }

    /// 地址有效（http/https origin）且用户名非空——**与凭据是否可用无关**。
    ///
    /// 和 `isConfigured` 的区别是「这台服务器配过账号」与「这份账号现在能用」：
    /// 退出登录、以及令牌过期后静默重登失败（没记住密码）都会清掉令牌与密码，
    /// 此时 `isConfigured` 为 false 而地址与用户名仍在。UI 判断「要不要引导去设置」
    /// 必须看本属性，否则一个只是没登录的账号会被说成「未配置」。
    public var hasAccount: Bool {
        baseURL != nil && !username.isEmpty
    }

    /// 账号填全且本地有可用凭据（密码或令牌）——「现在就能拿它发请求」。
    ///
    /// 密码**不是**必需项：没打开「记住密码」时，重启后密码是空的，但令牌可能仍有效
    /// （JWT 8 天）——那时它仍为 true，不会把「能正常用的账号」判成没配好。
    /// 反过来它**不**适合回答「配过没有」：登出与令牌失效都会让它变 false，
    /// 而地址与用户名一直好着。UI 分档请用 `integrationState` / `hasAccount`。
    public var isConfigured: Bool {
        hasAccount && (!password.isEmpty || hasToken)
    }

    /// 本地有 token（可能已过期，过期靠 401 触发静默重登）。
    public var hasToken: Bool {
        !(accessToken ?? "").isEmpty
    }

    /// 集成状态：分区首页与设置页状态行的**唯一判据**。
    ///
    /// 两处此前各自拼判定（首页 `isConfigured`、设置页 `isConfigured` 三目），
    /// 拼法不一致就会打架——现场是登出 / 令牌失效后首页显示「未配置 MoviePilot」
    /// 并把人赶去设置页，而地址与用户名其实一直好着，缺的只是登录。
    public enum IntegrationState: Sendable, Equatable {
        /// 没填地址或用户名：只能去设置页补。
        case unconfigured
        /// 账号在、但没有可用令牌：登出与令牌失效都落在这里，重新登录即可恢复。
        case loggedOut
        /// 本地有令牌：直接放行（令牌真失效由 401 → 静默重登 → 通知链纠正）。
        case ready
    }

    public var integrationState: IntegrationState {
        guard hasAccount else { return .unconfigured }
        return hasToken ? .ready : .loggedOut
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
            mutateDefaults { $0.removeObject(forKey: Self.serverKey) }
        } else {
            mutateDefaults { $0.set(server, forKey: Self.serverKey) }
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty {
            mutateDefaults { $0.removeObject(forKey: Self.usernameKey) }
        } else {
            mutateDefaults { $0.set(user, forKey: Self.usernameKey) }
        }
        setPasswordUnlocked(password)
        clearTokenUnlocked()
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
            mutateDefaults { $0.set(server, forKey: Self.serverKey) }
        } else {
            mutateDefaults { $0.removeObject(forKey: Self.serverKey) }
        }
        if snapshot.username.isEmpty {
            mutateDefaults { $0.removeObject(forKey: Self.usernameKey) }
        } else {
            mutateDefaults { $0.set(snapshot.username, forKey: Self.usernameKey) }
        }
        setPasswordUnlocked(snapshot.password)
        if let token = snapshot.accessToken, !token.isEmpty {
            credentials.setString(token, forKey: Self.tokenKey)
            mutateDefaults { $0.removeObject(forKey: Self.legacyTokenKey) }
        } else {
            clearTokenUnlocked()
        }
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
        clearTokenUnlocked()
        mutateDefaults { $0.removeObject(forKey: Self.legacyPasswordKey) }
    }

    /// 全部清空（卸载式清理）。
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        sessionPassword = nil
        mutateDefaults {
            $0.removeObject(forKey: Self.serverKey)
            $0.removeObject(forKey: Self.usernameKey)
            $0.removeObject(forKey: Self.legacyPasswordKey)
        }
        credentials.removeValue(forKey: Self.passwordKey)
        clearTokenUnlocked()
    }

    // MARK: - 锁内读取（供快照用）

    /// **必须在 `lock` 内调用**。
    private func passwordUnlocked() -> String {
        if let sessionPassword { return sessionPassword }
        guard defaults.bool(forKey: Self.rememberPasswordKey) else { return "" }
        return credentials.string(forKey: Self.passwordKey) ?? ""
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
