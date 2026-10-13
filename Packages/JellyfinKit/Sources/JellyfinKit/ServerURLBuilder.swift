import Foundation

/// 把路径与查询项拼到一个服务器地址之后。
///
/// `baseURL` 可能带子路径（Emby 档案是 `/emby`），所以拼在它**后面**而不是覆盖它
/// —— 一处前缀，全链路生效。
///
/// ## 为什么把它从 `EmbySession` 里提出来
///
/// 登录页的海报墙要在**没有会话**的情况下复原历史图片 URL：墙只读本机图片缓存，
/// 而缓存键里含 URL 的路径与查询（`ImageCacheKey` 抹掉 host、保留 path+query），
/// 所以拼出来的 URL 必须与当初存进缓存的那一条**逐字节一致**。
/// 两处各写一份拼接逻辑，迟早会因为一个尾斜杠或查询项顺序而悄悄错开——那时墙只是
/// 变空，不报错，最难查。这里做成唯一实现，`EmbySession` 也走它。
public enum ServerURLBuilder {
    /// 拼绝对地址；`components.url` 失败（地址畸形）时返回 nil，由调用方决定报什么错。
    public static func url(base: URL, path: String, query: [(String, String)] = []) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            // 用数组而不是字典：`includeItemTypes=Movie,Series` 这类同名多值要保序。
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url
    }
}
