import CoreModel
import Foundation
import JellyfinKit

/// 一份媒体数据来自哪里。视图据此区分「立即可用的旧内容」与「网络刚确认的内容」。
public enum MediaDataSource: String, Sendable, Equatable {
    case memory
    case disk
    case network
}

/// 带新鲜度与来源的媒体快照。缓存不再各自定义一套时间戳含义。
public struct MediaSnapshot<Value: Sendable>: Sendable {
    public var value: Value
    public var fetchedAt: Date
    public var source: MediaDataSource

    public init(value: Value, fetchedAt: Date, source: MediaDataSource) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return RustMediaRepository.freshness("snapshot", age: age, ttl: ttl, source: source)
            ?? (source != .disk && age < ttl)
    }

    public func replacingSource(_ source: MediaDataSource) -> Self {
        .init(value: value, fetchedAt: fetchedAt, source: source)
    }
}

/// 取数失败的统一投影。取消不进入这个类型——取消是控制流，不是页面错误。
public struct MediaFailure: Sendable, Equatable {
    public var message: String
    public var isConnectivity: Bool

    public init(message: String, isConnectivity: Bool) {
        self.message = message
        self.isConnectivity = isConnectivity
    }

    public init(_ error: any Error) {
        if let jellyfin = error as? JellyfinError {
            message = jellyfin.errorDescription ?? "\(jellyfin)"
            switch jellyfin.kind {
            case .noNetwork, .serverUnreachable:
                isConnectivity = true
            default:
                isConnectivity = false
            }
        } else {
            message = "\(error)"
            isConnectivity = false
        }
    }
}

public struct MediaLoadPart<Value: Sendable>: Sendable {
    public var value: Value?
    public var failure: MediaFailure?

    public init(value: Value?, failure: MediaFailure?) {
        self.value = value
        self.failure = failure
    }
}

public struct MediaHomeContent: Sendable, Equatable {
    public var libraries: [MediaLibrary]
    public var resume: [MediaItem]
    public var nextUp: [MediaItem]
    public var latest: [MediaItem]

    public init(
        libraries: [MediaLibrary] = [],
        resume: [MediaItem] = [],
        nextUp: [MediaItem] = [],
        latest: [MediaItem] = []
    ) {
        self.libraries = libraries
        self.resume = resume
        self.nextUp = nextUp
        self.latest = latest
    }

    public var isEmpty: Bool {
        libraries.isEmpty && resume.isEmpty && nextUp.isEmpty && latest.isEmpty
    }
}

/// 首页一次刷新的完整结果：成功的分区更新，失败的分区保留上一份内容。
public struct MediaHomeRefresh: Sendable {
    public var snapshot: MediaSnapshot<MediaHomeContent>
    public var failures: [String: MediaFailure]

    public init(snapshot: MediaSnapshot<MediaHomeContent>, failures: [String: MediaFailure]) {
        self.snapshot = snapshot
        self.failures = failures
    }
}

public struct MediaDetailContent: Sendable, Equatable {
    public var item: MediaItem
    public var seasons: [MediaItem]
    /// 仓储默认准备第一季非特别篇的集；应用层可再按自己的季偏好请求其他季。
    public var episodesSeasonID: MediaItem.ID?
    public var episodes: [MediaItem]
    public var collectionMembers: [MediaItem]
    public var collectionMembersTotalCount: Int?

    public init(
        item: MediaItem,
        seasons: [MediaItem] = [],
        episodesSeasonID: MediaItem.ID? = nil,
        episodes: [MediaItem] = [],
        collectionMembers: [MediaItem] = [],
        collectionMembersTotalCount: Int? = nil
    ) {
        self.item = item
        self.seasons = seasons
        self.episodesSeasonID = episodesSeasonID
        self.episodes = episodes
        self.collectionMembers = collectionMembers
        self.collectionMembersTotalCount = collectionMembersTotalCount
    }
}

public struct MediaDetailRefresh: Sendable {
    public var snapshot: MediaSnapshot<MediaDetailContent>
    public var failures: [String: MediaFailure]

    public init(snapshot: MediaSnapshot<MediaDetailContent>, failures: [String: MediaFailure]) {
        self.snapshot = snapshot
        self.failures = failures
    }
}

/// 库页 / 搜索页的查询身份。分页窗口不属于查询身份，而属于单次请求。
///
/// `recursive` 只影响请求形态，不进 SQLite 页键：当前两个调用方（库网格递归、
/// 合集成员非递归）的 parent 身份本身就能区分；将来若同一 parent 需要两种递归
/// 形态各自缓存，必须给 `page` 表加列并写迁移。
public struct MediaPageDescriptor: Hashable, Sendable {
    public var parentID: String?
    public var kinds: [MediaItem.Kind]?
    public var recursive: Bool
    public var sort: MediaItemsSort?
    public var watchState: MediaItemsWatchState?
    public var searchTerm: String?

    public init(
        parentID: String?,
        kinds: [MediaItem.Kind]? = nil,
        recursive: Bool = true,
        sort: MediaItemsSort? = nil,
        watchState: MediaItemsWatchState? = nil,
        searchTerm: String? = nil
    ) {
        self.parentID = parentID
        self.kinds = kinds
        self.recursive = recursive
        self.sort = sort
        self.watchState = watchState
        self.searchTerm = searchTerm
    }

    public func key(startIndex: Int, limit: Int) -> PageKey {
        PageKey(
            parentID: parentID, kinds: kinds, sort: sort, watchState: watchState,
            searchTerm: searchTerm, startIndex: startIndex, limit: limit)
    }
}

/// 某个查询已按顺序恢复的所有页。视图不需要再维护另一份跨页面分页缓存。
public struct MediaPageContent: Sendable, Equatable {
    public var items: [MediaItem]
    public var totalCount: Int?
    public var nextStartIndex: Int
    public var lastPageWasFull: Bool

    public init(
        items: [MediaItem] = [],
        totalCount: Int? = nil,
        nextStartIndex: Int = 0,
        lastPageWasFull: Bool = false
    ) {
        self.items = items
        self.totalCount = totalCount
        self.nextStartIndex = nextStartIndex
        self.lastPageWasFull = lastPageWasFull
    }
}

extension MediaDataSource: Codable {}
extension MediaSnapshot: Codable where Value: Codable {}
extension MediaFailure: Codable {}
extension MediaHomeContent: Codable {}
extension MediaHomeRefresh: Codable {}
extension MediaDetailContent: Codable {}
extension MediaDetailRefresh: Codable {}
extension MediaPageContent: Codable {}
