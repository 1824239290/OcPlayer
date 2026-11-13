import Foundation

/// Platform-neutral danmaku entry produced by the Rust core. The host maps the
/// three render modes to its overlay or native player track types.
public struct OcpDanmakuEntry: Decodable, Sendable, Equatable {
    public let time: Double
    public let mode: String
    public let color: UInt32
    public let text: String
}

public struct OcpDanmakuMatch: Decodable, Sendable, Equatable {
    public let episodeID: Int64
    public let shift: Int?
    public let animeTitle: String?
    public let episodeTitle: String?

    private enum CodingKeys: String, CodingKey {
        case episodeID = "episodeId"
        case shift, animeTitle, episodeTitle
    }
}

public struct OcpDanmakuEpisodePayload: Decodable, Sendable, Equatable {
    public let candidate: OcpDanmakuMatch
    public let count: Int
    public let comments: [OcpDanmakuEntry]
}

public struct OcpDanmakuLoadResult: Decodable, Sendable, Equatable {
    public let match: OcpDanmakuMatchResponse
    public let episodes: [OcpDanmakuEpisodePayload]
}

public struct OcpDanmakuMatchResponse: Decodable, Sendable, Equatable {
    public let success: Bool
    public let matches: [OcpDanmakuMatch]
}

/// Thin async adapter for `danmaku.load`; caching and UI remain host concerns so
/// the same contract can be consumed by Swift and the future Windows adapter.
public final class OcpDanmakuLoader: @unchecked Sendable {
    private let core: OcpCoreClient

    public init(core: OcpCoreClient) {
        self.core = core
    }

    public func load(
        gateway: [String: Any],
        matchRequest: [String: Any],
        requestID: String? = nil
    ) async throws -> OcpDanmakuLoadResult {
        var arguments: [String: Any] = [
            "gateway": gateway,
            "matchRequest": matchRequest,
        ]
        if let requestID { arguments["requestId"] = requestID }
        let response = try await core.callAsync(
            "danmaku.load",
            argumentsJSON: String(
                decoding: JSONSerialization.data(withJSONObject: arguments),
                as: UTF8.self))
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.data.decode(OcpDanmakuLoadResult.self)
    }
}
