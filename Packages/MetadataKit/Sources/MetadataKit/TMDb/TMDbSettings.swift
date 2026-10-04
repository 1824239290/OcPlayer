import Foundation

/// TMDb 凭据的读取口。
///
/// 与 `DandanplayCredentialStoring` / `AnimeSkipSettingsStore` 同款：**协议 + 生产实现**，
/// 测试注入替身。存 UserDefaults 而不是 Keychain——发行包统一 ad-hoc 签名，
/// Keychain 条目会因 cdhash 变化变成「另一个 App 的」，重签名后读不出来
/// （详见 `CredentialFileStore` 的类型注释）。
public protocol TMDbCredentialProviding: Sendable {
    /// nil / 空串 = **整个 TMDb 功能禁用**（与 AnimeSkip client id 的「留空即禁用」一致）。
    func apiKey() -> String?
}

/// 生产实现：UserDefaults。
///
/// 用户自填 key（Phase 2 的密钥路线：不内置、不走网关），支持两种形态：
/// - **v4 Read Access Token**（JWT，`eyJ…`）→ 走 `Authorization: Bearer`
/// - **v3 API Key**（32 位十六进制）→ 走 `api_key` 查询参数
///
/// 两种都接受，由 `TMDbClient` 按形态自动选择——用户从 TMDb 设置页复制哪个都行，
/// 不该要求他先搞清 v3/v4 的区别。
public struct TMDbCredentialStore: TMDbCredentialProviding, @unchecked Sendable {
    private let defaults: UserDefaults
    /// key 与 dandanplay / animeskip 的先例一致：`dev.jumusu.ocplayer.<域>.<项>`。
    public static let defaultsKey = "dev.jumusu.ocplayer.tmdb.apiKey"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func apiKey() -> String? {
        let raw = defaults.string(forKey: Self.defaultsKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func setAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(trimmed, forKey: Self.defaultsKey)
        }
    }
}

/// TMDb 的语言与字段策略。
///
/// 存 UserDefaults：这些是用户可见的设置项（设置页「TMDb」区块）。
/// `@unchecked Sendable`：`UserDefaults` 自身线程安全（内部有锁），
/// 与 `TMDbCredentialStore` / `ServerStore` 等既有 store 同款取舍。
public struct TMDbPreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public static let languageKey = "dev.jumusu.ocplayer.tmdb.language"
    public static let preferTMDbTextKey = "dev.jumusu.ocplayer.tmdb.preferText"
    public static let fillMissingImagesKey = "dev.jumusu.ocplayer.tmdb.fillImages"
    public static let expiresDaysKey = "dev.jumusu.ocplayer.tmdb.cacheDays"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 主语言。默认 `zh-CN`。
    public var language: String {
        get { defaults.string(forKey: Self.languageKey) ?? "zh-CN" }
        nonmutating set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { defaults.removeObject(forKey: Self.languageKey) }
            else { defaults.set(v, forKey: Self.languageKey) }
        }
    }

    /// 回退语言：主语言缺该字段时用它补。默认 `en-US`。
    public var fallbackLanguage: String { "en-US" }

    /// 文本是否以 TMDb 优先（用户已选定：默认 true）。
    ///
    /// 用 `object(forKey:)` 判存在而不是 `bool(forKey:)`：后者对「默认开」的开关
    /// 在键不存在时返回 false，会让默认值静默失效（`SettingsKeys` 里记着这个坑）。
    public var preferTMDbText: Bool {
        get {
            guard defaults.object(forKey: Self.preferTMDbTextKey) != nil else { return true }
            return defaults.bool(forKey: Self.preferTMDbTextKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.preferTMDbTextKey) }
    }

    /// 图片是否允许**顶替**服务端已有的图。默认 false（只补缺）。
    ///
    /// 与文本策略分开：文本可以整份换语言，而「谁的图更好」没有客观答案——
    /// 用户用刮削器精修过的海报被 TMDb 顶掉是单向损失。
    public var replaceExistingImages: Bool {
        get { defaults.bool(forKey: Self.fillMissingImagesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.fillMissingImagesKey) }
    }

    /// 缓存有效期（天）。
    ///
    /// **TMDb 的 API 条款禁止缓存超过 6 个月**，所以这里硬性夹在 [1, 180]。
    /// 默认 90 天：远小于上限，又长到不必频繁回源。
    public var cacheDays: Int {
        get {
            let stored = defaults.integer(forKey: Self.expiresDaysKey)
            return stored > 0 ? min(max(stored, 1), Self.maxCacheDays) : Self.defaultCacheDays
        }
        nonmutating set {
            defaults.set(min(max(newValue, 1), Self.maxCacheDays), forKey: Self.expiresDaysKey)
        }
    }

    public static let defaultCacheDays = 90
    /// 条款上限：6 个月。**不要调大**——那是 ToS 的硬约束，不是工程取舍。
    public static let maxCacheDays = 180

    public var cacheLifetime: TimeInterval {
        TimeInterval(cacheDays) * 24 * 60 * 60
    }
}
