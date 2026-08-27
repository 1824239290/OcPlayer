import Foundation

/// 媒体服务器类型。Emby 是 Jellyfin 的前身（3.5.2 fork），两者 API 高度同源，
/// 大部分链路共用；差异点（URL 前缀、Quick Connect、两条老式路由）按这个枚举分叉。
public enum ServerKind: String, Codable, Sendable {
    case jellyfin
    case emby
}

/// 一台已登录服务器的持久化档案。token 单独存进本地 UserDefaults。
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    /// `serverID:userID`，同一服务器换账号 = 不同 profile。
    public var id: String
    public var serverName: String
    public var baseURL: URL
    public var userID: String
    public var userName: String?
    public var serverVersion: String?
    /// 服务器类型；Emby 的 `baseURL` 已含 `/emby` 前缀。
    public var kind: ServerKind

    public init(id: String, serverName: String, baseURL: URL, userID: String,
                userName: String? = nil, serverVersion: String? = nil,
                kind: ServerKind = .jellyfin) {
        self.id = id
        self.serverName = serverName
        self.baseURL = baseURL
        self.userID = userID
        self.userName = userName
        self.serverVersion = serverVersion
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, serverName, baseURL, userID, userName, serverVersion, kind
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        serverName = try values.decode(String.self, forKey: .serverName)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        userID = try values.decode(String.self, forKey: .userID)
        userName = try values.decodeIfPresent(String.self, forKey: .userName)
        serverVersion = try values.decodeIfPresent(String.self, forKey: .serverVersion)
        // 旧版本落盘的 profile 没有 kind 字段：默认 Jellyfin，不炸老数据。
        kind = try values.decodeIfPresent(ServerKind.self, forKey: .kind) ?? .jellyfin
    }
}

/// 多服务器 profile 的持久化（档案和 token 均存本地 UserDefaults，使用不同 key）。
///
/// 用 class + 显式 save 而不是属性观察：AppModel 持有并 @Observable 转发，
/// 这里保持无 UI 依赖、可单测。profile 列表及当前 ID 的复合操作由同一把锁保护。
public final class ServerStore: @unchecked Sendable {
    private let lock = NSLock()
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
        lock.withLock { profilesUnlocked() }
    }

    public var currentProfile: ServerProfile? {
        lock.withLock {
            let profiles = profilesUnlocked()
            guard let id = defaults.string(forKey: currentKey) else { return profiles.first }
            return profiles.first { $0.id == id } ?? profiles.first
        }
    }

    public func save(_ profile: ServerProfile, makeCurrent: Bool = true) {
        lock.withLock {
            var list = profilesUnlocked().filter { $0.id != profile.id }
            list.append(profile)
            persistUnlocked(list)
            if makeCurrent { defaults.set(profile.id, forKey: currentKey) }
        }
    }

    public func remove(id: String) {
        lock.withLock {
            let list = profilesUnlocked().filter { $0.id != id }
            persistUnlocked(list)

            if defaults.string(forKey: currentKey) == id {
                if let first = list.first {
                    defaults.set(first.id, forKey: currentKey)
                } else {
                    defaults.removeObject(forKey: currentKey)
                }
            }
        }
        tokens.delete(account: id)
    }

    private func profilesUnlocked() -> [ServerProfile] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        do {
            return try JSONDecoder().decode([ServerProfile].self, from: data)
        } catch {
            // 坏数据就当没有（返回空列表是合理兜底），但留一条日志方便排查。
            NetworkLog.logger.error("读取服务器列表解码失败 error=\(error)")
            return []
        }
    }

    /// 编码失败**不**落盘：`defaults.set(nil, forKey:)` 会把该 key 整个删掉，
    /// 静默吞掉 `try?` 等于把已有服务器列表清空。失败只记日志，保留旧数据。
    private func persistUnlocked(_ list: [ServerProfile]) {
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
