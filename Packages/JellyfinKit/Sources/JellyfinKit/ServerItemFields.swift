import CoreModel
import DiagnosticsKit
import Foundation

/// 服务端条目 DTO 与域模型 `MediaItem` 之间的中间表示。
///
/// Jellyfin SDK 的 `BaseItemDto` 和 Emby 的裸 JSON DTO 各自填一份，下游的映射
/// 逻辑只存在这一处 —— 季/集号语义、父级图回退规则、缺 id 时的确定性派生都是
/// 容易踩坑的地方，重复一份就等于下一个修复要打两遍。
struct ServerItemFields {
    /// 服务端原始 `Type` 串（Jellyfin "Movie" / Emby 同样）。**只**用于缺 id
    /// 时的确定性派生：它进了哈希，改格式会让既有派生 id 全部漂移。
    var kindTag: String?
    var id: String?
    var name: String?
    var kind: MediaItem.Kind = .other
    var overview: String?
    var productionYear: Int?
    var runtimeTicks: Int?
    var genres: [String] = []
    var communityRating: Double?
    var officialRating: String?
    var seriesID: String?
    var seriesName: String?
    var seasonID: String?
    var seasonName: String?
    var parentIndexNumber: Int?
    var indexNumber: Int?
    var playState: MediaItem.PlayState?
    var cast: [MediaItem.Person] = []
    var childCount: Int?
    var imageTags: [String: String] = [:]
    var backdropImageTags: [String] = []
    var albumPrimaryImageTag: String?
    var seriesPrimaryImageTag: String?
    var parentLogoImageTag: String?
    var parentLogoItemID: String?
    var providerIDs: [String: String] = [:]

    var domainItem: MediaItem {
        // 首图 / 背景图的 tag：进 URL 让「图片换了 → URL 变了 → 缓存自动失效」。
        // SeriesPrimaryImageTag / AlbumPrimaryImageTag 是父级回退图，不能写进
        // 分集自己的 primary tag，否则每一集都会把同一张父级海报当成自己的图。
        let primaryTag: String?
        if kind == .episode {
            primaryTag = imageTags["Primary"]
        } else {
            primaryTag = imageTags["Primary"] ?? albumPrimaryImageTag ?? seriesPrimaryImageTag
        }
        let thumbTag = imageTags["Thumb"]
        let backdropTag = backdropImageTags.first
        let logoTag = imageTags["Logo"] ?? parentLogoImageTag

        // Episode：parentIndexNumber = 季号，indexNumber = 集号。
        // Season：indexNumber = 季号（0 多为特典/SP），parentIndexNumber 一般是剧 id 侧字段，不能当季号。
        let mappedSeasonNumber: Int?
        let mappedEpisodeNumber: Int?
        switch kind {
        case .season:
            mappedSeasonNumber = indexNumber
            mappedEpisodeNumber = nil
        default:
            mappedSeasonNumber = parentIndexNumber
            mappedEpisodeNumber = indexNumber
        }

        // id 缺失时兜底 UUID() 每次解析都会生成新 id——同一个条目两次拉取
        // 身份不同，SwiftUI 当成不同条目闪烁重排。改用「确定性派生 id」：
        // 名称+类型哈希，同一缺失条目跨拉取稳定（服务器本不该漏 id，这是兜底）。
        let resolvedID = id ?? "missing-\(Self.stableHash(name ?? "unnamed", kindTag))"
        return MediaItem(
            id: resolvedID,
            name: name ?? "未命名",
            kind: kind,
            overview: overview,
            year: productionYear,
            runtimeSeconds: seconds(fromTicks: runtimeTicks),
            genres: genres,
            communityRating: communityRating,
            officialRating: officialRating,
            seriesID: seriesID,
            seriesName: seriesName,
            seasonID: kind == .season ? resolvedID : seasonID,
            seasonName: kind == .season ? name : seasonName,
            seasonNumber: mappedSeasonNumber,
            episodeNumber: mappedEpisodeNumber,
            playState: playState,
            cast: cast,
            childCount: childCount,
            primaryImageTag: primaryTag,
            thumbImageTag: thumbTag,
            backdropImageTag: backdropTag,
            logoImageTag: logoTag,
            parentLogoItemID: parentLogoItemID,
            tmdbID: providerIDs["Tmdb"] ?? providerIDs["tmdb"],
            // MAL 的 provider key 各版本不统一（Mal / MyAnimeList），多兜几个。
            malID: providerIDs["Mal"] ?? providerIDs["MyAnimeList"] ?? providerIDs["mal"],
            anilistID: providerIDs["AniList"] ?? providerIDs["anilist"]
        )
    }

    /// 确定性短哈希（缺失 id 的派生用）。**必须跨进程 / 跨启动稳定**：
    /// `Hasher()` 每进程随机播种，同一个条目的派生 id 每次冷启动都不一样
    /// （review-20260914 P3-3）。FNV-1a 实现共享在 `DiagnosticsKit.FNV1a`。
    private static func stableHash(_ part: String?, _ kind: String?) -> String {
        var hasher = FNV1a()
        hasher.feed("part:\(part ?? "")")
        hasher.feed("kind:\(kind ?? "")")
        return hasher.finishHex()
    }
}

/// Jellyfin tick（100 ns）→ 秒。
func seconds(fromTicks ticks: Int?) -> Double? {
    ticks.map { Double($0) / 10_000_000 }
}
