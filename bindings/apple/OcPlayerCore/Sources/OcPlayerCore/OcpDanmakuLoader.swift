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
    public let animeID: Int64?
    public let shift: Int?
    public let animeTitle: String?
    public let episodeTitle: String?

    private enum CodingKeys: String, CodingKey {
        case episodeID = "episodeId"
        case animeID = "animeId"
        case shift, animeTitle, episodeTitle
    }
}

public struct OcpDanmakuEpisodePayload: Decodable, Sendable, Equatable {
    public let candidate: OcpDanmakuMatch
    public let count: Int
    public let comments: [OcpDanmakuEntry]
    public let entries: [OcpDanmakuEntry]?
    public let json: String?
    public let rawCommentCount: Int?
    public let introHint: OcpDanmakuIntroHint?
}

public struct OcpDanmakuLoadResult: Decodable, Sendable, Equatable {
    public let match: OcpDanmakuMatchResponse
    public let episodes: [OcpDanmakuEpisodePayload]
    public let outcome: OcpDanmakuLoadOutcome?
    public let diagnostics: OcpDanmakuLoadDiagnostics?
}

public struct OcpDanmakuIntroHint: Decodable, Sendable, Equatable {
    public let startSeconds: Double?
    public let endSeconds: Double
    public let evidenceCount: Int
    public let source: String
}

public struct OcpDanmakuLoadOutcome: Decodable, Sendable, Equatable {
    public let kind: String
    public let episodeID: Int64?
    public let commentCount: Int?
    public let title: String?
    public let introHint: OcpDanmakuIntroHint?
}

public struct OcpDanmakuLoadDiagnostics: Decodable, Sendable, Equatable {
    public let budgetDidCut: Bool
    public let tiersAttempted: Int
    public let fingerprintFailed: Bool
}

public struct OcpDanmakuMatchResponse: Decodable, Sendable, Equatable {
    public let success: Bool
    public let matches: [OcpDanmakuMatch]
}

/// Data consumer for the same state machine used by the native player. Core
/// owns matching, cache policy, payload conversion and complete intro resolution.
/// The host supplies media context/provider availability and consumes the result.
public final class OcpDanmakuLoader: @unchecked Sendable {
    private let core: OcpCoreClient

    public init(core: OcpCoreClient) {
        self.core = core
    }

    public func load(
        gateway: [String: Any],
        matchRequest: [String: Any],
        requestID: String? = nil,
        configuration: [String: Any] = [:],
        cacheKey: String? = nil,
        revision: UInt64? = nil,
        aliases: [String] = [],
        providers: [String: Any] = [:],
        format: String = "both",
        filePath: String? = nil,
        timeoutSeconds: Double = 30,
        retryAttempts: Int = 3
    ) async throws -> OcpDanmakuLoadResult {
        var arguments: [String: Any] = [
            "gateway": gateway,
            "matchRequest": matchRequest,
            "configuration": String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self),
            "aliases": aliases,
            "providers": providers,
            "format": format,
            "timeoutSeconds": timeoutSeconds,
            "retryAttempts": retryAttempts,
        ]
        if let requestID { arguments["requestId"] = requestID }
        if let cacheKey { arguments["cacheKey"] = cacheKey }
        if let revision { arguments["revision"] = revision }
        if let filePath { arguments["filePath"] = filePath }
        let response = try await core.callAsync(
            "danmaku.load",
            argumentsJSON: String(
                decoding: JSONSerialization.data(withJSONObject: arguments),
                as: UTF8.self))
        guard response.ok else { throw OcpCoreError(message: response.message) }
        struct Payload: Decodable { let payloadJSON: String }
        let payload = try response.data.decode(Payload.self)
        return try JSONDecoder().decode(OcpDanmakuLoadResult.self, from: Data(payload.payloadJSON.utf8))
    }
}
