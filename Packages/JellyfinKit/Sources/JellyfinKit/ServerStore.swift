import Foundation
import Security
import os

/// ServerStore 专属日志：编码 / 解码失败在这里留痕，不打断登录流程。
private let storeLog = Logger(subsystem: "dev.jumusu.OcPlayer", category: "ServerStore")

/// 一台已登录服务器的持久化档案。token **不在这里**——进 Keychain（见 `TokenStore`）。
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    /// `serverID:userID`，同一服务器换账号 = 不同 profile。
    public var id: String
    public var serverName: String
    public var baseURL: URL
    public var userID: String
    public var userName: String?
    public var serverVersion: String?

    public init(id: String, serverName: String, baseURL: URL, userID: String,
                userName: String? = nil, serverVersion: String? = nil) {
        self.id = id
        self.serverName = serverName
        self.baseURL = baseURL
        self.userID = userID
        self.userName = userName
        self.serverVersion = serverVersion
    }
}

/// 多服务器 profile 的持久化（UserDefaults 放档案，token 进 `TokenStoring`）。
///
/// 用 class + 显式 save 而不是属性观察：AppModel 持有并 @Observable 转发，
/// 这里保持无 UI 依赖、可单测。存储引用都是 `let`，标 `@unchecked Sendable` 安全。
public final class ServerStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let tokens: TokenStoring

    private let profilesKey = "dev.jumusu.ocplayer.servers"
    private let currentKey = "dev.jumusu.ocplayer.currentServer"

    /// - Debug：token 走 UserDefaults。Debug 包是 ad-hoc 签名、每次构建签名都变，
    ///   Keychain 的 ACL 会把新构建当成另一个 App，每次启动都弹「允许访问钥匙串」要密码。
    /// - Release：token 走 Keychain（`kSecAttrAccessibleAfterFirstUnlock`，不同步 iCloud）。
    public init(defaults: UserDefaults = .standard, tokens: TokenStoring? = nil) {
        self.defaults = defaults
        #if DEBUG
        self.tokens = tokens ?? UserDefaultsTokenStore(defaults: defaults)
        #else
        self.tokens = tokens ?? TokenStore()
        #endif
    }

    // MARK: - 档案

    public var profiles: [ServerProfile] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        do {
            return try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            // 坏数据就当没有（返回空列表是合理兜底），但留一条日志方便排查。
            storeLog.error("读取服务器列表解码失败：\(error, privacy: .public)")
            return []
        }
    }

    public var currentProfile: ServerProfile? {
        guard let id = defaults.string(forKey: currentKey) else { return profiles.first }
        return profiles.first { $0.id == id } ?? profiles.first
    }

    public func save(_ profile: ServerProfile, makeCurrent: Bool = true) {
        var list = profiles.filter { $0.id != profile.id }
        list.append(profile)
        persist(list)
        if makeCurrent { defaults.set(profile.id, forKey: currentKey) }
    }

    public func remove(id: String) {
        persist(profiles.filter { $0.id != id })
        tokens.delete(account: id)
        if defaults.string(forKey: currentKey) == id, let first = profiles.first {
            defaults.set(first.id, forKey: currentKey)
        }
    }

    /// 编码失败**不**落盘：`defaults.set(nil, forKey:)` 会把该 key 整个删掉，
    /// 静默吞掉 `try?` 等于把已有服务器列表清空。失败只记日志，保留旧数据。
    private func persist(_ list: [ServerProfile]) {
        do {
            defaults.set(try JSONEncoder().encode(list), forKey: profilesKey)
        } catch {
            storeLog.error("保存服务器列表编码失败，保留旧数据：\(error, privacy: .public)")
        }
    }

    // MARK: - token（Keychain）

    public func token(for profile: ServerProfile) -> String? {
        tokens.read(account: profile.id)
    }

    /// 登录成功后调用：档案 + token 一起落。
    public func activate(_ profile: ServerProfile, token: String) {
        tokens.save(token, account: profile.id)
        save(profile)
    }

    public func signOut(id: String) {
        tokens.delete(account: id)
    }
}

// MARK: - Keychain

/// token 存取抽象，测试可以换成内存版。
public protocol TokenStoring: Sendable {
    func read(account: String) -> String?
    func save(_ token: String, account: String)
    func delete(account: String)
}

/// Keychain 通用密码实现：kSecAttrAccessibleAfterFirstUnlock、不进 iCloud 同步。
public struct TokenStore: TokenStoring {
    private let service: String

    public init(service: String = "dev.jumusu.OcPlayer.accessToken") {
        self.service = service
    }

    public func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String, account: String) {
        let data = Data(token.utf8)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            // Keychain 在个别环境（无 entitlement 的测试进程等）会拒绝写入。
            // 不让登录流程因此崩掉；读不到 token 时用户重新登录即可。
            return
        }
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// 测试 / 预览用的内存 token 仓库。
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func read(account: String) -> String? {
        lock.withLock { storage[account] }
    }

    public func save(_ token: String, account: String) {
        lock.withLock { storage[account] = token }
    }

    public func delete(account: String) {
        lock.withLock { storage.removeValue(forKey: account) }
    }
}

/// 开发构建（Debug）用的 token 仓库：UserDefaults，避免 ad-hoc 签名变化
/// 触发钥匙串 ACL 反复弹密码。Release 不用它（见 `ServerStore.init`）。
public final class UserDefaultsTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ account: String) -> String {
        "dev.jumusu.ocplayer.token.\(account)"
    }

    public func read(account: String) -> String? {
        lock.withLock { defaults.string(forKey: key(account)) }
    }

    public func save(_ token: String, account: String) {
        lock.withLock { defaults.set(token, forKey: key(account)) }
    }

    public func delete(account: String) {
        lock.withLock { defaults.removeObject(forKey: key(account)) }
    }
}
