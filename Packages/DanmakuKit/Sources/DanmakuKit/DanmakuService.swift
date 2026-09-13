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
    /// 弹幕推导的片头提示（缓存优先，缺失时从正文现算并持久化）。
    /// 弹幕为空时也可能带出历史提示——「跳过片头」不随弹幕正文过期而失效。
    public let introHint: DanmakuIntroHint?

    public init(
        match: DanmakuEpisodeMatch,
        entries: [DanmakuJSONParser.Entry]?,
        json: String?,
        commentCount: Int,
        introHint: DanmakuIntroHint? = nil
    ) {
        self.match = match
        self.entries = entries
        self.json = json
        self.commentCount = commentCount
        self.introHint = introHint
    }
}

/// Coordinates the pure data path: match cache -> gateway match -> comment cache -> JSON.
/// Playback generation checks and Erika mutations remain in the app layer.
public actor DanmakuService {
    private let cache: DanmakuCache

    public init(cache: DanmakuCache) {
        self.cache = cache
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

    /// 永久缓存的片头提示（`DanmakuIntroDetector` 的产物）。
    public func cachedIntroHint(for episodeID: Int64) async -> DanmakuIntroHint? {
        await cache.introHint(for: episodeID)
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
        let hint = await resolveIntroHint(for: match.episodeID, comments: comments)
        return DanmakuPayload(
            match: match,
            entries: DanmakuJSONConverter.entries(from: comments),
            json: DanmakuJSONConverter.erikaJSON(from: comments),
            commentCount: comments.count,
            introHint: hint
        )
    }

    /// 片头提示解析：永久缓存命中直接用；否则从本次正文现算并持久化。
    /// 正文为空时算不出提示，但不覆盖/清除已有提示。
    private func resolveIntroHint(
        for episodeID: Int64,
        comments: [DanmakuComment]
    ) async -> DanmakuIntroHint? {
        if let cached = await cache.introHint(for: episodeID) {
            return cached
        }
        guard let detected = DanmakuIntroDetector.detect(in: comments) else { return nil }
        await cache.setIntroHint(detected, for: episodeID)
        return detected
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
