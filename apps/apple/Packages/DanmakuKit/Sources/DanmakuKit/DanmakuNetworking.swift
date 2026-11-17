import Foundation

/// 弹幕网络会话工厂：统一超时配置，避免慢网关让匹配阶段长时间停留在无反馈状态。
/// 匹配参数与正文都走这条会话；本地文件哈希不经过网络。
public enum DanmakuNetworking {
    /// 单请求 15 秒无响应即失败，整条资源 30 秒上限。ephemeral 不落磁盘缓存。
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }
}
