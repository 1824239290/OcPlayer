import CoreModel
import DiagnosticsKit
import Foundation

/// TMDb 补全服务：把「客户端 + 匹配器 + 数据库」串成一条可用路径。
///
/// ## 职责
///
/// - `overlay(for:tenant:)`：给定服务端条目，返回可叠加的 TMDb 数据（**只读路径**）。
/// - `refresh(item:tenant:)`：确保该条目的数据已拉取/未过期（**会发网络**）。
///
/// 两者分开是刻意的：**展示不该隐式发网络**。详情页可以只调 `overlay` 拿到已有数据
/// 立刻渲染，再在合适时机（`.task`）调 `refresh`。若合成一个方法，「打开详情页」
/// 与「打 TMDb 请求」就被绑死了，既没法离线复用，也没法让调用方控制时机。
///
/// ## 为什么它不碰 `MediaServer`
///
/// 它只认 `MediaItem`（值类型）与 `TenantID`。这样它可以脱离 AppModel / JellyfinKit
/// 单独测——而这层最容易出错的正是「匹配到什么」「该不该顶替服务端的值」这类纯逻辑。
public actor TMDbEnricher {

    private let client: TMDbClient
    private let store: MetadataStore
    private let preferences: TMDbPreferences
    private let logger = NetworkLog.logger(category: "TMDb")

    /// 正在拉取的键（同一实体并发请求只打一次——详情页与剧集页可能同时要它）。
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// 最近一次拉取的失败原因（成功即清空）。
    ///
    /// 存在的理由：**坏 key / 连不上原先完全静默**——用户填了 key、翻了几页、
    /// 什么都没发生，只会以为功能坏了。设置页据此把原因摆出来。
    /// 只记「最近一次」，不做历史；它是一个 UI 提示，不是错误账本。
    private var lastFailure: TMDbError?

    public init(client: TMDbClient, store: MetadataStore, preferences: TMDbPreferences) {
        self.client = client
        self.store = store
        self.preferences = preferences
    }

    /// 是否已配置 key（未配置时全部方法都是无操作，调用方不必自己判断）。
    public var isEnabled: Bool {
        get async { await client.isConfigured }
    }

    // MARK: - 只读：取叠加数据

    /// 拿这个条目当前的 TMDb 叠加数据。**不发网络**。
    ///
    /// 返回 nil 的三种情况（调用方都该当作「没有 TMDb 数据」正常渲染）：
    /// 没建立对应关系、对应上了但数据没拉过、拉过但语言对不上。
    public func overlay(for item: MediaItem, tenant: TenantID) async -> TMDbOverlay? {
        guard await client.isConfigured else { return nil }
        let language = preferences.language
        guard let link = try? await store.tmdbLink(itemID: item.id, tenant: tenant) else { return nil }
        guard let cached = try? await store.tmdbPayload(key: link.entityKey, language: language)
        else { return nil }

        switch cached.payload {
        case .entity(let entity):
            return TMDbOverlay(entity: entity, link: link,
                               fetchedAt: cached.fetchedAt, isExpired: cached.isExpired())
        case .season(let season):
            return TMDbOverlay(season: season, link: link,
                               fetchedAt: cached.fetchedAt, isExpired: cached.isExpired())
        }
    }

    /// 取某一季的叠加数据（**不发网络**）。nil = 没缓存过 / 语言对不上。
    ///
    /// 与 `overlay(for:tenant:)` 分开是因为季**没有自己的对应关系**（实测季级
    /// ProviderIds 只有 Tvdb），定位靠「父剧的 tv id + 季号」——所以入口收的是
    /// **父剧的 link**，而不是季条目。
    ///
    /// 剧集页拿它做两件事：切换季时更新简介、给分集卡片提供每集的标题与简介。
    public func seasonOverlay(seriesLink: TMDbLink, seasonNumber: Int) async -> TMDbOverlay? {
        guard await client.isConfigured else { return nil }
        guard case .tv(let tvID) = seriesLink.entityKey else { return nil }
        let key = TMDbEntityKey.season(tvID: tvID, number: seasonNumber)
        guard let cached = try? await store.tmdbPayload(key: key, language: preferences.language)
        else { return nil }
        guard case .season(let season) = cached.payload else { return nil }
        return TMDbOverlay(season: season, link: seriesLink,
                           fetchedAt: cached.fetchedAt, isExpired: cached.isExpired())
    }

    /// 确保某一季的数据可用（缺失则拉、过期则刷）。返回是否发起了网络。
    ///
    /// 与 `seasonOverlay` 配对：先读（立即渲染）、再补（后台拉）。合成一个方法就没法
    /// 离线复用，也会让「切季」这个高频操作卡在一次网络往返上。
    @discardableResult
    public func refreshSeason(seriesLink: TMDbLink, seasonNumber: Int) async -> Bool {
        guard await client.isConfigured else { return false }
        guard case .tv(let tvID) = seriesLink.entityKey else { return false }
        let key = TMDbEntityKey.season(tvID: tvID, number: seasonNumber)
        // 已有且未过期 → 不动。
        if let cached = try? await store.tmdbPayload(key: key, language: preferences.language),
           !cached.isExpired() {
            return false
        }
        return await fetchAndStore(key: key)
    }

    // MARK: - 网络：确保数据可用

    /// 服务端给出的**权威** TMDb id（`ProviderIds["Tmdb"]`）。nil = 没有 / 不可用。
    ///
    /// **只认电影与剧集**：实测集的 `ProviderIds["Tmdb"]` 是**单集 id**（如 3384539），
    /// 剧集 id 是另一个（153217）。拿单集 id 去当剧集 id 会拉到别的剧或 404。
    /// 季则根本没有 Tmdb id（只有 Tvdb）。
    private func authoritativeTmdbID(of item: MediaItem) -> Int? {
        switch item.kind {
        case .movie, .series:
            guard let raw = item.tmdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let id = Int(raw), id > 0
            else { return nil }
            return id
        case .season, .episode:
            return nil
        default:
            // 合集 / 音乐 / 书 / 文件夹… TMDb 的 movie/tv 端点都不适用，一律不用它的 id。
            return nil
        }
    }

    /// 确保该条目的 TMDb 数据可用（缺失则拉、过期则后台刷）。
    ///
    /// - Returns: 这次有没有实际发起网络（供调用方判断是否值得重新读一次 overlay）。
    ///
    /// 流程：已有对应且未过期 → 什么都不做；否则匹配 → 拉数据 → 落库。
    @discardableResult
    public func refresh(item: MediaItem, tenant: TenantID, seriesLink: TMDbLink? = nil) async -> Bool {
        guard await client.isConfigured else { return false }
        let language = preferences.language

        // ① 已有对应且数据够新 → 不动。
        if let link = try? await store.tmdbLink(itemID: item.id, tenant: tenant),
           let cached = try? await store.tmdbPayload(key: link.entityKey, language: language),
           !cached.isExpired() {
            return false
        }

        // ② 决定沿用哪条对应。
        //
        // **权威来源优先**（`isAuthoritative`）：服务端 `ProviderIds` 或用户手动选定
        // 的对应是事实，不该被自动匹配顶掉。反过来，如果当初只能靠**标题搜索猜**
        // （`.search`），而服务端后来补上了 `ProviderIds["Tmdb"]`，那这次就该改用
        // 权威的那个——否则我们会永远抱着一个猜出来的 id（实测库里确实存在
        // 「先入库无 id、后补元数据」的条目）。
        let existingLink = try? await store.tmdbLink(itemID: item.id, tenant: tenant)
        let authoritativeID = authoritativeTmdbID(of: item)
        let shouldRematch: Bool = if let existingLink {
            !existingLink.source.isAuthoritative && authoritativeID != nil
        } else {
            true
        }

        let link: TMDbLink
        if let existingLink, !shouldRematch {
            link = existingLink
        } else {
            let matcher = TMDbMatcher(language: language) { [client] query, type, year, lang in
                try await client.search(query: query, mediaType: type, year: year, language: lang)
            }
            guard let match = await matcher.match(item: item, seriesLink: seriesLink),
                  match.shouldApplyAutomatically
            else { return false }   // 匹配不可信 → 不落库，留给 Phase 3 手动面板
            link = TMDbLink(itemID: item.id, entityKey: match.entityKey, source: match.source,
                            confidence: match.confidence, linkedAt: Date())
            try? await store.saveTMDbLink(itemID: item.id, entityKey: match.entityKey,
                                          source: match.source, confidence: match.confidence,
                                          tenant: tenant)
        }

        return await fetchAndStore(key: link.entityKey, language: language)
    }

    /// 拉取一个实体并落库。返回是否成功。
    @discardableResult
    public func fetchAndStore(key: TMDbEntityKey, language: String? = nil) async -> Bool {
        guard await client.isConfigured else { return false }
        let language = language ?? preferences.language
        let taskKey = "\(key.storageKey)|\(language)"

        // 同一实体的并发请求合并：剧集页与详情页可能同时要它。
        if let running = inFlight[taskKey] {
            await running.value
            return true
        }
        let task = Task { [weak self] in
            // 显式返回 Void：`await self?.performFetch(...)` 的类型是 `()?`，
            // 直接作为 Task 体得到 `Task<()?, Never>`，与字典声明的 `Task<Void, Never>` 不符。
            guard let self else { return }
            await self.performFetch(key: key, language: language)
        }
        inFlight[taskKey] = task
        await task.value
        inFlight[taskKey] = nil
        return true
    }

    private func performFetch(key: TMDbEntityKey, language: String) async {
        do {
            let payload: TMDbEntityPayload
            switch key {
            case .movie(let id):
                payload = .entity(try await client.movie(id: id, language: language))
            case .tv(let id):
                payload = .entity(try await client.tv(id: id, language: language))
            case .season(let tvID, let number):
                payload = .season(try await client.season(tvID: tvID, seasonNumber: number,
                                                          language: language))
            }
            try await store.saveTMDbPayload(payload, key: key, language: language,
                                           lifetime: preferences.cacheLifetime)
            lastFailure = nil
        } catch let error as TMDbError {
            lastFailure = error
            // 失败**不删已有数据**：旧数据比没有强（这正是缓存优先的价值）。
            // 404 例外——那个 id 在 TMDb 不存在，留着对应关系只会每次白查一遍。
            if error == .notFound {
                logger.debug("TMDb 实体不存在 key=\(key.storageKey)")
            } else {
                logger.warning("TMDb 拉取失败 key=\(key.storageKey) error=\(error)")
            }
        } catch {
            lastFailure = .transport("\(error)")
            logger.warning("TMDb 拉取失败 key=\(key.storageKey) error=\(error)")
        }
    }

    /// 最近一次失败（设置页据此提示）。nil = 最近一次是成功的。
    public func reportedFailure() -> TMDbError? { lastFailure }

    // MARK: - 维护

    /// 清过期实体（挂每日存储维护）。
    @discardableResult
    public func evictExpired() async -> Int {
        (try? await store.evictExpiredTMDbEntities()) ?? 0
    }

    /// 清某租户的全部补全数据（设置页「清除 TMDb 数据」）。
    public func clear(tenant: TenantID) async {
        try? await store.clearTMDbData(tenant: tenant)
    }

    /// 已补全条目数（设置页展示）。
    public func linkedCount(tenant: TenantID) async -> Int {
        (try? await store.tmdbLinkCount(tenant: tenant)) ?? 0
    }
}
