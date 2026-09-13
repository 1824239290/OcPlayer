import Foundation

/// 弹幕本地缓存：两层结构。
///
/// 1. 剧集映射（`媒体标识 → episodeId + shift`）——永久保留，同一集不重复请求网关。
/// 2. 弹幕正文——按 TTL 过期（默认 3600s，对齐网关弹幕缓存），命中直接喂内核
///    不再回源。缓存放 `Application Support/OcPlayer/Danmaku/`，目录可注入便于测试。
///
/// 缓存文件按 `mapping.json` 与 `comments-<episodeId>.json` 分离；并发写入由 actor 隔离。
public actor DanmakuCache {
    /// 缓存根目录（`mapping.json` / `comments-*.json` / `intro-hints.json` 等都在这）。
    /// 不可变值，跨隔离域只读（编排层派生同目录的伴生存储用）。
    nonisolated public let directory: URL
    private let commentsTTL: TimeInterval
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var latestMappingRevision: [String: UInt64] = [:]

    public init(
        directory: URL,
        commentsTTL: TimeInterval = 3600,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.commentsTTL = commentsTTL
        self.fileManager = fileManager
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

    public func comments(for episodeID: Int64) -> [DanmakuComment]? {
        let url = commentsURL(episodeID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? decoder.decode(CachedComments.self, from: data) else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > commentsTTL {
            // 过期即删：TTL 只影响读取的话，过期文件会永远躺在盘上
            //（每集一份弹幕正文，几十 MB 很快就堆出来）。
            try? fileManager.removeItem(at: url)
            return nil
        }
        return entry.comments
    }

    public func setComments(_ comments: [DanmakuComment], for episodeID: Int64) {
        let entry = CachedComments(fetchedAt: Date(), comments: comments)
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: commentsURL(episodeID), options: .atomic)
    }

    private func commentsURL(_ episodeID: Int64) -> URL {
        directory.appendingPathComponent("comments-\(episodeID).json")
    }

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
    }
}

/// The stable part of a dandanplay match that must survive comment-cache expiry.
public struct DanmakuEpisodeMatch: Codable, Sendable, Equatable {
    public let episodeID: Int64
    public let shiftSeconds: Int
    public let animeTitle: String?
    public let episodeTitle: String?

    public init(
        episodeID: Int64,
        shiftSeconds: Int = 0,
        animeTitle: String? = nil,
        episodeTitle: String? = nil
    ) {
        self.episodeID = episodeID
        self.shiftSeconds = shiftSeconds
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
    }
}
