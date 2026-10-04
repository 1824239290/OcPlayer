import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit

/// `MediaServer` 的**写穿**装饰器：每个读方法原样转发给内层服务器，
/// 成功后把结果写进 `MetadataStore`。
///
/// ## 为什么只写不读（本方案最重要的一条约束）
///
/// 朴素做法是「网络失败时返回缓存」。但那会让调用方**分不清拿到的是新数据还是旧数据**，
/// 于是「离线」这件事在 UI 层变得不可表达；而吞掉错误还会把既有调好的错误路径弄浑
/// （首页 `RailResult` 的逐条成败、详情页 SWR 的静默失败）。
///
/// 所以职责切成三块，互不干扰：
/// - **写穿（本类）**：只落盘，返回值与错误一律与内层**完全一致**；
/// - **离线读**（`MetadataHydrator`）：独立的读入口，返回「内容 + 旧到什么程度」；
/// - **UI 决策**：网络失败且磁盘有内容 → 保留内容 + 标离线。
///
/// ## 为什么用装饰器而不是在各调用点加缓存
///
/// `MediaServer` 有 30 条要求且还会长。装饰器漏转发一条 = **编译不过**；
/// 散在调用点的写法一定是漏一条就静默不缓存，且永远不会有人发现。
///
/// ## 写入失败绝不冒泡
///
/// 落盘是**副作用**：缓存写失败（磁盘满、库损坏）不该让用户看到一个网络请求失败。
/// 因此所有写入都 `try?` 吞掉 + 记 warning；用户的请求照常成功。
public struct CachedMediaServer: MediaServer {

    /// 内层真实服务器。
    public let wrapped: any MediaServer
    private let store: MetadataStore
    private let tenant: TenantID

    public init(wrapping wrapped: any MediaServer, store: MetadataStore, tenant: TenantID) {
        self.wrapped = wrapped
        self.store = store
        self.tenant = tenant
    }

    // MARK: - 直通（不缓存）

    public var profile: ServerProfile { wrapped.profile }
    public var authorizationHeader: String { wrapped.authorizationHeader }

    public func imageURL(itemID: String, type: ItemImageType, maxWidth: Int?, tag: String?) throws -> URL {
        try wrapped.imageURL(itemID: itemID, type: type, maxWidth: maxWidth, tag: tag)
    }

    public func streamURL(itemID: String, mediaSourceID: String?, playSessionID: String?) throws -> String {
        try wrapped.streamURL(itemID: itemID, mediaSourceID: mediaSourceID, playSessionID: playSessionID)
    }

    /// 每次随机、且只是首页氛围图的素材池：缓存它没有意义（下次也该换一批），
    /// 而且它量不小（一屏轮播用得上的几十条）。刻意不写。
    public func randomBackdropItems(limit: Int) async throws -> [MediaItem] {
        try await wrapped.randomBackdropItems(limit: limit)
    }

    /// 「类似推荐」每次都可能不同，且是可选板块：不占缓存空间。
    public func similar(itemID: String, limit: Int) async throws -> [MediaItem] {
        try await wrapped.similar(itemID: itemID, limit: limit)
    }

    /// 章节 / 片头片尾：会话态数据，下次播放重拉（服务端有 intro-skipper 插件才有）。
    public func chapters(itemID: String) async throws -> [JellyfinChapter] {
        try await wrapped.chapters(itemID: itemID)
    }

    public func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment] {
        try await wrapped.mediaSegments(itemID: itemID)
    }

    /// 外挂字幕是**会话相关**的（服务端按当前会话能力决定给哪些），缓存会拿到过期清单。
    public func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle] {
        try await wrapped.externalSubtitles(itemID: itemID)
    }

    public func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL {
        try await wrapped.downloadSubtitle(subtitle)
    }

    /// `PlaybackInfo` 含一次性 playSessionId：**缓存它会把过期会话交出去**。
    public func playbackInfo(itemID: String) async throws -> PlaybackInfo {
        try await wrapped.playbackInfo(itemID: itemID)
    }

    // MARK: - 进度上报（直通）

    public func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async {
        await wrapped.reportPlaybackStart(context: context, positionSeconds: positionSeconds)
    }

    public func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async {
        await wrapped.reportPlaybackProgress(
            context: context, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    public func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async {
        await wrapped.reportPlaybackStopped(context: context, positionSeconds: positionSeconds)
    }

    // MARK: - 浏览（写穿）

    public func userViews() async throws -> [MediaLibrary] {
        let libraries = try await wrapped.userViews()
        await record { try await store.saveLibraries(libraries, tenant: tenant) }
        return libraries
    }

    public func latestItems(limit: Int) async throws -> [MediaItem] {
        let items = try await wrapped.latestItems(limit: limit)
        await record(items: items, rail: "latest")
        return items
    }

    public func favoriteItems(limit: Int) async throws -> [MediaItem] {
        let items = try await wrapped.favoriteItems(limit: limit)
        await record(items: items, rail: "favorite")
        return items
    }

    public func resumeItems() async throws -> [MediaItem] {
        let items = try await wrapped.resumeItems()
        await record(items: items, rail: "resume")
        return items
    }

    public func nextUp() async throws -> [MediaItem] {
        let items = try await wrapped.nextUp()
        await record(items: items, rail: "nextUp")
        return items
    }

    // MARK: - 标记已看 / 未看

    /// 服务端返回的 playState 是**权威值**：直接写回缓存（比等下次详情刷新更及时，
    /// 且离线时详情页显示的就是刚标记过的状态）。
    @discardableResult
    public func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        let state = try await wrapped.markPlayed(itemID: itemID)
        await record { try await store.updatePlayState(state, forItemID: itemID, tenant: tenant) }
        return state
    }

    @discardableResult
    public func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        let state = try await wrapped.markUnplayed(itemID: itemID)
        await record { try await store.updatePlayState(state, forItemID: itemID, tenant: tenant) }
        return state
    }

    // MARK: - 详情（写穿）

    public func item(_ id: String) async throws -> MediaItem {
        let item = try await wrapped.item(id)
        await record(items: [item], rail: nil)
        return item
    }

    public func itemsPage(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        startIndex: Int,
        limit: Int,
        sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?,
        searchTerm: String?
    ) async throws -> MediaItemsPage {
        let page = try await wrapped.itemsPage(
            parentID: parentID, kinds: kinds, recursive: recursive,
            startIndex: startIndex, limit: limit, sort: sort,
            watchState: watchState, searchTerm: searchTerm)
        let key = PageKey(parentID: parentID, kinds: kinds, sort: sort, watchState: watchState,
                          searchTerm: searchTerm, startIndex: startIndex, limit: limit)
        await record {
            // 条目与页快照一次事务写完：只写页快照的话，详情页（读 item 表）拿不到这些条目。
            try await store.saveItems(page.items, tenant: tenant)
            try await store.savePage(page, key: key, tenant: tenant)
        }
        return page
    }

    public func items(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        limit: Int
    ) async throws -> [MediaItem] {
        let items = try await wrapped.items(
            parentID: parentID, kinds: kinds, recursive: recursive, limit: limit)
        await record(items: items, rail: nil)
        return items
    }

    public func seasons(seriesID: String) async throws -> [MediaItem] {
        let seasons = try await wrapped.seasons(seriesID: seriesID)
        await record(items: seasons, rail: nil)
        return seasons
    }

    public func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem] {
        let episodes = try await wrapped.episodes(seriesID: seriesID, seasonID: seasonID)
        await record(items: episodes, rail: nil)
        return episodes
    }

    /// 连播路径：只记条目（不建快照——这条路径是播放中间态，不该覆盖首页 rail）。
    public func episodes(seriesID: String, startingAt startItemID: String, limit: Int) async throws -> [MediaItem] {
        let episodes = try await wrapped.episodes(
            seriesID: seriesID, startingAt: startItemID, limit: limit)
        await record(items: episodes, rail: nil)
        return episodes
    }

    public func mediaFileInfo(itemID: String) async throws -> MediaFileInfo? {
        let info = try await wrapped.mediaFileInfo(itemID: itemID)
        if let info {
            await record { try await store.saveMediaFileInfo(info, itemID: itemID, tenant: tenant) }
        }
        return info
    }

    // MARK: - 写盘

    /// 条目（可选带 rail 快照）一次事务写完。
    ///
    /// 条目与 rail **必须同一次写**：分开写的话，进程在两次写之间被杀会留下
    /// 「新 rail + 旧条目」的不一致快照，首页显示的条目详情与 rail 里的对不上。
    private func record(items: [MediaItem], rail: String?) async {
        await record {
            try await store.saveItems(items, tenant: tenant)
            if let rail {
                try await store.saveRail(items, rail: rail, tenant: tenant)
            }
        }
    }

    /// 落盘副作用的统一出口：**失败只记日志，绝不影响返回值**。
    private func record(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            MetadataLog.logger.warning("元数据缓存写入失败（不影响本次请求）", fields: [
                "error": .string("\(error)"),
            ])
        }
    }
}
