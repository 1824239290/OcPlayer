import DiagnosticsKit
import Foundation

/// Bangumi 登录态与关联映射的持久化。
///
/// 与 JellyfinKit 的 `ServerStore` 同风格：class + 锁 + 显式 save。
///
/// **OAuth 凭证（access / refresh token）存 `CredentialFileStore`**（排除备份的文件），
/// 不存 UserDefaults、也不用 Keychain：UserDefaults 会被 iCloud / iTunes 备份带走，
/// 而 Keychain 在本项目的 ad-hoc 签名下会带来开发期授权弹框、CI 无人应答、
/// 以及重签名后凭据读不出来——详见 `CredentialFileStore` 的类型注释。
///
/// 其余非机密状态（登录标记、用户资料、条目关联、同步时间戳）仍留在 UserDefaults。
///
/// ## ⚠️ 别在后台线程上写这里（与 MoviePilotStore 同一个坑）
///
/// 本类型的 `auth` setter / 迁移读都会**持锁**写 `UserDefaults`，而 `BangumiAPIClient`
/// 是 actor——`store.auth = …` 与 `authUnlocked()` 的迁移删除都跑在后台线程上。
/// 后台线程写 `UserDefaults` 会同步通知 SwiftUI 的 `@AppStorage` 观察者，观察者在发通知
/// 的线程上要申请 UI 更新锁（`Update.begin()`）；主线程此刻若正持着那把锁、又在读本类型
/// 的某个属性等这把 `lock`，就是 ABBA 互等、App 永久卡死（2026-10-02 在 MoviePilotStore
/// 上实际发生过，`sample` 有完整记录）。
///
/// 现在够不着那条环，只因为**没有任何视图在 body 求值里读本类型**——`BangumiContext`
/// 把 UI 需要的东西都存成了 @Observable 存储属性（`App/Shared` 里唯一一处
/// `context.store.…` 读在 async 上下文里）。所以别在 body 里读 `store.*`；真需要读，
/// 那道锁和后台写入就都成了隐患，届时按 `MoviePilotStore.mutateDefaults(_:)` 的写法
/// 把写入收回主线程。
public final class BangumiStore: @unchecked Sendable {
    /// 全局共用实例。同一份 UserDefaults 被多个 store 实例读写时，每个实例各有一把锁
    /// 等于没锁，所以除测试注入自定义 defaults 外都用这一个。
    public static let shared = BangumiStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let credentials: CredentialFileStore

    private let isAuthenticatedKey = "dev.jumusu.ocplayer.bangumi.isAuthenticated"
    private let profileKey = "dev.jumusu.ocplayer.bangumi.profile"
    /// 凭据文件内的键名。
    private let authKey = "bangumi.auth"
    /// 旧键：老版本把凭证 Data 放在 UserDefaults。仅迁移用。
    private let legacyAuthKey = "dev.jumusu.ocplayer.bangumi.auth"
    private let linkPrefix = "dev.jumusu.ocplayer.bangumi.link."
    private let collectionsUpdatedAtKey = "dev.jumusu.ocplayer.bangumi.collectionsUpdatedAt"

    public init(defaults: UserDefaults = .standard, credentialsDirectory: URL? = nil) {
        self.defaults = defaults
        // 生产用全局单例（多个域包共用一个文件）；测试传临时目录拿到隔离实例。
        self.credentials = credentialsDirectory.map { CredentialFileStore(directory: $0) } ?? .shared
    }

    /// 是否已登录（UI 的唯一门控信号）。
    ///
    /// **必须同时有标记位和凭证**：401 被动失效只清 token，如果这里只看标记位，
    /// UI 会永远停在「已登录」而每次操作静默失败。
    public var isAuthenticated: Bool {
        lock.withLock {
            defaults.bool(forKey: isAuthenticatedKey) && authUnlocked() != nil
        }
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

    /// OAuth 凭证（JSON 编码的 BangumiAuth）。存凭据文件，排除备份。
    public var auth: BangumiAuth? {
        get {
            lock.withLock {
                guard let data = authUnlocked() else { return nil }
                return try? JSONDecoder().decode(BangumiAuth.self, from: data)
            }
        }
        set {
            lock.withLock {
                // 「主动清空」与「编码失败」分开处理：原实现把两者并进同一个 else，
                // 编码失败会顺手把凭证删掉 —— 等于一次编码异常就把用户静默登出。
                // 编码失败保留旧凭证，只在显式传 nil 时删除。
                guard let newValue else {
                    credentials.removeValue(forKey: authKey)
                    defaults.removeObject(forKey: legacyAuthKey)
                    return
                }
                guard let data = try? JSONEncoder().encode(newValue) else { return }
                credentials.setData(data, forKey: authKey)
                defaults.removeObject(forKey: legacyAuthKey)
            }
        }
    }

    /// 读凭证（**必须在 `lock` 内调用**）：优先凭据文件；没有则从旧 UserDefaults 键
    /// 一次性迁移——搬到文件后立刻删掉旧键，否则明文副本会继续留在会进备份的
    /// UserDefaults 里，迁移的收益就等于零。
    private func authUnlocked() -> Data? {
        if let data = credentials.data(forKey: authKey) { return data }
        guard let legacy = defaults.data(forKey: legacyAuthKey) else { return nil }
        credentials.setData(legacy, forKey: authKey)
        defaults.removeObject(forKey: legacyAuthKey)
        return legacy
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
            defaults.removeObject(forKey: collectionsUpdatedAtKey)
            // 凭证在文件里，两个键都要清（旧键可能还没被迁移过）。
            credentials.removeValue(forKey: authKey)
            defaults.removeObject(forKey: legacyAuthKey)
        }
    }
}
