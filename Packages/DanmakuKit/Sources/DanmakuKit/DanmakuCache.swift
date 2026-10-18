import Foundation

/// 弹幕本地缓存：两层结构。
///
/// 1. 剧集映射（`媒体标识 → episodeId + shift`）——永久保留，同一集不重复请求网关。
/// 2. 弹幕正文——按 TTL 过期（默认 3600s，对齐网关弹幕缓存），命中直接喂内核
///    不再回源。缓存放 `Application Support/OcPlayer/Danmaku/`，目录可注入便于测试。
///
/// 缓存文件按 `mapping.json` 与 `comments-<episodeId>.json` 分离；并发写入由 actor 隔离。
///
/// ## 三层都有写穿内存缓存，但正文那层**必须是有界的**
///
/// `mapping` / `intro-hints` 是几百字节的小字典，常驻无妨；弹幕正文每集是
/// **0.1–0.8 MB 的 JSON、上千条记录**（本机真实缓存：23 个文件共 6.4 MB，
/// 最大一份 756 KB / 8159 条）。无界常驻几十集就是几十 MB，而本 App 的真实
/// 峰值 RSS 已经到过 435 MB —— 那等于拿内存告警换一次十几毫秒的磁盘读。
///
/// 所以正文缓存按**最近使用**只留 `commentsMemoryCapacity` 集（默认 2：当前这集
/// 与刚切走的那集）。这正是它唯一要覆盖的场景——换源 / 重试 / 手动选集后
/// 重新装载同一集。
public actor DanmakuCache {
    // MARK: - 落盘文件名（与 App 的定期清理共享的单一事实源）

    /// 弹幕**正文缓存**的文件名前缀：本目录里**唯一**该被定期清理淘汰的东西。
    ///
    /// `StorageMaintenance` 用它做白名单。为什么是白名单而不是"排除永久文件"：
    /// 淘汰按修改时间最旧优先，而永久数据写得最少、mtime 最旧 —— 于是会被**最先删掉**。
    /// 何况本目录 5 个文件里 4 个是永久的，只有 `comments-*` 是缓存：白名单更简短，
    /// 且将来新增永久文件天然安全。
    nonisolated public static let commentsFilePrefix = "comments-"

    /// 本目录下的**永久性**文件（丢了没法重建，或会持续回源）。
    /// 既给清理逻辑做第二道保险，也把「哪些文件是永久的」集中在一处。
    nonisolated public static let permanentFileNames: Set<String> = [
        "mapping.json",          // 剧集 ↔ 弹幕库映射
        "intro-hints.json",      // 片头落点提示（跳过片头用）
        "title-aliases.json",    // 手动别名合并
        "aniskip-ids.json",      // MAL ID 解析结果
        "learned-intros.json",   // 手动跳过学习（anime 级片头落点）
    ]

    /// 缓存根目录（`mapping.json` / `comments-*.json` / `intro-hints.json` 等都在这）。
    /// 不可变值，跨隔离域只读（编排层派生同目录的伴生存储用）。
    nonisolated public let directory: URL
    private let commentsTTL: TimeInterval
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var latestMappingRevision: [String: UInt64] = [:]

    // MARK: 正文内存缓存（有界，见类型注释）

    /// 最近读/写过的正文，键是 episodeID。值带上 `fetchedAt`，命中时仍要校验 TTL。
    private var commentsCache: [Int64: CachedComments] = [:]
    /// 最近使用顺序：**尾 = 最近使用**。容量满了从头部淘汰。
    private var commentsCacheOrder: [Int64] = []
    /// 最多常驻几集。0 = 关闭（测试与极端低内存场景）。
    private let commentsMemoryCapacity: Int

    public init(
        directory: URL,
        commentsTTL: TimeInterval = 3600,
        fileManager: FileManager = .default,
        commentsMemoryCapacity: Int = 2
    ) {
        self.directory = directory
        self.commentsTTL = commentsTTL
        self.fileManager = fileManager
        self.commentsMemoryCapacity = max(0, commentsMemoryCapacity)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: 剧集映射（永久）

    public func episodeMatch(for mediaID: String) -> DanmakuEpisodeMatch? {
        guard let mapping = loadMapping() else { return nil }
        return mapping[mediaID]
    }

    /// Advances the in-memory write barrier without touching the cache file.
    public func claimEpisodeMatchRevision(for mediaID: String, revision: UInt64) {
        _ = acceptMappingMutation(for: mediaID, revision: revision)
    }

    /// The highest revision that has claimed this media mapping (in-memory only).
    public func claimedRevision(for mediaID: String) -> UInt64? {
        latestMappingRevision[mediaID]
    }

    public func setEpisodeMatch(
        _ match: DanmakuEpisodeMatch,
        for mediaID: String,
        revision: UInt64? = nil
    ) {
        // A read/decode failure is not an empty mapping. Do not overwrite a
        // possibly recoverable cache with a new one-entry file.
        guard var mapping = loadMapping() else { return }
        guard acceptMappingMutation(for: mediaID, revision: revision) else { return }
        mapping[mediaID] = match
        saveMapping(mapping)
    }

    public func removeEpisodeMatch(for mediaID: String, revision: UInt64? = nil) {
        guard var mapping = loadMapping() else { return }
        guard acceptMappingMutation(for: mediaID, revision: revision) else { return }
        if mapping.removeValue(forKey: mediaID) != nil {
            saveMapping(mapping)
        }
    }

    public func episodeID(for mediaID: String) -> Int64? {
        episodeMatch(for: mediaID)?.episodeID
    }

    /// 全部已记录的匹配（跨集提示聚合用）。
    public func allEpisodeMatches() -> [DanmakuEpisodeMatch] {
        Array((loadMapping() ?? [:]).values)
    }

    public func setEpisodeID(_ episodeID: Int64, for mediaID: String) {
        setEpisodeMatch(DanmakuEpisodeMatch(episodeID: episodeID), for: mediaID)
    }

    private func mappingURL() -> URL {
        directory.appendingPathComponent("mapping.json")
    }

    /// mapping 内存缓存（写穿）。nil = 尚未加载；读取/解码失败的失败态**不缓存**，
    /// 保持每次重读盘以自愈（否则一次临时 I/O 错误会让写入被永久阻断）。
    private var cachedMapping: [String: DanmakuEpisodeMatch]?
    private var mappingCacheLoaded = false

    /// nil 表示文件不存在（可安全创建新映射）；非 nil 但读取/解码失败时返回
    /// nil 并阻止写入，避免临时 I/O 错误覆盖已有映射。
    private func loadMapping() -> [String: DanmakuEpisodeMatch]? {
        if mappingCacheLoaded, let cached = cachedMapping { return cached }
        let url = mappingURL()
        guard fileManager.fileExists(atPath: url.path) else {
            cachedMapping = [:]
            mappingCacheLoaded = true
            return [:]
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let mapping = try? decoder.decode([String: DanmakuEpisodeMatch].self, from: data) {
            cachedMapping = mapping
            mappingCacheLoaded = true
            return mapping
        }
        // Migrate the original `mediaID: episodeID` format without discarding
        // existing matches. The next successful write persists the new shape.
        if let legacy = try? decoder.decode([String: Int64].self, from: data) {
            let mapping = legacy.mapValues { DanmakuEpisodeMatch(episodeID: $0) }
            cachedMapping = mapping
            mappingCacheLoaded = true
            return mapping
        }
        return nil
    }

    private func saveMapping(_ mapping: [String: DanmakuEpisodeMatch]) {
        guard let data = try? encoder.encode(mapping) else { return }
        try? data.write(to: mappingURL(), options: .atomic)
        cachedMapping = mapping
        mappingCacheLoaded = true
    }

    private func acceptMappingMutation(for mediaID: String, revision: UInt64?) -> Bool {
        guard let revision else {
            latestMappingRevision.removeValue(forKey: mediaID)
            return true
        }
        guard revision >= (latestMappingRevision[mediaID] ?? 0) else { return false }
        latestMappingRevision[mediaID] = revision
        return true
    }

    // MARK: 弹幕正文（带 TTL）

    /// 先查内存、再读盘。**命中内存也要校验 TTL** —— 条目里带着 `fetchedAt`，
    /// 而长会话（>1 小时）里内存会一直返回过期弹幕，磁盘路径本来会删掉它。
    ///
    /// ## 内存条目过期后**不能**照着它删文件
    ///
    /// 内存里的 `fetchedAt` 是本实例的旧快照，而盘上那份可能已被**另一个实例**
    /// 刷新过（预览、重建 `AppModel`、测试里多实例同目录都是真实写法）。实测过的
    /// 坏路径：A 的内存条目过期 → A 读一次 → 把 B 刚写进去的新文件删掉。
    ///
    /// 所以这里只丢内存、**落到磁盘路径继续判断**：那份数据由 `diskComments` 先解码、
    /// 再按**盘上自己的** `fetchedAt` 决定是返回、还是真过期后删除。
    public func comments(for episodeID: Int64) -> [DanmakuComment]? {
        let now = Date()

        if let entry = commentsCache[episodeID] {
            if now.timeIntervalSince(entry.fetchedAt) <= commentsTTL {
                touchCommentsInMemory(episodeID)
                return entry.comments
            }
            forgetCommentsInMemory(episodeID)
        }

        return diskComments(for: episodeID, now: now)
    }

    /// 磁盘路径：解码 → 按**盘上那份**的 `fetchedAt` 判 TTL → 过期才删。
    private func diskComments(for episodeID: Int64, now: Date) -> [DanmakuComment]? {
        let url = commentsURL(episodeID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 解码失败**不进内存**：一次临时损坏不该被永久记住（与 `loadMapping` 的保守策略一致）。
        guard let entry = try? decoder.decode(CachedComments.self, from: data) else { return nil }
        guard now.timeIntervalSince(entry.fetchedAt) <= commentsTTL else {
            // 过期即删：TTL 只影响读取的话，过期文件会永远躺在盘上
            //（每集一份弹幕正文，几十 MB 很快就堆出来）。
            try? fileManager.removeItem(at: url)
            return nil
        }
        rememberCommentsInMemory(entry, for: episodeID)
        return entry.comments
    }

    public func setComments(_ comments: [DanmakuComment], for episodeID: Int64) {
        let entry = CachedComments(fetchedAt: Date(), comments: comments)
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: commentsURL(episodeID), options: .atomic)
        rememberCommentsInMemory(entry, for: episodeID)
    }

    private func commentsURL(_ episodeID: Int64) -> URL {
        directory.appendingPathComponent("comments-\(episodeID).json")
    }

    /// 写穿内存并维持 LRU 顺序。淘汰只丢内存，**不删文件** —— 删了就把缓存变成丢数据。
    private func rememberCommentsInMemory(_ entry: CachedComments, for episodeID: Int64) {
        guard commentsMemoryCapacity > 0 else { return }
        commentsCache[episodeID] = entry
        touchCommentsInMemory(episodeID)
        while commentsCacheOrder.count > commentsMemoryCapacity {
            let evicted = commentsCacheOrder.removeFirst()
            commentsCache.removeValue(forKey: evicted)
        }
    }

    private func touchCommentsInMemory(_ episodeID: Int64) {
        if let index = commentsCacheOrder.firstIndex(of: episodeID) {
            commentsCacheOrder.remove(at: index)
        }
        commentsCacheOrder.append(episodeID)
    }

    private func forgetCommentsInMemory(_ episodeID: Int64) {
        commentsCache.removeValue(forKey: episodeID)
        commentsCacheOrder.removeAll { $0 == episodeID }
    }

    /// 当前常驻的集数（诊断与测试用）。
    public var commentsMemoryCount: Int { commentsCache.count }

    private struct CachedComments: Codable {
        let fetchedAt: Date
        let comments: [DanmakuComment]
    }

    // MARK: 片头提示（永久）

    /// 弹幕推导的片头提示（`DanmakuIntroDetector` 的产物），按 episodeID 永久保存。
    /// 弹幕正文有 TTL 会过期重拉，提示一旦成立就常驻，即使之后网关不可达、
    /// 弹幕拉不到，「跳过片头」也照常可用。
    public func introHint(for episodeID: Int64) -> DanmakuIntroHint? {
        loadIntroHints()?[String(episodeID)]
    }

    public func setIntroHint(_ hint: DanmakuIntroHint, for episodeID: Int64) {
        var hints = loadIntroHints() ?? [:]
        hints[String(episodeID)] = hint
        saveIntroHints(hints)
    }

    private func introHintsURL() -> URL {
        directory.appendingPathComponent("intro-hints.json")
    }

    /// 提示文件可随时由弹幕正文重新推导，损坏即视为空并允许覆盖
    /// （与 mapping「读失败阻止写入」的保守策略不同：这里的代价只是重算一遍）。
    private func loadIntroHints() -> [String: DanmakuIntroHint]? {
        if introHintsLoaded, let cached = cachedIntroHints { return cached }
        let url = introHintsURL()
        guard fileManager.fileExists(atPath: url.path) else {
            cachedIntroHints = [:]
            introHintsLoaded = true
            return [:]
        }
        guard let data = try? Data(contentsOf: url),
              let hints = try? decoder.decode([String: DanmakuIntroHint].self, from: data)
        else { return nil }
        cachedIntroHints = hints
        introHintsLoaded = true
        return hints
    }

    private func saveIntroHints(_ hints: [String: DanmakuIntroHint]) {
        guard let data = try? encoder.encode(hints) else { return }
        try? data.write(to: introHintsURL(), options: .atomic)
        cachedIntroHints = hints
        introHintsLoaded = true
    }

    private var cachedIntroHints: [String: DanmakuIntroHint]?
    private var introHintsLoaded = false

    // MARK: 测试辅助

    /// 清空整个缓存目录（仅供测试与诊断使用）。
    func purge() {
        latestMappingRevision.removeAll()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        cachedMapping = nil
        mappingCacheLoaded = false
        cachedIntroHints = nil
        introHintsLoaded = false
        commentsCache.removeAll()
        commentsCacheOrder.removeAll()
    }
}

/// The stable part of a dandanplay match that must survive comment-cache expiry.
public struct DanmakuEpisodeMatch: Codable, Sendable, Equatable {
    public let episodeID: Int64
    public let shiftSeconds: Int
    /// 网关返回的 animeId。旧缓存记录没有该字段（解码为 nil）——跨集提示聚合
    /// 时回退 `derivedAnimeID` 按位段推导。
    public let animeID: Int64?
    public let animeTitle: String?
    public let episodeTitle: String?

    public init(
        episodeID: Int64,
        shiftSeconds: Int = 0,
        animeID: Int64? = nil,
        animeTitle: String? = nil,
        episodeTitle: String? = nil
    ) {
        self.episodeID = episodeID
        self.shiftSeconds = shiftSeconds
        self.animeID = animeID
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
    }

    /// dandanplay 位段约定：episodeID = animeID × 10000 + 集号（低 4 位）。
    /// 实测样本全部吻合（8419→84190003、14236→142360009）。位数不足视为不可推导。
    public var derivedAnimeID: Int64? {
        episodeID >= 10_000 ? episodeID / 10_000 : nil
    }
}
