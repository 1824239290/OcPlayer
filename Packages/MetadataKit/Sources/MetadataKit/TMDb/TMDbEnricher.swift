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

    /// `internal`（不是 `private`）：批量补全与手动匹配放在 `TMDbBatch.swift` 的扩展里。
    let client: TMDbClient
    /// `internal`（不是 `private`）：批量补全放在 `TMDbBatch.swift` 的扩展里，
    /// 跨文件访问需要 ≥ internal。对外仍是 `public actor` 封装，不泄露给使用方。
    let store: MetadataStore
    /// `internal`：同上（扩展文件要用）。
    let preferences: TMDbPreferences
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
    /// - Returns: 这次有没有**实际拉到数据**（供调用方判断是否值得重新读一次 overlay）。
    ///
    /// 流程：已有对应且未过期 → 什么都不做；否则匹配 → 拉数据 → 落库。
    @discardableResult
    public func refresh(item: MediaItem, tenant: TenantID, seriesLink: TMDbLink? = nil) async -> Bool {
        await performRefresh(item: item, tenant: tenant, seriesLink: seriesLink) == .fetched
    }

    /// 一次补全尝试的结局。批量补全据此分类统计（「多少条已是最新 / 拉到 / 匹配不上 /
    /// 拉取失败」），比只返回一个 Bool 有用得多——那四件事对用户的意义完全不同。
    enum RefreshOutcome: Sendable, Equatable {
        /// 已有对应且数据未过期，**没发请求**。
        case skipped
        /// 发了请求并成功落库。
        case fetched
        /// 匹配不上（没有可信的候选），或已有对应但**确实没有数据**。
        /// 与 `.failed` 分开：这个不是故障，是「TMDb 上没有 / 认不出来」。
        case noMatch
        /// 发了请求但失败（网络 / 401 / 429 / 404…）。
        case failed

        var didFetch: Bool { self == .fetched }
    }

    func performRefresh(
        item: MediaItem,
        tenant: TenantID,
        seriesLink: TMDbLink? = nil
    ) async -> RefreshOutcome {
        guard await client.isConfigured else { return .noMatch }
        let language = preferences.language

        // ① 已有对应且数据够新 → 不动。
        if let link = try? await store.tmdbLink(itemID: item.id, tenant: tenant),
           let cached = try? await store.tmdbPayload(key: link.entityKey, language: language),
           !cached.isExpired() {
            return .skipped
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
            else { return .noMatch }   // 匹配不可信 → 不落库，留给手动匹配面板
            link = TMDbLink(itemID: item.id, entityKey: match.entityKey, source: match.source,
                            confidence: match.confidence, linkedAt: Date())
            try? await store.saveTMDbLink(itemID: item.id, entityKey: match.entityKey,
                                          source: match.source, confidence: match.confidence,
                                          tenant: tenant)
        }

        // 已有对应但库里没有数据（上次拉失败了）：这一次的结果就是成败本身。
        let hadPayload = (try? await store.tmdbPayload(key: link.entityKey, language: language)) != nil
        let ok = await fetchAndStore(key: link.entityKey, language: language)
        if ok { return .fetched }
        return hadPayload ? .skipped : .failed
    }

    /// 拉取一个实体并落库。
    ///
    /// - Returns: 库里现在**有没有**这个实体的数据（成功写入 true；失败且原先也没有
    ///   false）。批量补全据此统计成功/失败，所以不能再像早先那样恒返回 true。
    @discardableResult
    public func fetchAndStore(key: TMDbEntityKey, language: String? = nil) async -> Bool {
        guard await client.isConfigured else { return false }
        let language = language ?? preferences.language
        let taskKey = "\(key.storageKey)|\(language)"

        // 同一实体的并发请求合并：剧集页与详情页可能同时要它。
        if let running = inFlight[taskKey] {
            await running.value
            return (try? await store.tmdbPayload(key: key, language: language)) != nil
        }
        let task = Task { [weak self] in
            // 显式返回 Void：`await self?.performFetch(...)` 的类型是 `()?`，
            // 直接作为 Task 体得到 `Task<()?, Never>`，与字典声明的 `Task<Void, Never>` 不符。
            guard let self else { return }
            _ = await self.performFetch(key: key, language: language)
        }
        inFlight[taskKey] = task
        await task.value
        inFlight[taskKey] = nil
        return (try? await store.tmdbPayload(key: key, language: language)) != nil
    }

    /// 真正发请求并落库。
    ///
    /// - Returns: 数据是否已写进库（批量补全据此统计，所以不能只看「有没有抛错」——
    ///   有些失败是静默 return 的）。
    @discardableResult
    private func performFetch(key: TMDbEntityKey, language: String) async -> Bool {
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
            return true
        } catch let error as TMDbError {
            lastFailure = error
            // 失败**不删已有数据**：旧数据比没有强（这正是缓存优先的价值）。
            //
            // ## 404 的现状与为什么不加退避
            //
            // 404 = 服务端 `ProviderIds["Tmdb"]` 里的 id 在 TMDb 不存在。当前表现是：
            // 该条目**每次打开详情页白打一次请求**，而且因为权威对应不会被自动匹配
            // 顶掉，它也**永远不会退回标题搜索**（等于永久补全不了）。
            //
            // 明知如此仍然不加退避，是因为**实测本机库没有这种条目**：全量 41 个带 Tmdb id
            // 的电影/剧**全部有效**（0 个 404，也没有「电影挂了剧集 id」的类型不符）。而修它需要 v3 迁移 + 一套失败
            // 重试策略，收益是「避免一个没有发生的请求」——不值得。
            //
            // 将来若真出现（换库 / 刮削器写错 id / 类型不符如电影挂了剧集 id），
            // 正确做法是在 `tmdb_link` 上记失败时间，N 天内直接跳过；顺带可以在
            // 权威 id 失效时**退回标题搜索**，让条目仍有机会被补全。
            if error == .notFound {
                logger.debug("TMDb 实体不存在 key=\(key.storageKey)")
            } else {
                logger.warning("TMDb 拉取失败 key=\(key.storageKey) error=\(error)")
            }
        } catch {
            lastFailure = .transport("\(error)")
            logger.warning("TMDb 拉取失败 key=\(key.storageKey) error=\(error)")
        }
        return false
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
