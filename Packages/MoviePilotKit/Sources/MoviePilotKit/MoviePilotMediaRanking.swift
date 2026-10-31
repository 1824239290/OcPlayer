import Foundation

/// 媒体搜索结果（`/media/search`）的候选排序与推荐。
///
/// ## 为什么需要它
///
/// `searchMedia` 是**多源聚合**（tmdb / douban / bangumi…，顺序跟服务端
/// `SEARCH_SOURCE` 配置走），同一个片名可能同时回来 TMDB 与 Douban 两条。
/// 客户端一旦「挑第一条就走」，选中的到底是哪一家完全取决于服务端配置：
/// 挑到 Douban 条目时对象里没有 `tmdb_id`，回传给 `/download/` 的 `media_in`
/// 也就没有 TMDB 编号 —— MoviePilot 下载完成后按 `media_info` 去刮削、改名、
/// 入库，缺编号就只能靠文件名猜，刮削会缺字段甚至认错条目。
///
/// 所以这里只做**排序与推荐**，不做自动采用：详情页拿到排序后的候选交给用户
/// 手动选，选完才是那个「原样回传」的完整对象。
public enum MoviePilotMediaRanking {

    /// 一条候选：原始条目 + 打分 + 是否推荐。
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let media: MPMediaInfo
        public let score: Int

        /// 用 `media.id` 做身份：与搜索结果页的 `ForEach` 同一口径。
        public var id: String { media.id }

        /// 是否值得打「推荐」标记（也是面板的默认预选）。
        public var isRecommended: Bool { score >= MoviePilotMediaRanking.recommendationThreshold }

        /// 没有 TMDB 编号：下载后 MoviePilot 的自动刮削可能缺字段。
        public var isMissingTMDBID: Bool { media.tmdbId == nil }

        /// 一行式来源说明（面板里的「来源 TMDB · 编号 123」），口径见
        /// `MPMediaInfo.sourceSummary`。
        public var sourceSummary: String { media.sourceSummary }
    }

    // MARK: - 打分权重

    /// 与条目自带 TMDB 编号完全一致：可以认为就是同一条目。
    public static let tmdbIDMatchBonus = 1000
    /// TMDB 源：MoviePilot 的刮削链路以 `tmdb_id` 为锚点，天然最稳。
    public static let tmdbSourceBonus = 100
    /// 年份吻合：同名不同年版（剧集 / 电影重拍）的主要区分手段。
    public static let yearMatchBonus = 30
    /// 对象里带 `tmdb_id`（哪怕来自 Douban 等其它源的适配器补齐）。
    public static let hasTMDBIDBonus = 10
    /// 类型吻合（电影 / 电视剧）。
    public static let typeMatchBonus = 5
    /// 达到这个分数才算「推荐」：只有 TMDB 源或编号命中才够，单单年份吻合不算。
    public static let recommendationThreshold = tmdbSourceBonus

    // MARK: - 排序

    /// 按与条目的匹配度排序候选，同分保持服务端原序。
    ///
    /// - Parameters:
    ///   - results: `/media/search` 的原始返回。
    ///   - year: 条目的年份（`MediaItem.year`）。
    ///   - tmdbID: 条目在媒体库里记下的 TMDB 编号（`MediaItem.tmdbID`）。
    ///   - type: 条目在 MoviePilot 口径下的类型文案（"电影" / "电视剧"）。
    public static func candidates(
        _ results: [MPMediaInfo],
        year: Int? = nil,
        tmdbID: String? = nil,
        type: String? = nil
    ) -> [Candidate] {
        let expectedTmdbID = tmdbID.flatMap { Int($0.prefix(while: \.isNumber)) }
        // 拆成三步写：链式 `map` 里现造 `Candidate` 会让类型检查超时（实测）。
        var scored: [(offset: Int, candidate: Candidate)] = []
        scored.reserveCapacity(results.count)
        for (offset, media) in results.enumerated() {
            let value = score(media, expectedTmdbID: expectedTmdbID, year: year, type: type)
            scored.append((offset, Candidate(media: media, score: value)))
        }
        // 同分按原序：`sorted` 不保证稳定，所以显式带上下标。
        scored.sort { lhs, rhs in
            lhs.candidate.score == rhs.candidate.score
                ? lhs.offset < rhs.offset
                : lhs.candidate.score > rhs.candidate.score
        }
        return scored.map(\.candidate)
    }

    /// 排序后第一顺位的推荐条目；没有够格的（全都不带 TMDB 编号又没年份信号）就是 nil，
    /// 面板此时只预选不标记，把选择权留给用户。
    public static func recommended(
        _ results: [MPMediaInfo],
        year: Int? = nil,
        tmdbID: String? = nil,
        type: String? = nil
    ) -> MPMediaInfo? {
        candidates(results, year: year, tmdbID: tmdbID, type: type)
            .first(where: \.isRecommended)?
            .media
    }

    // MARK: - 明细

    static func score(
        _ media: MPMediaInfo,
        expectedTmdbID: Int?,
        year: Int?,
        type: String?
    ) -> Int {
        var score = 0
        if let expectedTmdbID, media.tmdbId == expectedTmdbID { score += tmdbIDMatchBonus }
        if media.mediaSource?.lowercased() == "tmdb" { score += tmdbSourceBonus }
        if let year, Self.year(of: media) == year { score += yearMatchBonus }
        if media.tmdbId != nil { score += hasTMDBIDBonus }
        if let type, media.type == type { score += typeMatchBonus }
        return score
    }

    /// 条目年份：优先 `title_year`，回落到 `year`；两种都可能带月日，只取前四位。
    static func year(of media: MPMediaInfo) -> Int? {
        guard let text = media.titleYear ?? media.year else { return nil }
        return Int(text.prefix(while: \.isNumber).prefix(4))
    }
}
