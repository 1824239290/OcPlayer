import CoreModel
import Foundation
import JellyfinAPI

// MARK: - BaseItemDto → MediaItem

extension MediaItem.Kind {
    init(_ kind: BaseItemKind?) {
        switch kind {
        case .movie: self = .movie
        case .series: self = .series
        case .season: self = .season
        case .episode: self = .episode
        case .boxSet: self = .boxSet
        case .musicAlbum: self = .musicAlbum
        case .musicArtist: self = .musicArtist
        case .audio: self = .audio
        case .book: self = .book
        case .photo: self = .photo
        case .playlist: self = .playlist
        case .folder, .collectionFolder, .aggregateFolder,
             .basePluginFolder, .manualPlaylistsFolder, .playlistsFolder:
            self = .folder
        default: self = .other
        }
    }
}

extension BaseItemKind {
    /// 反向映射（请求参数用）；`.folder` / `.other` 这类没有对应 wire 值的返回 nil。
    init? (_ kind: MediaItem.Kind) {
        switch kind {
        case .movie: self = .movie
        case .series: self = .series
        case .season: self = .season
        case .episode: self = .episode
        case .boxSet: self = .boxSet
        case .musicAlbum: self = .musicAlbum
        case .musicArtist: self = .musicArtist
        case .audio: self = .audio
        case .book: self = .book
        case .photo: self = .photo
        case .playlist: self = .playlist
        case .folder, .other: return nil
        }
    }
}

extension MediaLibrary.CollectionType {
    init(_ raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .unknown
    }
}

/// Jellyfin tick（100 ns）→ 秒。
/// 确定性短哈希（缺失 id 的派生用，只要求跨进程稳定，不要求密码学强度）。
private func stableHash(_ part: String?, _ kind: BaseItemKind?) -> String {
    var hasher = Hasher()
    hasher.combine(part)
    hasher.combine(kind?.rawValue)
    return String(hasher.finalize())
}

func seconds(fromTicks ticks: Int?) -> Double? {
    ticks.map { Double($0) / 10_000_000 }
}

extension UserItemDataDto {
    /// 标记已看/取消已看等接口返回的用户数据 → 域模型播放状态。
    var domainPlayState: MediaItem.PlayState {
        MediaItem.PlayState(
            played: isPlayed ?? false,
            percentage: (playedPercentage ?? 0) / 100,
            positionSeconds: seconds(fromTicks: playbackPositionTicks) ?? 0,
            unplayedCount: unplayedItemCount
        )
    }
}

extension BaseItemDto {
    var domainItem: MediaItem {
        // 首图 / 背景图的 tag：进 URL 让「图片换了 → URL 变了 → 缓存自动失效」。
        // SeriesPrimaryImageTag / AlbumPrimaryImageTag 是父级回退图，不能写进
        // 分集自己的 primary tag，否则每一集都会把同一张父级海报当成自己的图。
        let primaryTag: String?
        if type == .episode {
            primaryTag = imageTags?["Primary"]
        } else {
            primaryTag = imageTags?["Primary"] ?? albumPrimaryImageTag ?? seriesPrimaryImageTag
        }
        let thumbTag = imageTags?["Thumb"]
        let backdropTag = backdropImageTags?.first
        let logoTag = imageTags?["Logo"] ?? parentLogoImageTag

        // Episode：parentIndexNumber = 季号，indexNumber = 集号。
        // Season：indexNumber = 季号（0 多为特典/SP），parentIndexNumber 一般是剧 id 侧字段，不能当季号。
        let mappedSeasonNumber: Int?
        let mappedEpisodeNumber: Int?
        switch type {
        case .season:
            mappedSeasonNumber = indexNumber
            mappedEpisodeNumber = nil
        case .episode:
            mappedSeasonNumber = parentIndexNumber
            mappedEpisodeNumber = indexNumber
        default:
            mappedSeasonNumber = parentIndexNumber
            mappedEpisodeNumber = indexNumber
        }

        // id 缺失时兜底 UUID() 每次解析都会生成新 id——同一个条目两次拉取
        // 身份不同，SwiftUI 当成不同条目闪烁重排。改用「确定性派生 id」：
        // 名称+类型哈希，同一缺失条目跨拉取稳定（服务器本不该漏 id，这是兜底）。
        let resolvedID = id ?? "missing-\(stableHash(name ?? "unnamed", type))"
        return MediaItem(
            id: resolvedID,
            name: name ?? "未命名",
            kind: MediaItem.Kind(type),
            overview: overview,
            year: productionYear,
            runtimeSeconds: seconds(fromTicks: runTimeTicks),
            genres: genres ?? [],
            communityRating: communityRating.map(Double.init),
            officialRating: officialRating,
            seriesID: seriesID,
            seriesName: seriesName,
            seasonID: type == .season ? resolvedID : seasonID,
            seasonName: type == .season ? name : seasonName,
            seasonNumber: mappedSeasonNumber,
            episodeNumber: mappedEpisodeNumber,
            playState: userData.map {
                MediaItem.PlayState(
                    played: $0.isPlayed ?? false,
                    // Jellyfin 的 PlayedPercentage 是 0–100 的百分数；域模型统一存 0–1 比例。
                    percentage: ($0.playedPercentage ?? 0) / 100,
                    positionSeconds: seconds(fromTicks: $0.playbackPositionTicks) ?? 0,
                    unplayedCount: $0.unplayedItemCount
                )
            },
            cast: (people ?? []).compactMap { person in
                guard let id = person.id, let name = person.name else { return nil }
                return MediaItem.Person(
                    id: id,
                    name: name,
                    role: person.role,
                    kind: person.type?.rawValue ?? "Actor"
                )
            },
            childCount: childCount,
            primaryImageTag: primaryTag,
            thumbImageTag: thumbTag,
            backdropImageTag: backdropTag,
            logoImageTag: logoTag,
            parentLogoItemID: parentLogoItemID,
            tmdbID: providerIDs?["Tmdb"] ?? providerIDs?["tmdb"]
        )
    }
}
