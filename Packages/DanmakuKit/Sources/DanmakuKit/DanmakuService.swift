import Foundation

/// A renderer-ready comment payload resolved from the permanent match and TTL cache.
public struct DanmakuPayload: Sendable, Equatable {
    public let match: DanmakuEpisodeMatch
    public let json: String?
    public let commentCount: Int

    public init(match: DanmakuEpisodeMatch, json: String?, commentCount: Int) {
        self.match = match
        self.json = json
        self.commentCount = commentCount
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

    /// Claims the current playback generation before any cache/network awaits.
    /// Older cancelled work can no longer overwrite this media mapping.
    public func claimMatchRevision(cacheKey: String, revision: UInt64) async {
        await cache.claimEpisodeMatchRevision(for: cacheKey, revision: revision)
    }

    public func automaticMatch(
        cacheKey: String,
        request: MatchRequest,
        client: DanmakuGatewayClient,
        ignoringCachedMatch: Bool = false,
        persistingResult: Bool = true
    ) async throws -> DanmakuEpisodeMatch? {
        if !ignoringCachedMatch, let cached = await cache.episodeMatch(for: cacheKey) {
            return cached
        }

        let response = try await client.match(request).payload
        try Task.checkCancellation()
        guard response.isMatched == true, let match = response.matches.first else { return nil }
        let selected = DanmakuEpisodeMatch(
            episodeID: match.episodeId,
            shiftSeconds: match.shift ?? 0,
            animeTitle: match.animeTitle,
            episodeTitle: match.episodeTitle
        )
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
        return DanmakuPayload(
            match: match,
            json: DanmakuJSONConverter.erikaJSON(from: comments),
            commentCount: comments.count
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
