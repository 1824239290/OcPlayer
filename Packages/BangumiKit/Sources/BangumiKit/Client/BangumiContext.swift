import DiagnosticsKit
import Foundation
import GRDB
import Observation

/// 进度/收藏数据变更后的跨页面失效通知。
/// object 为 subjectId（NSNumber），userInfo 里 mayChangeProgressMembership 表示
/// 这次变更可能改变该条目是否还属于「在看」列表（需要整窗刷新而非单纯合并）。
public enum BangumiProgressInvalidation {
    public static let notificationName = Notification.Name("BangumiProgressInvalidation")

    public static func post(subjectId: Int, mayChangeProgressMembership: Bool = false) {
        NotificationCenter.default.post(
            name: notificationName,
            object: NSNumber(value: subjectId),
            userInfo: ["mayChangeProgressMembership": mayChangeProgressMembership])
    }
}

/// 集合远程与本地组合层：先拉远程、落库，再让 UI 从 DB 读。
@MainActor
public enum BangumiCollectionRepository {
    /// 增量同步全部收藏（since > 0 时只拉变更）。返回本页拉取的条目数。
    public static func refreshCollections(since: Int) async throws -> Int {
        guard let db = BangumiContext.shared.database else { throw BangumiError.uninitializedDB }
        var count = 0
        var offset = 0
        let limit = 100
        while true {
            let resp = try await BangumiCollectionService.getSubjectCollections(
                since: since, limit: limit, offset: offset)
            if resp.data.isEmpty { break }
            for item in resp.data {
                try await db.saveSubject(item)
                count += 1
            }
            offset += limit
            if offset >= resp.total { break }
        }
        return count
    }
}

/// 章节远程与本地组合层。
@MainActor
public enum BangumiEpisodeRepository {
    /// 拉取条目全部章节并落库，删除本地多余章节。
    public static func loadEpisodes(_ subjectId: Int) async throws {
        guard let db = BangumiContext.shared.database else { throw BangumiError.uninitializedDB }
        var offset = 0
        let limit = 1000
        var total = 0
        var items: [BangumiEpisodeDTO] = []
        var episodeIds = Set<Int>()
        while true {
            let response = try await BangumiEpisodeService.getSubjectEpisodes(
                subjectId, limit: limit, offset: offset)
            total = response.total
            if response.data.isEmpty { break }
            for item in response.data {
                items.append(item)
                episodeIds.insert(item.id)
            }
            offset += limit
            if offset >= total { break }
        }
        try await db.saveEpisodes(subjectId: subjectId, items: items)
        try await db.deleteEpisodesNotIn(subjectId: subjectId, episodeIds: episodeIds)
        BangumiProgressInvalidation.post(subjectId: subjectId)
    }

    /// 更新单集状态：先远程成功后改本地，再发失效通知。
    public static func updateEpisodeCollection(
        episodeId: Int, type: BangumiEpisodeCollectionType, batch: Bool = false
    ) async throws {
        try await BangumiEpisodeService.updateEpisodeCollection(
            episodeId: episodeId, type: type, batch: batch)
        guard let db = BangumiContext.shared.database else { throw BangumiError.uninitializedDB }
        let subjectId = try await db.updateEpisodeCollection(
            episodeId: episodeId, type: type, batch: batch)
        if let subjectId {
            BangumiProgressInvalidation.post(subjectId: subjectId)
        }
    }
}

/// Bangumi 功能的中央上下文：数据库 + 登录态 + 收藏/章节操作。
/// App 层持有它（仿 danmaku 协调器模式），视图通过它访问 Bangumi 能力。
@MainActor
@Observable
public final class BangumiContext {
    public static let shared = BangumiContext()

    public let store = BangumiStore()
    public private(set) var database: BangumiDatabaseOperator?

    /// 数据库就绪状态（启动时异步建库）。
    public private(set) var isDatabaseReady = false

    private var setupTask: Task<Void, Never>?

    public init() {}

    /// 启动时调用一次，异步建库（不阻塞主线程）。
    public func setupIfNeeded(directory: URL? = nil) {
        guard setupTask == nil else { return }
        // 先从 store 恢复登录态到内存（启动时如果已登录，UI 立刻显示正确状态）。
        syncAuthState()
        setupTask = Task { @MainActor in
            let base = directory
                ?? FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first!
            let appDir = base.appendingPathComponent("OcPlayer", isDirectory: true)
            do {
                let dbQueue = try BangumiDatabaseFactory.makeDatabase(at: appDir)
                self.database = BangumiDatabaseOperator(database: dbQueue)
                self.isDatabaseReady = true
            } catch {
                BangumiNetworkLog.logger.error("Bangumi 建库失败 error=\(error)")
            }
        }
    }

    // MARK: - 登录态

    /// 存储属性（非计算属性）：@Observable 只有存储属性变更才触发 UI 更新。
    /// AuthService 写完 store（UserDefaults）后必须调 syncAuthState() 刷新这两个值。
    public private(set) var isAuthenticated = false
    public private(set) var profile: BangumiProfile?

    /// 从 store（UserDefaults）同步登录态到内存存储属性（触发 UI 刷新）。
    public func syncAuthState() {
        isAuthenticated = store.isAuthenticated
        profile = store.profile
    }

    /// 登录成功后调：写 store + 同步内存属性。
    public func setAuthenticated(_ profile: BangumiProfile) {
        store.setProfile(profile)
        store.setAuthenticated(true)
        syncAuthState()
    }

    /// 登出后调：清 store + 同步内存属性。
    public func clearAuthState() {
        store.setAuthenticated(false)
        store.setProfile(nil)
        syncAuthState()
    }

    // MARK: - 进度

    public func fetchProgressSubjects(
        tab: BangumiSubjectType,
        sortMode: BangumiProgressSortMode = .collectedAt,
        search: String = "",
        episodeWindowSize: Int = 5,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> BangumiPagedDTO<BangumiProgressSubject> {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.fetchProgressSubjects(
            progressTab: tab,
            sortMode: sortMode,
            search: search,
            episodeWindowSize: episodeWindowSize,
            limit: limit,
            offset: offset)
    }

    public func fetchProgressCounts() async throws -> [BangumiSubjectType: Int] {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.fetchProgressCounts()
    }

    public func fetchProgressSubject(
        subjectId: Int, episodeWindowSize: Int = 5
    ) async throws -> BangumiProgressSubject? {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.fetchProgressSubject(
            subjectId: subjectId, episodeWindowSize: episodeWindowSize)
    }

    // MARK: - 收藏列表

    public func fetchCollectionCounts(
        subjectType: BangumiSubjectType
    ) async throws -> [BangumiCollectionType: Int] {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.fetchCollectionCounts(subjectType: subjectType)
    }

    public func fetchCollectionSubjects(
        subjectType: BangumiSubjectType,
        collectionType: BangumiCollectionType,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> [BangumiSubjectDTO] {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.fetchCollectionSubjects(
            subjectType: subjectType,
            collectionType: collectionType,
            limit: limit,
            offset: offset)
    }

    // MARK: - 章节

    public func fetchEpisodes(
        subjectId: Int, main: Bool? = nil, limit: Int? = nil
    ) async throws -> [BangumiEpisodeDTO] {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.fetchEpisodes(subjectId: subjectId, main: main, limit: limit)
    }

    public func loadEpisodes(_ subjectId: Int) async throws {
        try await BangumiEpisodeRepository.loadEpisodes(subjectId)
    }

    public func updateEpisodeCollection(
        episodeId: Int, type: BangumiEpisodeCollectionType, batch: Bool = false
    ) async throws {
        try await BangumiEpisodeRepository.updateEpisodeCollection(
            episodeId: episodeId, type: type, batch: batch)
    }

    /// 收藏同步 + 章节补齐（进度页全量刷新）。
    public func refreshAllCollections(force: Bool = false) async throws -> Int {
        let store = BangumiStore()
        if force { store.setCollectionsUpdatedAt(0) }
        let since = store.collectionsUpdatedAt
        let count = try await BangumiCollectionRepository.refreshCollections(since: since)
        store.setCollectionsUpdatedAt(Int(Date().timeIntervalSince1970))
        return count
    }

    public func subject(id: Int) async throws -> BangumiSubjectDTO? {
        guard let db = database else { throw BangumiError.uninitializedDB }
        return try await db.subject(id: id)
    }

    // MARK: - 登出

    public func signOutBangumi() async {
        await BangumiAuthService.logout()
    }
}

public extension BangumiError {
    static let uninitializedDB = BangumiError(message: "Bangumi 数据库尚未就绪")
}
