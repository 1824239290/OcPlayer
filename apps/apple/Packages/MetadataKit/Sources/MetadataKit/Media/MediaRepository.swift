import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit

/// 媒体元数据的唯一数据面：内存投影 → SQLite → 服务端。
///
/// 调用方用 `cached*` 立即可得地读旧内容，用 `refresh*` 做同键单飞的网络确认。
/// 视图不再直接缓存同一份媒体内容，也不再分别实现请求去重、租户隔离和进度写回。
///
/// `store == nil` 是**内存模式**（建库失败 / 测试未建库），读取与刷新协议完全不变；
/// 这样 App 不需要保留「有缓存走仓储、没缓存直走服务器」的第二套实现。
public actor MediaRepository {
    public struct Configuration: Sendable, Codable {
        public var itemLimit: Int
        public var detailLimit: Int
        public var episodeListLimit: Int
        public var pageLimit: Int

        public init(
            itemLimit: Int = 1_024,
            detailLimit: Int = 40,
            episodeListLimit: Int = 80,
            pageLimit: Int = 24
        ) {
            self.itemLimit = itemLimit
            self.detailLimit = detailLimit
            self.episodeListLimit = episodeListLimit
            self.pageLimit = pageLimit
        }
    }

    struct EpisodeKey: Hashable, Codable {
        var seriesID: MediaItem.ID
        var seasonID: MediaItem.ID
    }

    let server: any MediaServer
    let store: MetadataStore?
    let tenant: TenantID
    let configuration: Configuration
    let now: @Sendable () -> Date

    var localProgress: [MediaItem.ID: LocalPlaybackProgress] = [:]
    private var nativeShutdown = false
    var isShutdown: Bool { rust?.shutdownState ?? nativeShutdown }
    let rust: RustMediaRepository?
    var usesCoreRepository: Bool { rust != nil }
    private var nativeHomeEntry: MemoryEntry<MediaHomeContent>?
    var homeEntry: MemoryEntry<MediaHomeContent>? {
        get { if let rust { return rust.get("home", key: "home") }; return nativeHomeEntry }
        set { if let rust { rust.put("home", key: "home", entry: newValue) } else { nativeHomeEntry = newValue } }
    }
    var items: MemoryLRU<MediaItem.ID, MediaItem>
    var details: MemoryLRU<MediaItem.ID, MediaDetailContent>
    var episodeLists: MemoryLRU<EpisodeKey, [MediaItem]>
    var pages: MemoryLRU<MediaPageDescriptor, MediaPageContent>

    var homeTask: Task<MediaHomeRefresh, Never>?
    var itemTasks: [MediaItem.ID: Task<MediaItem, Error>] = [:]
    var detailTasks: [MediaItem.ID: Task<MediaDetailRefresh, Error>] = [:]
    var episodeTasks: [EpisodeKey: Task<[MediaItem], Error>] = [:]
    var pageTasks: [PageKey: Task<MediaSnapshot<MediaPageContent>, Error>] = [:]

    public init(
        server: any MediaServer,
        store: MetadataStore?,
        tenant: TenantID? = nil,
        configuration: Configuration = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        rustCoreLibraryPath: String? = nil, useSharedCore: Bool = true
    ) {
        self.server = server
        self.store = store
        self.tenant = tenant ?? TenantID(profile: server.profile)
        self.configuration = configuration
        self.now = now
        let rust = RustMediaRepository.make(configuration: configuration, libraryPath: rustCoreLibraryPath, enabled: useSharedCore)
        self.rust = rust
        self.items = MemoryLRU(limit: configuration.itemLimit, rust: rust, bucket: "items")
        self.details = MemoryLRU(limit: configuration.detailLimit, rust: rust, bucket: "details")
        self.episodeLists = MemoryLRU(limit: configuration.episodeListLimit, rust: rust, bucket: "episodes")
        self.pages = MemoryLRU(limit: configuration.pageLimit, rust: rust, bucket: "pages")
    }

    /// 会话结束：拒绝后续写盘并清掉内存投影，避免旧会话的在途请求在登出后
    /// 把缓存重新写回来。SQLite 内容按租户保留，不在这里删除。
    public func shutdown() {
        if let rust { rust.shutdown(); return }
        nativeShutdown = true
        invalidateMemory()
    }

    /// 清掉当前会话的内存投影。SQLite 内容仍属于租户，不应随视图或会话内存重置而删除。
    public func invalidateMemory(discardLocalProgress: Bool = false) {
        if let rust { rust.invalidate(discardLocalProgress: discardLocalProgress); return }
        if discardLocalProgress { localProgress.removeAll() }
        homeEntry = nil
        items.removeAll()
        details.removeAll()
        episodeLists.removeAll()
        pages.removeAll()
    }

    func snapshot<Value: Sendable>(
        _ value: Value,
        fetchedAt: Date,
        source: MediaDataSource
    ) -> MediaSnapshot<Value> {
        MediaSnapshot(value: value, fetchedAt: fetchedAt, source: source)
    }

    /// 缓存写入是副作用：磁盘失败只降级，不把一次成功的网络请求变成页面失败。
    func persist(_ work: @Sendable (MetadataStore) async throws -> Void) async {
        guard !isShutdown, let store else { return }
        do {
            try await work(store)
        } catch {
            MetadataLog.logger.warning("媒体数据写入失败（保留内存结果）", fields: [
                "error": .string("\(error)"),
            ])
        }
    }

    func read<Value: Sendable>(
        _ work: @Sendable (MetadataStore) async throws -> Value?
    ) async -> Value? {
        guard let store else { return nil }
        do {
            return try await work(store)
        } catch {
            MetadataLog.logger.warning("媒体数据读取失败（按无缓存处理）", fields: [
                "error": .string("\(error)"),
            ])
            return nil
        }
    }

    func rememberItems(_ newItems: [MediaItem]) {
        for item in newItems {
            items[item.id] = MemoryEntry(value: item, fetchedAt: now())
        }
    }

    func deduplicatedNextUp(_ nextUp: [MediaItem], resume: [MediaItem]) -> [MediaItem] {
        if let rust {
            do { return try rust.compose("nextUp", RustMediaRepository.NextUp(nextUp: nextUp, resume: resume)) }
            catch { RustMediaRepository.report(error); return [] }
        }
        guard !nextUp.isEmpty, !resume.isEmpty else { return nextUp }
        let resumeIDs = Set(resume.map(\.id))
        return nextUp.filter { !resumeIDs.contains($0.id) }
    }
}

struct MemoryEntry<Value: Sendable>: Sendable {
    var value: Value
    var fetchedAt: Date
}

/// 小型 LRU。只服务 actor 内部，不再引入另一套锁或跨 actor 缓存。
struct MemoryLRU<Key: Hashable & Codable, Value: Sendable & Codable> {
    private let rust: RustMediaRepository?
    private let bucket: String
    private let limit: Int
    private var values: [Key: MemoryEntry<Value>] = [:]
    private var recency: [Key] = []

    init(limit: Int, rust: RustMediaRepository? = nil, bucket: String = "items") {
        self.limit = max(1, limit)
        self.rust = rust
        self.bucket = bucket
    }

    subscript(key: Key) -> MemoryEntry<Value>? {
        mutating get {
            if let rust { return rust.get(bucket, key: key) }
            guard let entry = values[key] else { return nil }
            touch(key)
            return entry
        }
        set {
            if let rust { rust.put(bucket, key: key, entry: newValue); return }
            guard let newValue else {
                values[key] = nil
                recency.removeAll { $0 == key }
                return
            }
            values[key] = newValue
            touch(key)
            while values.count > limit, let oldest = recency.first {
                recency.removeFirst()
                values[oldest] = nil
            }
        }
    }

    var allValues: [Key: MemoryEntry<Value>] { rust?.all(bucket) ?? values }

    mutating func removeAll() {
        if let rust { rust.clear(bucket); return }
        values.removeAll()
        recency.removeAll()
    }

    private mutating func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// 分区加载的统一失败语义。取消不生成错误文案，真实失败投影成 `MediaFailure`。
func mediaLoadPart<Value: Sendable>(
    _ work: @Sendable () async throws -> Value
) async -> MediaLoadPart<Value> {
    do {
        return MediaLoadPart(value: try await work(), failure: nil)
    } catch where JellyfinError.isCancellation(error) {
        return MediaLoadPart(value: nil, failure: nil)
    } catch {
        return MediaLoadPart(value: nil, failure: MediaFailure(error))
    }
}

extension MediaPageDescriptor {
    var query: PageQuery {
        PageQuery(
            parentID: parentID, kinds: kinds, sort: sort,
            watchState: watchState, searchTerm: searchTerm)
    }
}

extension MemoryEntry: Encodable where Value: Encodable {}
extension MemoryEntry: Decodable where Value: Decodable {}
