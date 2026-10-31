import Foundation

/// 媒体搜索结果（`/media/search`）的**展示排序**。
///
/// ## 为什么需要它
///
/// `searchMedia` 是**多源聚合**（tmdb / douban / bangumi…），返回顺序由服务端
/// `SEARCH_SOURCE` 配置决定——同一个片名可能同时回来 TMDB 与 Douban 两条，而
/// Douban 那条在前。挑到 Douban 条目时对象里没有 `tmdb_id`，它会被原样回传成
/// `/download/` 的 `media_in`，MoviePilot 下载后的自动刮削就缺编号。
///
/// 所以这里只做一件事：**把更可能带 `tmdb_id` 的条目排到前面**，让用户顺手挑到
/// 对的来源。它不改变任何条目内容、不做过滤、不替用户选择——每一条仍是服务端
/// 返回的完整对象。
///
/// - Note: 早期版本还带「与条目的 TMDB 编号 / 年份 / 类型匹配」的打分与
///   `recommended(...)` 推荐接口，那些是给一个「选源面板」用的；面板取消后
///   （详情页改为直接跳 MoviePilot 搜索页）调用点只剩下自由文本搜索，
///   **根本拿不到年份或条目编号**（见 `MoviePilotHomeView.search()`），
///   那几个参数与推荐接口全部无从调用，已随面板一起删掉。
public enum MoviePilotMediaRanking {

    // MARK: - 打分权重

    /// TMDB 源：MoviePilot 的刮削链路以 `tmdb_id` 为锚点，天然最稳。
    public static let tmdbSourceBonus = 100
    /// 对象里带 `tmdb_id`（个别其它源的适配器会补齐）。
    public static let hasTMDBIDBonus = 10

    // MARK: - 排序

    /// 按「更可能有 TMDB 编号」的程度排序，同分保持服务端原序。
    public static func sortedForDisplay(_ results: [MPMediaInfo]) -> [MPMediaInfo] {
        // 同分按原序：`sorted` 不保证稳定，所以显式带上下标。
        var scored: [(offset: Int, media: MPMediaInfo, score: Int)] = []
        scored.reserveCapacity(results.count)
        for (offset, media) in results.enumerated() {
            scored.append((offset, media, score(media)))
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.offset < rhs.offset : lhs.score > rhs.score
        }
        return scored.map(\.media)
    }

    static func score(_ media: MPMediaInfo) -> Int {
        var score = 0
        if media.mediaSource?.lowercased() == "tmdb" { score += tmdbSourceBonus }
        if media.tmdbId != nil { score += hasTMDBIDBonus }
        return score
    }
}
