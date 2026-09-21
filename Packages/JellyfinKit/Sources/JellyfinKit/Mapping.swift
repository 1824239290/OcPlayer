import CoreModel
import Foundation
import JellyfinAPI

// MARK: - BaseItemDto → MediaItem

extension MediaItem.Kind {
    /// 服务端 `Type` 串 → 域模型。Jellyfin 的 `BaseItemKind.rawValue` 与 Emby 的
    /// wire 串是同一套值，所以两家共用这一张表（避免两份会各自漂移的映射）。
    /// **认不出的一律 `.other`** —— Emby 会多出 CollectionFolder 等 Jellyfin 没有的值。
    init(serverTypeString raw: String?) {
        switch raw {
        case "Movie": self = .movie
        case "Series": self = .series
        case "Season": self = .season
        case "Episode": self = .episode
        case "BoxSet": self = .boxSet
        case "MusicAlbum": self = .musicAlbum
        case "MusicArtist": self = .musicArtist
        case "Audio": self = .audio
        case "Book": self = .book
        case "Photo": self = .photo
        case "Playlist": self = .playlist
        case "Folder", "CollectionFolder", "AggregateFolder", "BasePluginFolder",
             "ManualPlaylistsFolder", "PlaylistsFolder":
            self = .folder
        default: self = .other
        }
    }

    init(_ kind: BaseItemKind?) {
        self.init(serverTypeString: kind?.rawValue)
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
    /// 服务端 `CollectionType` 串 → 域模型。**大小写不敏感**：Emby 会发
    /// "BoxSets" 这类大小写变体，Jellyfin 发全小写。认不出的落到 `.unknown`
    /// （浏览层会据此过滤掉，如 Emby 的 "mixed"）。
    init(_ raw: String?) {
        self = raw.flatMap { Self(rawValue: $0.lowercased()) } ?? .unknown
    }
}

extension MediaItem.PlayState {
    /// 两家服务端的 `UserData` 字段同名同义（`IsPlayed` / `PlayedPercentage` /
    /// `PlaybackPositionTicks` / `UnplayedItemCount`），换算规则只写这一处 ——
    /// 百分数 ÷100 这条口径重复一份就是下一个 bug 要打两遍。
    init(played: Bool?, playedPercentage: Double?, playbackPositionTicks: Int?, unplayedItemCount: Int?) {
        self.init(
            played: played ?? false,
            // PlayedPercentage 是 0–100 的百分数；域模型统一存 0–1 比例。
            percentage: (playedPercentage ?? 0) / 100,
            positionSeconds: seconds(fromTicks: playbackPositionTicks) ?? 0,
            unplayedCount: unplayedItemCount
        )
    }
}

extension UserItemDataDto {
    /// 标记已看/取消已看等接口返回的用户数据 → 域模型播放状态。
    /// 列表响应里的 `UserData` 也走这一份（字段与语义完全相同）。
    var domainPlayState: MediaItem.PlayState {
        MediaItem.PlayState(
            played: isPlayed,
            playedPercentage: playedPercentage,
            playbackPositionTicks: playbackPositionTicks,
            unplayedItemCount: unplayedItemCount
        )
    }
}

extension BaseItemDto {
    /// Jellyfin SDK DTO → 共享中间表示。Emby 侧由 `EmbyItemDTO` 填同一份结构，
    /// 映射逻辑（季/集号、父级图回退、缺 id 派生）只存在于 `ServerItemFields`。
    var serverFields: ServerItemFields {
        var fields = ServerItemFields()
        fields.kindTag = type?.rawValue
        fields.id = id
        fields.name = name
        fields.kind = MediaItem.Kind(type)
        fields.overview = overview
        fields.productionYear = productionYear
        fields.runtimeTicks = runTimeTicks
        fields.genres = genres ?? []
        fields.communityRating = communityRating.map(Double.init)
        fields.officialRating = officialRating
        fields.seriesID = seriesID
        fields.seriesName = seriesName
        fields.seasonID = seasonID
        fields.seasonName = seasonName
        fields.parentIndexNumber = parentIndexNumber
        fields.indexNumber = indexNumber
        fields.playState = userData?.domainPlayState
        fields.cast = (people ?? []).compactMap { person in
            guard let id = person.id, let name = person.name else { return nil }
            return MediaItem.Person(
                id: id,
                name: name,
                role: person.role,
                kind: person.type?.rawValue ?? "Actor"
            )
        }
        fields.childCount = childCount
        fields.imageTags = imageTags ?? [:]
        fields.backdropImageTags = backdropImageTags ?? []
        fields.albumPrimaryImageTag = albumPrimaryImageTag
        fields.seriesPrimaryImageTag = seriesPrimaryImageTag
        fields.parentLogoImageTag = parentLogoImageTag
        fields.parentLogoItemID = parentLogoItemID
        fields.providerIDs = providerIDs ?? [:]
        return fields
    }

    var domainItem: MediaItem { serverFields.domainItem }
}
