import Foundation

/// 弹幕本地缓存：两层结构。
///
/// 1. 剧集映射（`媒体标识 → episodeId + shift`）——永久保留，同一集不重复请求网关。
/// 2. 弹幕正文——按 TTL 过期（默认 3600s，对齐网关弹幕缓存），命中直接喂内核
///    不再回源。缓存放 `Application Support/OcPlayer/Danmaku/`，目录可注入便于测试。
///
/// 缓存文件按 `mapping.json` 与 `comments-<episodeId>.json` 分离；并发写入由 actor 隔离。
public actor DanmakuCache {
    private let directory: URL
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

    /// nil 表示文件不存在（可安全创建新映射）；非 nil 但读取/解码失败时返回
    /// nil 并阻止写入，避免临时 I/O 错误覆盖已有映射。
    private func loadMapping() -> [String: DanmakuEpisodeMatch]? {
        let url = mappingURL()
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let mapping = try? decoder.decode([String: DanmakuEpisodeMatch].self, from: data) {
            return mapping
        }
        // Migrate the original `mediaID: episodeID` format without discarding
        // existing matches. The next successful write persists the new shape.
        if let legacy = try? decoder.decode([String: Int64].self, from: data) {
            return legacy.mapValues { DanmakuEpisodeMatch(episodeID: $0) }
        }
        return nil
    }

    private func saveMapping(_ mapping: [String: DanmakuEpisodeMatch]) {
        guard let data = try? encoder.encode(mapping) else { return }
        try? data.write(to: mappingURL(), options: .atomic)
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
        if Date().timeIntervalSince(entry.fetchedAt) > commentsTTL { return nil }
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

    // MARK: 测试辅助

    /// 清空整个缓存目录（仅供测试与诊断使用）。
    func purge() {
        latestMappingRevision.removeAll()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
