import DiagnosticsKit
import Foundation

/// 媒体服务器类型。Emby 是 Jellyfin 的前身（3.5.2 fork），两者 API 高度同源，
/// 大部分链路共用；差异点（URL 前缀、Quick Connect、两条老式路由）按这个枚举分叉。
public enum ServerKind: String, Codable, Sendable {
    case jellyfin
    case emby

    /// 服务器列表标识上显示的产品名。
    public var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }
}

/// 一台已登录服务器的持久化档案。token 单独存进本地 UserDefaults。
///
/// **一台服务器 = 一个档案 = 一组地址**（`baseURL` + `addresses`）。地址之间的
/// 取舍是运行时的（`ServerEndpointDirectory` 探活择优），档案只记住「有哪些入口」
/// 和「上次用的是哪个」。
public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    /// `serverID:userID`，同一服务器换账号 = 不同 profile。
    public var id: String
    public var serverName: String
    /// **当前生效**（最近一次探活选中）的地址。登录 / 切换 / 探活都会更新它。
    public var baseURL: URL
    public var userID: String
    public var userName: String?
    public var serverVersion: String?
    /// 服务器类型；Emby 的 `baseURL` 已含 `/emby` 前缀。
    public var kind: ServerKind
    /// 备选地址（**不含** `baseURL`）。同一台服务器的其它入口：局域网、Tailscale、反代域名。
    public var addresses: [ServerAddress]
    /// 用户固定使用的地址；nil = 自动择优（默认）。
    public var pinnedURL: URL?
    /// 服务端 `/System/Info/Public` 报的服务器 Id。老档案没有这个字段，用 `id` 前缀兜底。
    public var serverID: String?

    public init(id: String, serverName: String, baseURL: URL, userID: String,
                userName: String? = nil, serverVersion: String? = nil,
                kind: ServerKind = .jellyfin,
                addresses: [ServerAddress] = [],
                pinnedURL: URL? = nil,
                serverID: String? = nil) {
        self.id = id
        self.serverName = serverName
        self.baseURL = baseURL
        self.userID = userID
        self.userName = userName
        self.serverVersion = serverVersion
        self.kind = kind
        self.addresses = addresses
        self.pinnedURL = pinnedURL
        self.serverID = serverID
    }

    /// 全部候选地址：`baseURL` 打头 + 其余备选，归一化去重。
    /// 顺序只在**地址延迟相同**或全部探活失败时才有意义（决议器按实测延迟排序）。
    public var allAddresses: [ServerAddress] {
        ServerAddress.list(from: [baseURL] + addresses.map(\.url))
    }

    /// 用于探活校验的服务器 ID。显式字段优先；老档案从 `id`（`serverID:userID`）
    /// 的前缀里恢复。
    ///
    /// 前缀必须**看起来像服务器 Id** 才认。老版本在服务器没报 `Id` 时会拿 host
    /// （`nas`）甚至整个地址字符串（`http`）来拼档案 id，那些值是主机名/协议名不是
    /// 服务器 Id —— 拿它当校验值，探活会把**每一条**地址都判成「另一台服务器」，
    /// 于是「添加地址」误报、启动换址静默失效（`firstReachable` 全 nil 后回落到
    /// baseURL，连报错都没有）。Jellyfin / Emby 的服务器 Id 是 32 位十六进制。
    public var resolvedServerID: String? {
        if let serverID, !serverID.isEmpty { return serverID }
        guard let separator = id.firstIndex(of: ":") else { return nil }
        let prefix = String(id[id.startIndex..<separator])
        guard prefix.count >= 16, prefix.allSatisfy(\.isHexDigit) else { return nil }
        return prefix
    }

    private enum CodingKeys: String, CodingKey {
        case id, serverName, baseURL, userID, userName, serverVersion, kind
        case addresses, pinnedURL, serverID
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
        // 这三个同样是后加的字段：老档案解出来是「没有备选地址、自动择优」的正
        // 常状态，不是坏数据。
        addresses = try values.decodeIfPresent([ServerAddress].self, forKey: .addresses) ?? []
        pinnedURL = try values.decodeIfPresent(URL.self, forKey: .pinnedURL)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID)
    }

    /// 合并同 id 的两个档案（同一台服务器、同一个账号从**另一条地址**登录）。
    ///
    /// 身份字段以新登录为准（服务器名 / 版本 / 用户名可能是新装的），地址取并集：
    /// 旧地址退成候选，新地址成为当前 —— 这正是「用 Tailscale 地址登录一次，
    /// 不会再多出一个服务器条目」的落点。
    static func merged(existing: ServerProfile, incoming: ServerProfile) -> ServerProfile {
        var result = incoming
        result.addresses = ServerAddress.list(
            from: [existing.baseURL] + existing.addresses.map(\.url) + incoming.addresses.map(\.url),
            excluding: incoming.baseURL)
        // 固定项由用户在设置页决定，登录流程不碰它：新登录没带就沿用旧的。
        if result.pinnedURL == nil { result.pinnedURL = existing.pinnedURL }
        if result.serverID == nil { result.serverID = existing.resolvedServerID }
        return result
    }
}

/// 多服务器 profile 的持久化（档案和 token 均存本地 UserDefaults，使用不同 key）。
///
/// 用 class + 显式 save 而不是属性观察：AppModel 持有并 @Observable 转发，
/// 这里保持无 UI 依赖、可单测。profile 列表及当前 ID 的复合操作由同一把锁保护。
///
/// **写路径必须留在主线程**：`UserDefaults` 每次写入都会同步发变更通知，SwiftUI
/// 给 `@AppStorage` 挂的观察者会在发通知的那个线程上申请 UI 更新锁 —— 后台线程
/// 持 store 锁写 defaults、主线程持 UI 锁读 store，就是一例必死的 ABBA 互等
/// （MoviePilotStore 上实测过，见 CHANGELOG）。地址决议器跑在后台线程，所以它
/// 只回调 `onChange`，由 App 层 hop 回主线程再调这里。
public final class ServerStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let tokens: TokenStoring

    private let profilesKey = "dev.jumusu.ocplayer.servers"
    private let currentKey = "dev.jumusu.ocplayer.currentServer"
    /// 启动时优先使用的服务器档案 ID。nil = 跟随「上次使用的服务器」（`currentKey`）。
    private let defaultServerKey = "dev.jumusu.ocplayer.defaultServer"
    /// 解码缓存，nil = 尚未读过；受 `lock` 保护（读路径 profilesUnlocked 也在锁内）。
    private var cachedProfiles: [ServerProfile]?
    /// 每个档案一个地址决议器（进程内共享：切走再切回来复用同一份决议结果，
    /// 不会因为重建 `MediaServer` 就把刚探活的结论丢掉）。同样受 `lock` 保护。
    private var directories: [String: ServerEndpointDirectory] = [:]

    /// 测试注入：替换真实探活。生产恒为 nil。
    var probeOverride: (@Sendable (URL) async -> ServerProbeResult?)?
    /// 探活超时。测试可以调小，免得等满默认的 2 秒。
    var probeTimeout: TimeInterval = 2

    public init(
        defaults: UserDefaults = .standard,
        tokens: TokenStoring? = nil,
        credentialsDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.tokens = tokens ?? LocalTokenStore(defaults: defaults, credentialsDirectory: credentialsDirectory)
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

    /// 用户指定的启动默认服务器 ID；nil = 未指定，启动跟随上次使用的服务器。
    public var defaultServerID: String? {
        get { lock.withLock { defaults.string(forKey: defaultServerKey) } }
        set {
            lock.withLock {
                if let newValue, !newValue.isEmpty {
                    defaults.set(newValue, forKey: defaultServerKey)
                } else {
                    defaults.removeObject(forKey: defaultServerKey)
                }
            }
        }
    }

    /// 启动恢复时优先尝试的档案：设了默认服务器且档案仍在就用它；否则与 `currentProfile` 一致。
    /// token 是否可用由调用方（`MediaServerFactory.restore(from:)`）再判断并回退。
    public var launchProfile: ServerProfile? {
        lock.withLock {
            let profiles = profilesUnlocked()
            if let id = defaults.string(forKey: defaultServerKey),
               let preferred = profiles.first(where: { $0.id == id }) {
                return preferred
            }
            guard let id = defaults.string(forKey: currentKey) else { return profiles.first }
            return profiles.first { $0.id == id } ?? profiles.first
        }
    }

    /// 落一个档案。**同 id 的已有档案会合并地址**，不是整体替换：
    /// 同一台服务器从另一条地址登录（家里的局域网 → 出门用 Tailscale）时，
    /// 档案 id（`serverID:userID`）不变，旧地址必须留成备选，否则用户一出门
    /// 就得到处找地址重新登录。
    public func save(_ profile: ServerProfile, makeCurrent: Bool = true) {
        let saved: ServerProfile = lock.withLock {
            var list = profilesUnlocked()
            let merged: ServerProfile
            if let index = list.firstIndex(where: { $0.id == profile.id }) {
                merged = ServerProfile.merged(existing: list[index], incoming: profile)
                list[index] = merged
            } else {
                merged = profile
                list.append(merged)
            }
            persistUnlocked(list)
            if makeCurrent { defaults.set(merged.id, forKey: currentKey) }
            return merged
        }
        syncDirectory(with: saved)
    }

    public func remove(id: String) {
        lock.withLock {
            let list = profilesUnlocked().filter { $0.id != id }
            persistUnlocked(list)
            directories.removeValue(forKey: id)

            if defaults.string(forKey: currentKey) == id {
                if let first = list.first {
                    defaults.set(first.id, forKey: currentKey)
                } else {
                    defaults.removeObject(forKey: currentKey)
                }
            }
            // 默认服务器指向被删档案时一并清掉，避免启动时留一个悬空 ID。
            if defaults.string(forKey: defaultServerKey) == id {
                defaults.removeObject(forKey: defaultServerKey)
            }
        }
        tokens.delete(account: id)
    }

    // MARK: - 地址（一台服务器多个入口）

    /// 给已有档案补一个备选地址。返回 false = 档案不存在，或这个地址已经在列表里
    /// （含与 `baseURL` 相同的情况）。
    @discardableResult
    public func addAddress(_ url: URL, to profileID: String) -> Bool {
        var added = false
        mutate(profileID) { profile in
            // 与当前生效地址相同、或已在备选里：都不是「新增」。
            guard !ServerAddress.isSame(profile.baseURL, url),
                  !profile.addresses.contains(where: { ServerAddress.isSame($0.url, url) })
            else { return }
            profile.addresses = ServerAddress.list(
                from: profile.addresses.map(\.url) + [url],
                excluding: profile.baseURL)
            added = true
        }
        return added
    }

    /// 删掉一个备选地址。删的是**当前生效地址**时，把剩下的第一个提上来当 `baseURL`
    /// （档案必须至少留一个地址，删最后一个是不允许的，UI 也不给这个入口）。
    public func removeAddress(_ url: URL, from profileID: String) {
        mutate(profileID) { profile in
            if ServerAddress.isSame(profile.baseURL, url) {
                guard let next = profile.addresses.first else { return }
                profile.baseURL = next.url
                profile.addresses = ServerAddress.list(
                    from: profile.addresses.dropFirst().map(\.url),
                    excluding: next.url)
                if let pinned = profile.pinnedURL, ServerAddress.isSame(pinned, url) {
                    profile.pinnedURL = nil
                }
                return
            }
            profile.addresses = ServerAddress.list(
                from: profile.addresses.map(\.url).filter { !ServerAddress.isSame($0, url) },
                excluding: profile.baseURL)
            if let pinned = profile.pinnedURL, ServerAddress.isSame(pinned, url) {
                profile.pinnedURL = nil
            }
        }
    }

    /// 固定使用某个地址（`nil` = 恢复自动择优）。传进来的地址必须已经在档案的地址
    /// 列表里，否则忽略 —— 免得手动固定出一个用户没添加过的地址。
    public func setPinnedAddress(_ url: URL?, for profileID: String) {
        mutate(profileID) { profile in
            guard let url else {
                profile.pinnedURL = nil
                return
            }
            guard profile.allAddresses.contains(where: { ServerAddress.isSame($0.url, url) }) else { return }
            profile.pinnedURL = url
        }
    }

    /// 记下当前生效地址（决议器选中新地址时由 App 层调，**主线程**）。
    /// 旧地址退成备选，下次仍然参与探活。
    public func markActiveURL(_ url: URL, for profileID: String) {
        mutate(profileID) { profile in
            guard !ServerAddress.isSame(profile.baseURL, url) else { return }
            profile.addresses = ServerAddress.list(
                from: profile.addresses.map(\.url) + [profile.baseURL],
                excluding: url)
            profile.baseURL = url
        }
    }

    /// 档案的地址决议器（不存在就按档案建一个）。
    ///
    /// 由 store 托管而不是由 `MediaServer` 自己持有：切服务器 / 重启会话会重建
    /// `MediaServer`，但「这台服务器现在该走哪个地址」的结论应该活得更久。
    public func endpointDirectory(
        for profile: ServerProfile,
        sessionConfiguration: URLSessionConfiguration = .default
    ) -> ServerEndpointDirectory {
        let directory: ServerEndpointDirectory = lock.withLock {
            if let existing = directories[profile.id] { return existing }
            let created = ServerEndpointDirectory(
                profile: profile,
                probe: ServerProbe(timeout: probeTimeout,
                                   sessionConfiguration: sessionConfiguration,
                                   inject: probeOverride))
            directories[profile.id] = created
            return created
        }
        directory.sync(profile: profile)
        return directory
    }

    /// 网络路径变化 / 应用回前台：所有档案的地址结论作废，下次请求重新探活。
    public func invalidateEndpoints() {
        let list: [ServerEndpointDirectory] = lock.withLock { Array(directories.values) }
        for directory in list { directory.invalidate() }
    }

    /// 改档案的唯一落点：持锁改 + 落盘，出锁后同步决议器。
    /// 决议器同步放在锁外是刻意的 —— 它可能触发 `onChange`，而 `onChange` 的
    /// 接收方（App 层）会回调 store，持锁回调就是一把 ABBA 锁。
    ///
    /// **空操作不落盘也不同步**：这些地址管理口会被"其实什么都没改"的调用打到
    /// （典型是 App 层每次挂会话都对齐一次当前地址），而每次 `UserDefaults` 写入
    /// 都会同步发变更通知给 SwiftUI 的观察者 —— 白写的代价不只是磁盘。
    private func mutate(_ profileID: String, _ body: (inout ServerProfile) -> Void) {
        let updated: ServerProfile? = lock.withLock {
            var list = profilesUnlocked()
            guard let index = list.firstIndex(where: { $0.id == profileID }) else { return nil }
            let original = list[index]
            var profile = original
            body(&profile)
            guard profile != original else { return nil }
            list[index] = profile
            persistUnlocked(list)
            return profile
        }
        if let updated { syncDirectory(with: updated) }
    }

    private func syncDirectory(with profile: ServerProfile) {
        let directory: ServerEndpointDirectory? = lock.withLock { directories[profile.id] }
        directory?.sync(profile: profile)
    }

    private func profilesUnlocked() -> [ServerProfile] {
        // 进程内缓存：profiles 被视图高频读取（每次重渲染都来问），逐次从
        // UserDefaults 全量 JSONDecoder 解码纯浪费。所有写路径都经同一把锁的
        // persistUnlocked，缓存写穿即可；nil = 还没读过（空列表是合法缓存值）。
        if let cached = cachedProfiles { return cached }
        guard let data = defaults.data(forKey: profilesKey) else {
            cachedProfiles = []
            return []
        }
        do {
            let list = try JSONDecoder().decode([ServerProfile].self, from: data)
            cachedProfiles = list
            return list
        } catch {
            // 坏数据就当没有（返回空列表是合理兜底），但留一条日志方便排查。
            NetworkLog.logger.error("读取服务器列表解码失败 error=\(error)")
            cachedProfiles = []
            return []
        }
    }

    /// 编码失败**不**落盘：`defaults.set(nil, forKey:)` 会把该 key 整个删掉，
    /// 静默吞掉 `try?` 等于把已有服务器列表清空。失败只记日志，保留旧数据。
    private func persistUnlocked(_ list: [ServerProfile]) {
        do {
            defaults.set(try JSONEncoder().encode(list), forKey: profilesKey)
            cachedProfiles = list
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

/// 本地 token 仓库。凭据存 `CredentialFileStore`（排除备份的文件），不访问系统钥匙串。
///
/// **为什么从 UserDefaults 搬走**：UserDefaults 落在 App 容器里、会被 iCloud / iTunes
/// 备份原样带走，而它无法单独排除备份。换成可 `isExcludedFromBackup` 的文件后，
/// 访问令牌不再随备份离开设备。Keychain 不是选项：本包 ad-hoc 签名，每次构建
/// cdhash 都变，会带来「开发时每次运行都弹授权框」「重签名后凭据读不出来」
/// 与「CI 无人应答授权」三个问题（详见 `CredentialFileStore` 的类型注释）。
public final class LocalTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let store: CredentialFileStore
    /// 只用于**一次性迁移**旧值；迁移完成即与旧键无关。
    private let legacyDefaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        credentialsDirectory: URL? = nil
    ) {
        self.legacyDefaults = defaults
        // 生产用全局单例（多个域包共用一个文件）；测试传临时目录拿到隔离实例。
        self.store = credentialsDirectory.map { CredentialFileStore(directory: $0) } ?? .shared
    }

    /// 新键（文件内）。不再带 `dev.jumusu.ocplayer.` 前缀——它已经不是 UserDefaults 键了。
    private func key(_ account: String) -> String {
        "jellyfin.token.\(account)"
    }

    /// 旧键（UserDefaults），仅迁移用。
    private func legacyKey(_ account: String) -> String {
        "dev.jumusu.ocplayer.token.\(account)"
    }

    public func read(account: String) -> String? {
        lock.withLock {
            if let token = store.string(forKey: key(account)) { return token }
            // 迁移：老版本把 token 放在 UserDefaults。读到就搬到文件并删旧键，
            // 使凭据从下一次备份起就不再出现（已经进过备份的历史无法追回）。
            guard let legacy = legacyDefaults.string(forKey: legacyKey(account)) else { return nil }
            store.setString(legacy, forKey: key(account))
            legacyDefaults.removeObject(forKey: legacyKey(account))
            return legacy
        }
    }

    public func save(_ token: String, account: String) {
        lock.withLock {
            store.setString(token, forKey: key(account))
            legacyDefaults.removeObject(forKey: legacyKey(account))
        }
    }

    public func delete(account: String) {
        lock.withLock {
            store.removeValue(forKey: key(account))
            legacyDefaults.removeObject(forKey: legacyKey(account))
        }
    }
}
