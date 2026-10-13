import Foundation

public extension ServerProfile {

    /// 条目图片地址，**不需要活会话**。
    ///
    /// ## 为什么需要它
    ///
    /// 登录页要铺一面「你自己媒体库」的海报墙，而那时**还没有会话**——只有服务器
    /// 档案。墙上的图全部来自本机图片缓存，而缓存键里含 URL 的路径与查询
    /// （`ImageCacheKey` 抹掉 host、保留 path+query），所以必须能把当初那条 URL
    /// 逐字节复原出来，否则缓存一条都命中不了。
    ///
    /// ## 形状必须与在线路径一致
    ///
    /// 拼法与 `EmbyServer.imageURL` / `JellyfinServer.imageURL` 相同：
    /// 路径 `/Items/{id}/Images/{Type}`，查询 `maxWidth` 在前、`tag` 在后，
    /// 与 `EmbySession` 共用 `ServerURLBuilder`。这条形状是**实测确认**过的
    /// （对着本机 746 个图片缓存文件逐个复原键：47 个有主图的条目全部命中），
    /// `ServerProfileImageURLTests` 把它钉成黄金值，改动形状会让测试直接失败。
    ///
    /// - Note: 返回 `nil` = 档案地址畸形。调用方按「这张没有海报」处理。
    func imageURL(
        itemID: String,
        type: ItemImageType = .primary,
        maxWidth: Int? = nil,
        tag: String? = nil
    ) -> URL? {
        var query: [(String, String)] = []
        if let maxWidth { query.append(("maxWidth", String(maxWidth))) }
        if let tag { query.append(("tag", tag)) }
        return ServerURLBuilder.url(
            base: baseURL,
            path: "/Items/\(itemID)/Images/\(type.rawValue)",
            query: query
        )
    }
}
