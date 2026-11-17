import Foundation

/// 按档案的产品类型造出对应实现。
///
/// 这是「两家分家」唯一的汇聚点：App 层只认 `any MediaServer`，不关心背后是
/// Jellyfin 还是 Emby。构造参数两家同形，差别只在类型。
public enum MediaServerFactory {

    /// 按指定档案恢复会话（多服务器切换用）。token 缺失时返回 nil，
    /// 由调用方决定回落到登录流程。
    public static func resume(
        profile: ServerProfile,
        from store: ServerStore,
        sessionConfiguration: URLSessionConfiguration = .default
    ) -> (any MediaServer)? {
        switch profile.kind {
        case .jellyfin:
            return JellyfinServer.resume(
                profile: profile,
                from: store,
                sessionConfiguration: sessionConfiguration
            )
        case .emby:
            return EmbyServer.resume(
                profile: profile,
                from: store,
                sessionConfiguration: sessionConfiguration
            )
        }
    }

    /// 启动时恢复会话。
    ///
    /// 优先恢复用户指定的启动默认服务器（`launchProfile`）；它没有 token 时
    /// 回退到列表里第一个有 token 的档案（登出 A 后 A 仍是 current，但 B 的
    /// token 还有效——这时应该直接进 B 而不是弹登录页）。
    public static func restore(from store: ServerStore) -> (any MediaServer)? {
        let preferred = store.launchProfile
        let profile = preferred.flatMap { store.token(for: $0) != nil ? $0 : nil }
            ?? store.profiles.first { store.token(for: $0) != nil }
        guard let profile else { return nil }
        return resume(profile: profile, from: store)
    }
}
