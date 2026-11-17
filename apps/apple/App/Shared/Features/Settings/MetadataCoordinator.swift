import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit
import Observation

/// 媒体数据面的 App 层宿主：开库、维护，以及为当前会话提供唯一的 `MediaRepository`。
///
/// 视图不再直接调用 `MediaServer` 的媒体读方法，也不再各自持有详情 / 分页缓存。
/// 首页、详情、预取、库页与进度写回全部经这里转发到仓储；缓存写入、租户隔离、
/// 同键单飞与 SQLite 读写都收在 `MediaRepository` 内部。
///
/// 建库失败时仓储退化为**内存模式**：读取与刷新协议不变，只是不落盘。
/// 因此 App 不需要「有库走缓存、无库直走服务器」的第二套实现。
@MainActor
@Observable
final class MetadataCoordinator {

    /// 当前是否可用（建库完成）。false 时仓储仍可用，只是不落盘。
    private(set) var isReady = false
    /// 建库失败的原因（供设置页/诊断展示）。
    private(set) var setupError: String?
    /// 上次体积统计（字节，含 WAL）。
    private(set) var databaseBytes: Int64 = 0

    @ObservationIgnored private var store: MetadataStore?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var databaseDirectory: URL?
    @ObservationIgnored private var activeServer: (any MediaServer)?
    @ObservationIgnored private var activeServerIdentifier: ObjectIdentifier?
    @ObservationIgnored private var repository: MediaRepository?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private let openStore: @Sendable (URL) async throws -> MetadataStore
    @ObservationIgnored private(set) var pendingPlaybackProgressWrite: Task<Void, Never>?

    init(openStore: @escaping @Sendable (URL) async throws -> MetadataStore = {
        try MetadataCache.open(at: $0)
    }) {
        self.openStore = openStore
    }

    // MARK: - 建库

    /// 启动时调用一次，异步建库（不阻塞主线程）。
    func setup(directory: URL? = nil) {
        guard setupTask == nil else { return }
        let root = directory ?? OcPlayerStorage.defaultRoot
        databaseDirectory = root
        let openStore = openStore
        setupTask = Task.detached(priority: .userInitiated) {
            do {
                let store = try await openStore(root)
                await MainActor.run {
                    self.store = store
                    self.isReady = true
                    self.setupError = nil
                    self.refreshSize()
                }
            } catch {
                AppDiagnostics.logError("媒体元数据库建库失败 error=\(error)")
                await MainActor.run {
                    self.setupTask = nil
                    self.setupError = "元数据缓存初始化失败：\(error)"
                }
            }
        }
    }

    /// 等建库完成（仓储创建用）。未 setup 时立即返回 false。
    func waitUntilReady() async -> Bool {
        if isReady { return true }
        guard let setupTask else { return false }
        await setupTask.value
        return isReady
    }

    // MARK: - 当前会话

    /// 会话落地 / 换服 / 登出时调用。服务器实例变化即丢弃旧仓储的内存投影，
    /// 磁盘内容按租户隔离，仍归同一台服务器复用。
    func setActiveServer(_ server: (any MediaServer)?) {
        let effectiveServer: (any MediaServer)?
        if let server = server as? RustCoreMediaServer {
            // AppModel may install the Rust facade as the session's canonical
            // server so playback reporting and browsing share one backend.
            effectiveServer = server
        } else if let server, let rust = RustCoreMediaServer(wrapping: server, dataDirectory: databaseDirectory) {
            effectiveServer = rust
        } else {
            effectiveServer = server
        }
        let identifier = effectiveServer.map { ObjectIdentifier($0 as AnyObject) }
        if identifier != activeServerIdentifier {
            sessionGeneration &+= 1
            let retired = repository
            activeServer = effectiveServer
            activeServerIdentifier = identifier
            repository = nil
            if let retired {
                // 旧会话的在途请求可能在登出后才回来；先关写盘闸门再放手。
                Task { await retired.shutdown() }
            }
        }
    }

    /// 当前会话的媒体数据仓储。未接服务器时为 nil。
    func currentRepository() async -> MediaRepository? {
        guard let server = activeServer else { return nil }
        if let repository { return repository }
        let generation = sessionGeneration
        _ = await waitUntilReady()
        // await 期间可能换服、登出，甚至 A → B → A；旧调用不能安装新会话的仓储。
        guard !Task.isCancelled, generation == sessionGeneration else { return nil }
        // 同一会话的其他调用者可能已经完成创建。安装过程在主 actor 上无悬挂点。
        if let repository { return repository }
        let repo = MediaRepository(server: server, store: store)
        repository = repo
        return repo
    }

    /// 测试与维护用：当前仓储（不创建）。
    var repositoryIfReady: MediaRepository? { repository }

    // MARK: - 读入口（全部转发仓储）

    func cachedHome() async -> MediaSnapshot<MediaHomeContent>? {
        await currentRepository()?.cachedHome()
    }

    func refreshHome() async -> MediaHomeRefresh? {
        await currentRepository()?.refreshHome()
    }

    func cachedItem(itemID: MediaItem.ID) async -> MediaSnapshot<MediaItem>? {
        await currentRepository()?.cachedItem(itemID: itemID)
    }

    func refreshItem(itemID: MediaItem.ID) async throws -> MediaItem? {
        try await currentRepository()?.refreshItem(itemID: itemID)
    }

    func cachedDetail(itemID: MediaItem.ID) async -> MediaSnapshot<MediaDetailContent>? {
        await currentRepository()?.cachedDetail(itemID: itemID)
    }

    func refreshDetail(
        itemID: MediaItem.ID,
        kindHint: MediaItem.Kind?
    ) async throws -> MediaDetailRefresh? {
        try await currentRepository()?.refreshDetail(itemID: itemID, kindHint: kindHint)
    }

    func prefetchDetail(itemID: MediaItem.ID, kindHint: MediaItem.Kind?) async {
        await currentRepository()?.prefetchDetail(itemID: itemID, kindHint: kindHint)
    }

    func cachedEpisodes(
        seriesID: MediaItem.ID,
        seasonID: MediaItem.ID
    ) async -> MediaSnapshot<[MediaItem]>? {
        await currentRepository()?.cachedEpisodes(seriesID: seriesID, seasonID: seasonID)
    }

    func refreshEpisodes(
        seriesID: MediaItem.ID,
        seasonID: MediaItem.ID
    ) async throws -> [MediaItem]? {
        try await currentRepository()?.refreshEpisodes(seriesID: seriesID, seasonID: seasonID)
    }

    func cachedPage(
        _ descriptor: MediaPageDescriptor,
        limit: Int
    ) async -> MediaSnapshot<MediaPageContent>? {
        await currentRepository()?.cachedPage(descriptor, limit: limit)
    }

    func refreshPage(
        _ descriptor: MediaPageDescriptor,
        startIndex: Int,
        limit: Int
    ) async throws -> MediaSnapshot<MediaPageContent>? {
        try await currentRepository()?.refreshPage(
            descriptor, startIndex: startIndex, limit: limit)
    }

    func cachedCollectionMembers(
        itemID: MediaItem.ID
    ) async -> MediaSnapshot<MediaPageContent>? {
        await currentRepository()?.cachedCollectionMembers(itemID: itemID)
    }

    func refreshCollectionMembers(
        itemID: MediaItem.ID,
        startIndex: Int = 0
    ) async throws -> MediaSnapshot<MediaPageContent>? {
        try await currentRepository()?.refreshCollectionMembers(
            itemID: itemID, startIndex: startIndex)
    }

    func similar(itemID: MediaItem.ID, limit: Int) async throws -> [MediaItem] {
        try await currentRepository()?.similar(itemID: itemID, limit: limit) ?? []
    }

    // MARK: - 写入口

    /// 排队前固定原会话。即使建库尚未完成或仓储已退休，也只写原租户的末次进度。
    /// 本地进度与远端上报独立；串行写回防止快速换片时旧位置后落库。
    func finishPlaybackProgress(
        item: MediaItem,
        positionSeconds: Double,
        durationSeconds: Double?
    ) -> Task<Void, Never>? {
        guard let server = activeServer else { return nil }
        let recordedAt = Date()
        let originRepository = repository
        let readiness = setupTask
        let preceding = pendingPlaybackProgressWrite
        let write = Task { @MainActor in
            await preceding?.value
            await readiness?.value
            // store 是整库，不随租户切换；server 已在排队前捕获，绝不再解析 activeServer。
            let origin = originRepository ?? MediaRepository(server: server, store: store)
            await origin.recordFinalPlaybackProgress(
                item: item, positionSeconds: positionSeconds, durationSeconds: durationSeconds,
                recordedAt: recordedAt)
        }
        pendingPlaybackProgressWrite = write
        return write
    }

    @discardableResult
    func markPlayed(itemID: MediaItem.ID) async throws -> MediaItem.PlayState? {
        try await currentRepository()?.markPlayed(itemID: itemID)
    }

    @discardableResult
    func markUnplayed(itemID: MediaItem.ID) async throws -> MediaItem.PlayState? {
        try await currentRepository()?.markUnplayed(itemID: itemID)
    }

    func recordPlaybackProgress(
        itemID: MediaItem.ID,
        positionSeconds: Double,
        durationSeconds: Double?,
        played: Bool
    ) async {
        await currentRepository()?.recordPlaybackProgress(
            itemID: itemID, positionSeconds: positionSeconds,
            durationSeconds: durationSeconds, played: played)
    }

    func applyPlayState(_ state: MediaItem.PlayState, forItemID itemID: MediaItem.ID) async {
        await currentRepository()?.applyPlayState(
            state, forItemID: itemID, persistToStore: true)
    }

    /// 清空当前会话内存投影（不清磁盘）。
    func invalidateMemory() async {
        await repository?.invalidateMemory()
    }

    // MARK: - 维护

    var activeStore: MetadataStore? { store }

    func refreshSize() {
        guard let databaseDirectory else { return }
        databaseBytes = MetadataCache.sizeInBytes(at: databaseDirectory)
    }

    @discardableResult
    func clearCurrentTenant() async -> Bool {
        guard let store else { return false }
        do {
            if let server = activeServer {
                try await store.clear(tenant: TenantID(profile: server.profile))
            } else {
                try await store.clearAll()
            }
            await repository?.invalidateMemory(discardLocalProgress: true)
            refreshSize()
            return true
        } catch {
            AppDiagnostics.logWarning("清空媒体元数据缓存失败", fields: ["error": .string("\(error)")])
            return false
        }
    }

    /// 跑一次淘汰 + 回收磁盘。维护定时器调它。
    func runMaintenance(
        maxItems: Int = Eviction.maxItems,
        maxBytes: Int64 = Eviction.maxBytes
    ) async {
        guard let store else { return }
        do {
            let before = try await store.itemCount()
            try await store.evictItems(keepingAtMost: maxItems)

            if let databaseDirectory {
                let bytes = MetadataCache.sizeInBytes(at: databaseDirectory)
                if bytes > maxBytes {
                    let current = try await store.itemCount()
                    let target = max(0, current - max(1, current / 10))
                    try await store.evictItems(keepingAtMost: target)
                    try await store.vacuum()
                }
            }

            let after = try await store.itemCount()
            if after != before {
                AppDiagnostics.logInfo("媒体元数据淘汰", fields: [
                    "before": .integer(Int64(before)),
                    "after": .integer(Int64(after)),
                ])
            }
            refreshSize()
        } catch {
            AppDiagnostics.logWarning("媒体元数据维护失败", fields: ["error": .string("\(error)")])
        }
    }
}
