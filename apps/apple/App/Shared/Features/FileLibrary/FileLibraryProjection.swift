import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit
import OcPlayerCore

/// 文件媒体库的图片 tag 解析。
///
/// 文件库条目的图片来自 `Library.sqlite` 中持久化的 TMDB 路径（无服务器凭证），
/// 用 `"tmdb:"` 前缀装进 `MediaItem` 的既有 imageTag 字段；`DesignSystem` 层的
/// `imageTarget` / `homeStillImageTarget` / `episodeThumbTarget` 识别该前缀后
/// 走 `MirrorSettings.tmdbEndpoints` 生成免鉴权 URL，从而让首页、库页、详情页
/// 与氛围轮播完全复用现有卡片组件，同时在移除 TMDB API Key 后依然离线可读。
enum FileLibraryArtwork {
    static let tagPrefix = "tmdb:"

    static func tag(forPath path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return tagPrefix + path
    }

    static func imageURL(
        forTag tag: String?,
        width: Int,
        preferences: UserDefaults = OcPlayerStorage.defaultPreferences
    ) -> URL? {
        guard let tag, tag.hasPrefix(tagPrefix) else { return nil }
        let path = String(tag.dropFirst(tagPrefix.count))
        guard !path.isEmpty else { return nil }
        let endpoints = MirrorSettings.tmdbEndpoints(
            enabled: preferences.bool(forKey: SettingsKeys.tmdbMirrorEnabled),
            apiRawValue: preferences.string(forKey: SettingsKeys.tmdbMirrorAPIBaseURL) ?? "",
            imageRawValue: preferences.string(forKey: SettingsKeys.tmdbMirrorImageBaseURL) ?? ""
        )
        let size: TMDbImageSize = switch width {
        case ...92: .w92
        case ...154: .w154
        case ...185: .w185
        case ...342: .w342
        case ...500: .w500
        case ...780: .w780
        case ...1280: .w1280
        default: .original
        }
        return TMDbImageSize.url(
            path: path,
            size: size,
            endpoints: endpoints
        )
    }

    static func isFileLibraryTag(_ tag: String?) -> Bool {
        tag?.hasPrefix(tagPrefix) == true
    }
}

/// 将 Core `OcpFileLibrary` 永久记录投影为 App 既有 UI 消费的 `CoreModel` / `TMDbOverlay`。
///
/// 所有字段均只读来自 `Library.sqlite`，绝不写入 `Media.sqlite` 也不伪造 `ServerProfile`。
enum FileLibraryProjection {

    static func sourceKindLabel(_ kind: String) -> String {
        switch kind {
        case "localFolder": "本地文件夹"
        case "webdav": "WebDAV"
        case "smb": "SMB"
        default: "文件媒体库"
        }
    }

    static func mediaLibrary(_ library: OcpFileLibrary.Library) -> MediaLibrary {
        MediaLibrary(
            id: library.libraryId,
            name: library.name,
            collectionType: library.type == .movies ? .movies : .tvshows,
            primaryImageTag: nil
        )
    }

    static func playState(from progress: OcpFileLibrary.Progress) -> MediaItem.PlayState {
        let duration = progress.durationSeconds ?? 0
        let percentage: Double
        if progress.played || progress.completed {
            percentage = 1
        } else if duration > 0 {
            percentage = min(max(progress.positionSeconds / duration, 0), 1)
        } else {
            percentage = 0
        }
        return MediaItem.PlayState(
            played: progress.played || progress.completed,
            percentage: percentage,
            positionSeconds: progress.positionSeconds
        )
    }

    static func mediaItem(
        _ item: OcpFileLibrary.Item,
        progressOverride: OcpFileLibrary.Progress? = nil
    ) -> MediaItem {
        let meta = metadataObject(item.metadata)
        let kind: MediaItem.Kind = switch item.kind {
        case .movie: .movie
        case .series: .series
        case .season: .season
        case .episode: .episode
        case .unidentified: .other
        }
        let effectiveProgress = progressOverride ?? item.progress
        let originalTitle = string(meta, "original_title") ?? string(meta, "original_name")
        let overview = string(meta, "overview")
        let genres = stringArray(meta, "genres")
        let rating = double(meta, "vote_average").flatMap { $0 > 0 ? $0 : nil }
        let contentRating = string(meta, "content_rating")
        let tmdbID = int(meta, "id").flatMap { $0 > 0 ? String($0) : nil }
        let runtimeSeconds: Double? = effectiveProgress?.durationSeconds
            ?? int(meta, "runtime").flatMap { $0 > 0 ? Double($0) * 60 : nil }

        let castMembers = cast(meta)
        let people = castMembers.map {
            MediaItem.Person(
                id: "\(TMDbOverlay.tmdbPersonPrefix)\($0.id)",
                name: $0.name,
                role: $0.character,
                kind: "Actor"
            )
        }

        let primaryPath: String?
        let backdropPath: String?
        let thumbPath: String?
        switch item.kind {
        case .movie, .series:
            primaryPath = string(meta, "poster_path")
            backdropPath = string(meta, "backdrop_path")
            thumbPath = nil
        case .season:
            primaryPath = string(meta, "poster_path")
            backdropPath = nil
            thumbPath = nil
        case .episode:
            primaryPath = nil
            backdropPath = nil
            thumbPath = string(meta, "still_path")
        case .unidentified:
            primaryPath = nil
            backdropPath = nil
            thumbPath = nil
        }

        let displayName: String
        if item.kind == .season, item.title.hasPrefix("Season "), let number = item.seasonNumber {
            displayName = number == 0 ? "特别篇" : "第 \(number) 季"
        } else {
            displayName = item.title
        }

        return MediaItem(
            id: item.itemId,
            name: displayName,
            originalTitle: originalTitle,
            kind: kind,
            overview: overview,
            year: item.year,
            runtimeSeconds: runtimeSeconds,
            genres: genres,
            communityRating: rating,
            officialRating: contentRating,
            seriesID: item.seriesId,
            seriesName: item.seriesTitle,
            seasonID: item.kind == .episode ? item.parentId : nil,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            playState: effectiveProgress.map(playState(from:)),
            cast: people,
            childCount: item.childCount,
            primaryImageTag: FileLibraryArtwork.tag(forPath: primaryPath),
            primaryImageAspectRatio: nil,
            thumbImageTag: FileLibraryArtwork.tag(forPath: thumbPath),
            backdropImageTag: FileLibraryArtwork.tag(forPath: backdropPath),
            parentBackdropItemID: item.kind == .episode ? item.seriesId : nil,
            parentBackdropImageTag: item.kind == .episode ? FileLibraryArtwork.tag(forPath: item.seriesBackdropPath) : nil,
            seriesPrimaryImageTag: item.kind == .episode ? FileLibraryArtwork.tag(forPath: item.seriesPosterPath) : nil,
            tmdbID: tmdbID
        )
    }

    /// 从 `Library.sqlite` 持久化的 TMDB 元数据构造只读 `TMDbOverlay`。
    /// 供详情页展示演员头像、季简介、分集剧照与未拥有分集占位，不依赖 API Key。
    static func tmdbOverlay(for item: OcpFileLibrary.Item, seriesTMDbID: Int? = nil) -> TMDbOverlay? {
        guard let meta = metadataObject(item.metadata) else { return nil }
        switch item.kind {
        case .movie:
            guard let id = int(meta, "id"), id > 0 else { return nil }
            return TMDbOverlay(
                source: .manual,
                confidence: 1,
                entityKey: .movie(id),
                title: string(meta, "title"),
                overview: string(meta, "overview"),
                genres: stringArray(meta, "genres"),
                communityRating: double(meta, "vote_average").flatMap { $0 > 0 ? $0 : nil },
                contentRating: string(meta, "content_rating"),
                cast: cast(meta),
                imdbID: string(meta, "imdb_id"),
                posterPath: string(meta, "poster_path"),
                backdropPath: string(meta, "backdrop_path")
            )
        case .series:
            guard let id = int(meta, "id"), id > 0 else { return nil }
            return TMDbOverlay(
                source: .manual,
                confidence: 1,
                entityKey: .tv(id),
                title: string(meta, "name") ?? string(meta, "title"),
                overview: string(meta, "overview"),
                genres: stringArray(meta, "genres"),
                communityRating: double(meta, "vote_average").flatMap { $0 > 0 ? $0 : nil },
                contentRating: string(meta, "content_rating"),
                cast: cast(meta),
                imdbID: string(meta, "imdb_id"),
                posterPath: string(meta, "poster_path"),
                backdropPath: string(meta, "backdrop_path")
            )
        case .season:
            guard let seasonNumber = item.seasonNumber ?? int(meta, "season_number") else { return nil }
            let tvID = seriesTMDbID ?? 0
            return TMDbOverlay(
                source: .manual,
                confidence: 1,
                entityKey: .season(tvID: tvID, number: seasonNumber),
                title: string(meta, "name"),
                overview: string(meta, "overview"),
                posterPath: string(meta, "poster_path"),
                episodes: episodes(meta)
            )
        case .episode, .unidentified:
            return nil
        }
    }

    static func sortKey(for field: MediaItemsSortField) -> String {
        switch field {
        case .name: "name"
        case .dateAdded: "dateAdded"
        case .year: "year"
        case .rating: "rating"
        case .runtime, .random: "name"
        }
    }

    static func watchStateKey(for state: MediaItemsWatchState) -> String {
        switch state {
        case .all: "all"
        case .unwatched: "unplayed"
        case .watched: "played"
        }
    }

    // MARK: - JSONValue 抽取

    private static func metadataObject(_ value: OcPlayerCore.JSONValue?) -> [String: OcPlayerCore.JSONValue]? {
        guard case let .object(dict) = value else { return nil }
        return dict
    }

    private static func string(_ dict: [String: OcPlayerCore.JSONValue]?, _ key: String) -> String? {
        guard let value = dict?[key], case let .string(text) = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ dict: [String: OcPlayerCore.JSONValue]?, _ key: String) -> Double? {
        guard let value = dict?[key], case let .number(number) = value, number.isFinite else { return nil }
        return number
    }

    private static func int(_ dict: [String: OcPlayerCore.JSONValue]?, _ key: String) -> Int? {
        guard let number = double(dict, key) else { return nil }
        return Int(number)
    }

    private static func stringArray(_ dict: [String: OcPlayerCore.JSONValue]?, _ key: String) -> [String] {
        guard let value = dict?[key], case let .array(elements) = value else { return [] }
        return elements.compactMap {
            guard case let .string(text) = $0 else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func cast(_ dict: [String: OcPlayerCore.JSONValue]?) -> [CastMember] {
        guard let value = dict?["cast"], case let .array(elements) = value else { return [] }
        return elements.compactMap { element in
            guard case let .object(obj) = element,
                  let id = int(obj, "id"),
                  let name = string(obj, "name") else { return nil }
            return CastMember(
                id: id,
                name: name,
                character: string(obj, "character"),
                profilePath: string(obj, "profile_path")
            )
        }
    }

    private static func episodes(_ dict: [String: OcPlayerCore.JSONValue]?) -> [EpisodeEntry] {
        guard let value = dict?["episodes"], case let .array(elements) = value else { return [] }
        return elements.compactMap { element in
            guard case let .object(obj) = element,
                  let number = int(obj, "episode_number") else { return nil }
            return EpisodeEntry(
                episodeNumber: number,
                name: string(obj, "name"),
                overview: string(obj, "overview"),
                stillPath: string(obj, "still_path"),
                airDate: string(obj, "air_date"),
                runtime: int(obj, "runtime"),
                voteAverage: double(obj, "vote_average")
            )
        }
    }
}
