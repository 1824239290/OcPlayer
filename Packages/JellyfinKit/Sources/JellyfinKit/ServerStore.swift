import Foundation

/// 一台已登录服务器的持久化档案。token 单独存进本地 UserDefaults。
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

/// 多服务器 profile 的持久化（档案和 token 均存本地 UserDefaults，使用不同 key）。
///
/// 用 class + 显式 save 而不是属性观察：AppModel 持有并 @Observable 转发，
/// 这里保持无 UI 依赖、可单测。存储引用都是 `let`，标 `@unchecked Sendable` 安全。
public final class ServerStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let tokens: TokenStoring

    private let profilesKey = "dev.jumusu.ocplayer.servers"
    private let currentKey = "dev.jumusu.ocplayer.currentServer"

    public init(defaults: UserDefaults = .standard, tokens: TokenStoring? = nil) {
        self.defaults = defaults
        self.tokens = tokens ?? LocalTokenStore(defaults: defaults)
    }

    // MARK: - 档案

    public var profiles: [ServerProfile] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        do {
            return try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            // 坏数据就当没有（返回空列表是合理兜底），但留一条日志方便排查。
            NetworkLog.logger.error("读取服务器列表解码失败 error=\(error)")
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
            NetworkLog.logger.error("保存服务器列表编码失败，保留旧数据 error=\(error)")
        }
    }

    // MARK: - token

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

/// token 存取抽象，测试可以换成内存版。
public protocol TokenStoring: Sendable {
    func read(account: String) -> String?
    func save(_ token: String, account: String)
    func delete(account: String)
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
        lock.withLock { _ = storage.removeValue(forKey: account) }
    }
}

/// 本地 token 仓库。使用与服务器档案相同的 UserDefaults，不访问系统钥匙串。
public final class LocalTokenStore: TokenStoring, @unchecked Sendable {
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
