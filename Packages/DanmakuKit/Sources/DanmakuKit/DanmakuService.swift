import Foundation

/// A renderer-ready comment payload resolved from the permanent match and TTL cache.
///
/// `entries` 是 overlay 渲染器的直接输入（结构直传，装载侧不再解 JSON）；
/// `json` 只服务内核弹幕轨（`ErikaEngine.addDanmakuTrack`，当前路线停用中）。
/// 两者判据一致、都由本 actor 产出，主线程不做转换。
public struct DanmakuPayload: Sendable, Equatable {
    public let match: DanmakuEpisodeMatch
    public let entries: [DanmakuJSONParser.Entry]?
    public let json: String?
    public let commentCount: Int
    /// 弹幕正文现算出的片头提示（`DanmakuIntroDetector`，未持久化）。
    /// 缓存命中 / AniSkip 解析 / 持久化时机由编排层（`DanmakuLoadOrchestrator`）统一决策。
    public let detectedIntroHint: DanmakuIntroHint?

    public init(
        match: DanmakuEpisodeMatch,
        entries: [DanmakuJSONParser.Entry]?,
        json: String?,
        commentCount: Int,
        detectedIntroHint: DanmakuIntroHint? = nil
    ) {
        self.match = match
        self.entries = entries
        self.json = json
        self.commentCount = commentCount
        self.detectedIntroHint = detectedIntroHint
    }
}

/// Coordinates the pure data path: match cache -> gateway match -> comment cache -> JSON.
/// Playback generation checks and Erika mutations remain in the app layer.
public actor DanmakuService {
    private let cache: DanmakuCache
    /// 缓存根目录（与 `cache.directory` 同源；伴生存储派生目录用）。
    public let cacheDirectory: URL

    public init(cache: DanmakuCache) {
        self.cache = cache
        self.cacheDirectory = cache.directory
    }

    /// Returns the permanent media-to-episode mapping without contacting the gateway.
    /// Callers can use this before doing file or remote hashing work.
    public func cachedMatch(for cacheKey: String) async -> DanmakuEpisodeMatch? {
        await cache.episodeMatch(for: cacheKey)
    }

    /// TTL-cached comments for an episode, or nil when absent/expired. Load-only.
    public func cachedComments(for episodeID: Int64) async -> [DanmakuComment]? {
        await cache.comments(for: episodeID)
    }

    /// 永久缓存的片头提示（弹幕报点 / AniSkip 任一来源）。
    public func cachedIntroHint(for episodeID: Int64) async -> DanmakuIntroHint? {
        await cache.introHint(for: episodeID)
    }

    /// 持久化片头提示（编排层按优先级选出的最终结果）。
    public func persistIntroHint(_ hint: DanmakuIntroHint, for episodeID: Int64) async {
        await cache.setIntroHint(hint, for: episodeID)
    }

    /// Persist comments directly (test seeding; production goes through `payload`).
    public func persistComments(_ comments: [DanmakuComment], for episodeID: Int64) async {
        await cache.setComments(comments, for: episodeID)
    }

    /// Claims the current playback generation before any cache/network awaits.
    /// Older cancelled work can no longer overwrite this media mapping.
    public func claimMatchRevision(cacheKey: String, revision: UInt64) async {
        await cache.claimEpisodeMatchRevision(for: cacheKey, revision: revision)
    }

    /// The highest revision that claimed this media mapping. Writers compare against
    /// this before persisting so stale work cannot clobber newer matches.
    public func claimedRevision(for cacheKey: String) async -> UInt64? {
        await cache.claimedRevision(for: cacheKey)
    }

    public func automaticMatch(
        cacheKey: String,
        request: MatchRequest,
        client: DanmakuGatewayClient,
        targetContext: DanmakuCandidateScorer.TargetContext? = nil,
        ignoringCachedMatch: Bool = false,
        persistingResult: Bool = true
    ) async throws -> DanmakuEpisodeMatch? {
        if !ignoringCachedMatch, let cached = await cache.episodeMatch(for: cacheKey) {
            return cached
        }

        let response = try await client.match(request).payload
        try Task.checkCancellation()

        let match: DanmakuEpisodeMatch?
        if response.isMatched == true, let first = response.matches.first {
            match = DanmakuEpisodeMatch(
                episodeID: first.episodeId,
                shiftSeconds: first.shift ?? 0,
                animeTitle: first.animeTitle,
                episodeTitle: first.episodeTitle
            )
        } else if !response.matches.isEmpty {
            let target: DanmakuCandidateScorer.TargetContext
            if let targetContext {
                target = targetContext
            } else {
                let parsed = DanmakuFilenameParser.parse(request.fileName ?? "")
                target = DanmakuCandidateScorer.TargetContext(
                    animeTitle: parsed.title,
                    episodeNumber: parsed.episodeNumber,
                    seasonNumber: parsed.seasonNumber,
                    isFinal: parsed.isFinal
                )
            }
            match = DanmakuCandidateScorer.pickBestMatch(from: response.matches, target: target)?.match
        } else {
            match = nil
        }

        guard let selected = match else { return nil }
        if persistingResult {
            await cache.setEpisodeMatch(selected, for: cacheKey)
        }
        return selected
    }

    public func payload(
        for match: DanmakuEpisodeMatch,
        client: DanmakuGatewayClient
    ) async throws -> DanmakuPayload {
        let comments: [DanmakuComment]
        if let cached = await cache.comments(for: match.episodeID) {
            comments = cached
        } else {
            let fetched = try await client.comments(episodeId: match.episodeID).payload.comments ?? []
            await cache.setComments(fetched, for: match.episodeID)
            comments = fetched
        }
        let detected = DanmakuIntroDetector.detect(in: comments)
        return DanmakuPayload(
            match: match,
            entries: DanmakuJSONConverter.entries(from: comments),
            json: DanmakuJSONConverter.erikaJSON(from: comments),
            commentCount: comments.count,
            detectedIntroHint: detected
        )
    }

    public func remember(
        episode: Episode,
        animeTitle: String?,
        cacheKey: String,
        revision: UInt64? = nil
    ) async -> DanmakuEpisodeMatch {
        let match = DanmakuEpisodeMatch(
            episodeID: episode.episodeId,
            animeTitle: animeTitle,
            episodeTitle: episode.episodeTitle
        )
        await cache.setEpisodeMatch(match, for: cacheKey, revision: revision)
        return match
    }

    public func remember(
        match: DanmakuEpisodeMatch,
        cacheKey: String,
        revision: UInt64? = nil
    ) async {
        await cache.setEpisodeMatch(match, for: cacheKey, revision: revision)
    }

    public func forgetMatch(cacheKey: String, revision: UInt64? = nil) async {
        await cache.removeEpisodeMatch(for: cacheKey, revision: revision)
    }
}
