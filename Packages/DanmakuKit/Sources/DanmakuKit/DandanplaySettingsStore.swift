import Foundation

/// 弹幕网关设置存取。
///
/// 网关地址以原始字符串形式存 UserDefaults，设置页可以保存任意输入中间态；
/// 读取网关 URL 时再做规范化，缺 scheme 自动补 `https://`。
/// API Key 只存 UserDefaults。项目发行包统一使用 ad-hoc 签名，不引入 Keychain
/// 或签名身份探测，避免不同构建身份导致凭据不可读。
///
/// 测试可注入 `UserDefaults` 与内存凭据存储。
public struct DandanplaySettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let credentialStore: DandanplayCredentialStoring

    private static let gatewayURLKey = "dev.jumusu.ocplayer.dandanplay.gatewayURL"

    /// 网关默认地址（自定义域名，可在设置页覆盖）。
    public static let defaultGatewayURL = URL(string: "https://dandanplay.3841625.xyz")!

    /// 内置公共 API Key：由 OcPlay 网关管理端签发，随 App 分发，开箱即用。
    /// 属公共额度（任何拿到 App 的人都能用它请求网关），不适合高安全场景；
    /// 用户可在设置页用自有的 Key 覆盖，清空后回落此默认值。
    public static let defaultAPIKey = "ocp_-zNBxWgtukt0JD7sjQQgzcNk99MUrERqGlg6rABKFQQ"

    public init(
        defaults: UserDefaults = .standard,
        credentialStore: DandanplayCredentialStoring? = nil
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore ?? DandanplayCredentialStore(defaults: defaults)
    }

    /// 设置页直接绑定的原始地址字符串。nil = 从未设置（使用默认地址）；
    /// 空串会清空保存，方便用户恢复默认。
    public var gatewayURLString: String? {
        get { defaults.string(forKey: Self.gatewayURLKey) }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                defaults.removeObject(forKey: Self.gatewayURLKey)
            } else {
                defaults.set(value, forKey: Self.gatewayURLKey)
            }
        }
    }

    /// 规范化后的网关地址；无法解析时回落默认地址。
    public var gatewayURL: URL {
        get { Self.normalizedURL(from: gatewayURLString ?? "") ?? Self.defaultGatewayURL }
        set { gatewayURLString = newValue.absoluteString }
    }

    public var apiKey: String {
        // 未显式设置（或用户清空）时回落内置公共 Key，保证开箱即用。
        get { credentialStore.readAPIKey() ?? Self.defaultAPIKey }
        set {
            if newValue.isEmpty {
                credentialStore.deleteAPIKey()
            } else {
                credentialStore.writeAPIKey(newValue)
            }
        }
    }

    /// 配置是否就绪：未填写地址时使用默认网关；显式地址必须是 HTTPS origin，
    /// 且 API Key 非空（未设置时使用内置默认 Key）。
    public var isConfigured: Bool {
        let url: URL
        if let raw = gatewayURLString {
            guard let normalized = Self.normalizedURL(from: raw) else { return false }
            url = normalized
        } else {
            url = Self.defaultGatewayURL
        }
        return url.scheme?.lowercased() == "https" &&
            url.user == nil &&
            url.password == nil &&
            url.query == nil &&
            url.fragment == nil &&
            !apiKey.isEmpty
    }

    /// 解析 + 规范化：不含 scheme（无 `://`）补 `https://`；只接受 HTTPS origin。
    public static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: URL?
        if trimmed.contains("://") {
            candidate = URL(string: trimmed)
        } else {
            candidate = URL(string: "https://\(trimmed)")
        }
        guard let candidate,
              candidate.scheme?.lowercased() == "https",
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

/// API Key 存储抽象，便于测试注入。
public protocol DandanplayCredentialStoring: Sendable {
    func readAPIKey() -> String?
    func writeAPIKey(_ value: String)
    func deleteAPIKey()
}

/// 生产实现：API Key 存在 UserDefaults。发行包统一使用 ad-hoc 签名，
/// 因此不使用 Keychain，避免签名身份变化造成凭据不可读。
public struct DandanplayCredentialStore: DandanplayCredentialStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let defaultsKey = "dev.jumusu.ocplayer.dandanplay.apiKey"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func readAPIKey() -> String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    public func writeAPIKey(_ value: String) {
        defaults.set(value, forKey: Self.defaultsKey)
    }

    public func deleteAPIKey() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
