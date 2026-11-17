import Foundation

/// 登录页只复原本档案在 v2 服务器上下文中记下的身份。旧键和全局身份池无法确认
/// 服务器/账号归属，因此不迁移；旧字节保留，由缓存正常淘汰，新会话重新下载。
@MainActor
enum ImageCacheIdentityStore {
    static let historyLimit = 8
    static let prefix = "dev.jumusu.ocplayer.imageCacheIdentity.v2."

    static func remember(identity: String, tenant: String) {
        guard identity.hasPrefix("v2-"), !tenant.isEmpty else { return }
        var list = history(for: tenant)
        list.removeAll { $0 == identity }
        list.insert(identity, at: 0)
        UserDefaults.standard.set(Array(list.prefix(historyLimit)), forKey: prefix + tenant)
    }

    static func identities(for tenant: String) async -> [String] {
        history(for: tenant)
    }

    static func identity(for tenant: String) -> String? {
        history(for: tenant).first
    }

    static func history(for tenant: String) -> [String] {
        guard !tenant.isEmpty else { return [] }
        return (UserDefaults.standard.stringArray(forKey: prefix + tenant) ?? [])
            .filter { $0.hasPrefix("v2-") }
    }
}
