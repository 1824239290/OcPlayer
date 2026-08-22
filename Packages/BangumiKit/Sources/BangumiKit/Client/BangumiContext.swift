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
            // 整页一个事务：一条一个事务在上千条收藏时会明显卡。
            try await db.saveSubjects(resp.data)
            count += resp.data.count
            offset += limit
            if offset >= resp.total { break }
        }
        return count
    }

    /// 给「在看」里章节还缺的条目补齐章节。
    ///
    /// 收藏接口只返回条目，不含章节，而进度页的章节网格、「下一集」按钮全靠本地
    /// 章节表。不补的话同步完照样是空网格，还会因为找不到未看集而显示成「已看完」。
    /// 并发有上限，别把几十个条目的章节请求一次全发出去。
    @discardableResult
    public static func backfillMissingEpisodes(maxConcurrent: Int = 4) async -> Int {
        guard let db = BangumiContext.shared.database else { return 0 }
        let subjectIDs = (try? await db.fetchSubjectIDsMissingEpisodes()) ?? []
        guard !subjectIDs.isEmpty else { return 0 }

        var filled = 0
        await withTaskGroup(of: Bool.self) { group in
            var pending = subjectIDs.makeIterator()
            for _ in 0..<max(1, maxConcurrent) {
                guard let subjectID = pending.next() else { break }
                group.addTask { await BangumiEpisodeRepository.syncEpisodesQuietly(subjectID, db: db) }
            }
            while let succeeded = await group.next() {
                if succeeded { filled += 1 }
                if let subjectID = pending.next() {
                    group.addTask { await BangumiEpisodeRepository.syncEpisodesQuietly(subjectID, db: db) }
                }
            }
        }
        if filled > 0 {
            BangumiNetworkLog.logger.debug("章节补齐完成 subjects=\(filled)")
        }
        return filled
    }
}

/// 章节远程与本地组合层。
@MainActor
public enum BangumiEpisodeRepository {
    /// 拉取条目全部章节并落库，删除本地多余章节。不发通知，供批量补齐复用。
    nonisolated static func syncEpisodes(
        _ subjectId: Int, db: BangumiDatabaseOperator
    ) async throws {
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
    }

    /// `syncEpisodes` 的静默版本：失败只记日志，返回是否成功（批量补齐用）。
    nonisolated static func syncEpisodesQuietly(
        _ subjectId: Int, db: BangumiDatabaseOperator
    ) async -> Bool {
        do {
            try await syncEpisodes(subjectId, db: db)
            return true
        } catch {
            BangumiNetworkLog.logger.warning("章节补齐失败 subject=\(subjectId) error=\(error)")
            return false
        }
    }

    /// 拉取条目全部章节并落库，删除本地多余章节。
    public static func loadEpisodes(_ subjectId: Int) async throws {
        guard let db = BangumiContext.shared.database else { throw BangumiError.uninitializedDB }
        try await syncEpisodes(subjectId, db: db)
        BangumiProgressInvalidation.post(subjectId: subjectId)
    }

    /// 保证条目本体和章节都在本地。
    ///
    /// 关联是可以指向「没收藏过」的条目的，那种条目根本不在收藏同步的结果里；
    /// 只从本地读会得到 nil，详情页就永远停在「未关联」的样子。这里补远程拉取。
    public static func ensureSubjectLoaded(
        _ subjectId: Int, refreshEpisodes: Bool = false
    ) async throws {
        guard let db = BangumiContext.shared.database else { throw BangumiError.uninitializedDB }
        if try await db.subject(id: subjectId) == nil {
            let remote = try await BangumiSubjectService.getSubject(subjectId)
            try await db.saveSubject(remote)
        }
        let counts = try await db.fetchEpisodeCounts(subjectId: subjectId)
        if refreshEpisodes || counts.main + counts.other == 0 {
            try await syncEpisodes(subjectId, db: db)
        }
        BangumiProgressInvalidation.post(subjectId: subjectId)
    }

    /// 从远端整份回读条目 + 章节，覆盖本地。
    static func reconcileSubject(_ subjectId: Int) async throws {
        guard let db = BangumiContext.shared.database else { throw BangumiError.uninitializedDB }
        let remote = try await BangumiSubjectService.getSubject(subjectId)
        try await db.saveSubject(remote)
        try await syncEpisodes(subjectId, db: db)
    }

    /// 单集标记后的服务端对齐（播放结束自动标记用）。
    ///
    /// 单集 PATCH 不带 batch，服务端对条目收藏状态的连带推进（如看到最后一集
    /// 后的「在看 → 看过」）不该由本地猜——回读一次并带上 membership 失效，
    /// 让进度页的章节状态、计数和列表成员资格立刻对齐。回读失败不回滚，
    /// 本地乐观值仍然可用，下次全量同步纠正。
    public static func refreshSubjectAfterProgressChange(_ subjectId: Int) async {
        do {
            try await reconcileSubject(subjectId)
            BangumiProgressInvalidation.post(
                subjectId: subjectId, mayChangeProgressMembership: true)
        } catch {
            BangumiNetworkLog.logger.warning(
                "进度变更后回读条目失败 subject=\(subjectId) error=\(error)")
        }
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
        guard let subjectId else { return }
        // 先按本地推断更新，UI 立刻有反馈。
        BangumiProgressInvalidation.post(subjectId: subjectId)
        guard batch else { return }
        // 「看到此集」的服务端语义（连带标了哪些集、条目收藏状态有没有被推进）不该由
        // 本地猜，回读一次对齐；回读失败不回滚——本地乐观值仍然可用，下次同步会纠正。
        do {
            try await reconcileSubject(subjectId)
            BangumiProgressInvalidation.post(
                subjectId: subjectId, mayChangeProgressMembership: true)
        } catch {
            BangumiNetworkLog.logger.warning(
                "批量标记后回读失败 subject=\(subjectId) error=\(error)")
        }
    }
}

/// Bangumi 功能的中央上下文：数据库 + 登录态 + 收藏/章节操作。
/// App 层持有它（仿 danmaku 协调器模式），视图通过它访问 Bangumi 能力。
@MainActor
@Observable
public final class BangumiContext {
    public static let shared = BangumiContext()

    public let store = BangumiStore.shared
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

    /// 保证条目本体 + 章节在本地（详情页、刚关联完时调）。
    public func ensureSubjectLoaded(_ subjectId: Int, refreshEpisodes: Bool = false) async throws {
        try await BangumiEpisodeRepository.ensureSubjectLoaded(
            subjectId, refreshEpisodes: refreshEpisodes)
    }

    public func updateEpisodeCollection(
        episodeId: Int, type: BangumiEpisodeCollectionType, batch: Bool = false
    ) async throws {
        try await BangumiEpisodeRepository.updateEpisodeCollection(
            episodeId: episodeId, type: type, batch: batch)
    }

    /// 单集标记后的服务端对齐（播放结束自动标记用），实例侧入口。
    public func refreshSubjectAfterProgressChange(_ subjectId: Int) async {
        await BangumiEpisodeRepository.refreshSubjectAfterProgressChange(subjectId)
    }

    /// 收藏同步 + 章节补齐（进度页全量刷新）。返回同步到的条目数。
    @discardableResult
    public func refreshAllCollections(force: Bool = false) async throws -> Int {
        if force { store.setCollectionsUpdatedAt(0) }
        let since = store.collectionsUpdatedAt
        // 时间戳取「同步开始」而不是结束：同步途中发生的变更下次还能被 since 捞到。
        let startedAt = Int(Date().timeIntervalSince1970)
        let count = try await BangumiCollectionRepository.refreshCollections(since: since)
        store.setCollectionsUpdatedAt(startedAt)
        // 收藏接口不带章节，进度页的章节网格靠这一步补。
        await BangumiCollectionRepository.backfillMissingEpisodes()
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
