import CoreModel
import Foundation
import JellyfinKit

/// 从磁盘读回的条目 + 它的新鲜度。
///
/// **两个时间戳是有意分开的**：元数据（简介 / 演员 / 图 tag）失效很慢，
/// 播放进度失效很快。合成一个时间会让「进度是 5 分钟前的」和「简介是 3 天前的」
/// 无法区分，而离线标识要说的恰恰是「你现在看到的这份，旧到什么程度」。
public struct CachedItem: Sendable {
    public var item: MediaItem
    /// 元数据写入时间。
    public var fetchedAt: Date
    /// 进度写入时间；nil = 这份进度从没被服务端确认过（只可能是首次写入就缺 playState）。
    public var progressFetchedAt: Date?

    public init(item: MediaItem, fetchedAt: Date, progressFetchedAt: Date? = nil) {
        self.item = item
        self.fetchedAt = fetchedAt
        self.progressFetchedAt = progressFetchedAt
    }

    /// 这份进度是否已经旧到不该当作现状展示（用于离线标识与「可能过期」提示）。
    public func isProgressStale(now: Date = Date(), ttl: TimeInterval = Freshness.progress) -> Bool {
        guard let progressFetchedAt else { return true }
        return now.timeIntervalSince(progressFetchedAt) > ttl
    }
}

public struct CachedLibrary: Sendable {
    public var library: MediaLibrary
    public var fetchedAt: Date

    public init(library: MediaLibrary, fetchedAt: Date) {
        self.library = library
        self.fetchedAt = fetchedAt
    }
}

public struct CachedRail: Sendable {
    public var items: [MediaItem]
    public var fetchedAt: Date

    public init(items: [MediaItem], fetchedAt: Date) {
        self.items = items
        self.fetchedAt = fetchedAt
    }
}

public struct CachedPage: Sendable {
    public var items: [MediaItem]
    public var totalRecordCount: Int?
    public var fetchedAt: Date

    public init(items: [MediaItem], totalRecordCount: Int?, fetchedAt: Date) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.fetchedAt = fetchedAt
    }
}

public struct CachedMediaFileInfo: Sendable {
    public var info: MediaFileInfo
    public var fetchedAt: Date

    public init(info: MediaFileInfo, fetchedAt: Date) {
        self.info = info
        self.fetchedAt = fetchedAt
    }
}

/// 各类数据的新鲜度阈值。
///
/// **只用于「标不标过期」与淘汰优先级，绝不阻止读取**——离线时宁可给旧数据，
/// 也不要空白页（这是整个 Phase 1 的目的）。所以这些值调大调小只影响提示文案，
/// 不影响功能可用性。
public enum Freshness {
    /// 播放进度：变化最快，也是用户最在意「准不准」的一项。
    public static let progress: TimeInterval = 15 * 60
    /// 首页 rail。
    public static let rail: TimeInterval = 15 * 60
    /// 库页 / 搜索页。
    public static let page: TimeInterval = 60 * 60
    /// 条目元数据。
    public static let item: TimeInterval = 7 * 24 * 60 * 60
    /// 媒体技术信息（分辨率 / 编码 / 音轨）：几乎不变。
    public static let mediaFileInfo: TimeInterval = 30 * 24 * 60 * 60
}

/// 淘汰上限。
public enum Eviction {
    /// 条目数上限。
    public static let maxItems = 30_000
    /// 数据库体积上限（含 WAL）。
    public static let maxBytes: Int64 = 200 * 1024 * 1024
}
