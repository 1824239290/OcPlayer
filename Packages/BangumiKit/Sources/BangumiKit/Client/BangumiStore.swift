import Foundation

/// Bangumi 登录态与关联映射的 UserDefaults 持久化。
///
/// 与 JellyfinKit 的 `ServerStore` 同风格：class + 锁 + 显式 save。
/// token 存 UserDefaults 而不是 Keychain（发行包统一 ad-hoc 签名，与现有 Jellyfin token 一致）。
public final class BangumiStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults

    private let isAuthenticatedKey = "dev.jumusu.ocplayer.bangumi.isAuthenticated"
    private let profileKey = "dev.jumusu.ocplayer.bangumi.profile"
    private let authKey = "dev.jumusu.ocplayer.bangumi.auth"
    private let linkPrefix = "dev.jumusu.ocplayer.bangumi.link."
    private let collectionsUpdatedAtKey = "dev.jumusu.ocplayer.bangumi.collectionsUpdatedAt"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否已登录（UI 的唯一门控信号）。
    public var isAuthenticated: Bool {
        lock.withLock { defaults.bool(forKey: isAuthenticatedKey) }
    }

    public func setAuthenticated(_ value: Bool) {
        lock.withLock { defaults.set(value, forKey: isAuthenticatedKey) }
    }

    /// 登录用户资料（JSON 字符串，Bangumi-iOS 的 AppConfig.profile 同格式）。
    public var profile: BangumiProfile? {
        lock.withLock {
            guard let raw = defaults.string(forKey: profileKey), !raw.isEmpty else { return nil }
            return BangumiProfile(from: raw)
        }
    }

    public var profileRaw: String {
        lock.withLock { defaults.string(forKey: profileKey) ?? "" }
    }

    public func setProfile(_ profile: BangumiProfile?) {
        lock.withLock {
            defaults.set(profile?.rawValue, forKey: profileKey)
        }
    }

    /// OAuth 凭证（JSON 编码的 BangumiAuth）。
    public var auth: BangumiAuth? {
        get {
            lock.withLock {
                guard let data = defaults.data(forKey: authKey) else { return nil }
                return try? JSONDecoder().decode(BangumiAuth.self, from: data)
            }
        }
        set {
            lock.withLock {
                if let newValue, let data = try? JSONEncoder().encode(newValue) {
                    defaults.set(data, forKey: authKey)
                } else {
                    defaults.removeObject(forKey: authKey)
                }
            }
        }
    }

    /// 收藏增量同步的时间戳（秒）。0 表示从未同步过（下次全量拉取）。
    public var collectionsUpdatedAt: Int {
        lock.withLock { defaults.integer(forKey: collectionsUpdatedAtKey) }
    }

    public func setCollectionsUpdatedAt(_ value: Int) {
        lock.withLock { defaults.set(value, forKey: collectionsUpdatedAtKey) }
    }

    // MARK: - Jellyfin ↔ Bangumi 条目关联

    /// 查询一条 Jellyfin 条目的 Bangumi subject 关联。
    public func bangumiSubjectID(forJellyfinItemID itemID: String) -> Int? {
        lock.withLock {
            let key = linkPrefix + itemID
            return defaults.object(forKey: key) as? Int
        }
    }

    public func setBangumiSubjectID(_ subjectID: Int?, forJellyfinItemID itemID: String) {
        lock.withLock {
            let key = linkPrefix + itemID
            if let subjectID {
                defaults.set(subjectID, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - 账户本地数据

    /// 登出/换号时清理所有账户相关持久化数据。
    public func clearAccountState() {
        lock.withLock {
            defaults.removeObject(forKey: isAuthenticatedKey)
            defaults.removeObject(forKey: profileKey)
            defaults.removeObject(forKey: authKey)
            defaults.removeObject(forKey: collectionsUpdatedAtKey)
        }
    }
}
