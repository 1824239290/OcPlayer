import Foundation

/// Rust playback state projected for platform adapters.
public struct OcpPlaybackSnapshot: Decodable, Sendable {
    public let state: String
    public let source: JSONValue
    public let positionSeconds: Double
    public let durationSeconds: Double?
    public let rate: Double
    public let volume: Double
    public let muted: Bool
    public let audioTrack: String?
    public let subtitleTrack: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        source = try container.decodeIfPresent(JSONValue.self, forKey: .source) ?? .null
        positionSeconds = try container.decodeIfPresent(Double.self, forKey: .positionSeconds) ?? 0
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        audioTrack = try container.decodeIfPresent(String.self, forKey: .audioTrack)
        subtitleTrack = try container.decodeIfPresent(String.self, forKey: .subtitleTrack)
    }

    private enum CodingKeys: String, CodingKey {
        case state, source, positionSeconds, durationSeconds, rate, volume, muted, audioTrack, subtitleTrack
    }
}

/// Synchronous, low-latency adapter for the Rust playback reducer.
///
/// The platform engine remains responsible for decoding and rendering. This session
/// mirrors lifecycle and user intent into Rust so recovery, diagnostics and progress
/// use the same state machine on every platform.
public final class OcpPlaybackSession: @unchecked Sendable {
    public let client: OcpCoreClient
    public private(set) var snapshot: OcpPlaybackSnapshot?

    public init?(client: OcpCoreClient? = nil, libraryPath: String? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do {
            self.client = try client ?? OcpCoreClient(libraryPath: libraryPath)
            snapshot = try Self.decodePlayback(from: self.client.snapshot(kind: "playback"))
        } catch {
            return nil
        }
    }

    public func open(uri: String, headers: [String: String] = [:], sourceID: String? = nil,
                     alternates: [[String: Any]] = []) throws {
        var source: [String: Any] = ["uri": uri]
        if !headers.isEmpty { source["headers"] = headers }
        var arguments: [String: Any] = ["source": source]
        if let sourceID { arguments["sourceId"] = sourceID }
        if !alternates.isEmpty { arguments["candidates"] = alternates }
        try update(with: client.call("playback.open", arguments: arguments))
    }

    public func ready(durationSeconds: Double?) throws { try command("playback.ready", args: durationSeconds.map { ["durationSeconds": $0] } ?? [:]) }
    public func play() throws { try command("playback.play") }
    public func pause() throws { try command("playback.pause") }
    public func stop() throws { try command("playback.stop") }
    public func ended() throws { try command("playback.ended") }
    public func failed(category: String, message: String, retryable: Bool = false,
                       stopsAutomaticRecovery: Bool = false, recordOnly: Bool = false) throws {
        try command("playback.failed", args: [
            "category": category,
            "message": message,
            "retryable": retryable,
            "stopsAutomaticRecovery": stopsAutomaticRecovery,
            "recordOnly": recordOnly,
        ])
    }
    public func seek(seconds: Double) throws { try command("playback.seek", args: ["positionSeconds": seconds]) }
    public func updatePosition(seconds: Double, durationSeconds: Double? = nil) throws {
        var args: [String: Any] = ["positionSeconds": seconds]
        if let durationSeconds { args["durationSeconds"] = durationSeconds }
        try command("playback.position", args: args, fallback: "playback.seek")
    }
    public func setRate(_ rate: Double) throws { try command("playback.setRate", args: ["rate": rate]) }
    public func refresh() throws { snapshot = try Self.decodePlayback(from: client.snapshot(kind: "playback")) }
    public func setMuted(_ muted: Bool) throws { try command("playback.setMuted", args: ["muted": muted]) }
    public func setVolume(_ volume: Double) throws { try command("playback.setVolume", args: ["volume": volume]) }
    public func selectAudio(_ trackID: String?) throws { try command("playback.selectAudio", args: ["trackId": trackID as Any]) }
    public func selectSubtitle(_ trackID: String?) throws { try command("playback.selectSubtitle", args: ["trackId": trackID as Any]) }

    private func command(_ method: String, args: [String: Any] = [:], fallback: String? = nil) throws {
        do {
            try update(with: client.call(method, arguments: args))
        } catch let error as OcpCoreError where fallback != nil && error.message.contains("unknown method") {
            try update(with: client.call(fallback!, arguments: args))
        }
    }

    private func update(with response: OcpResponse) throws {
        guard response.ok else { throw OcpCoreError(message: response.message) }
        if case .object(let object) = response.data, let value = object["playback"] {
            snapshot = try value.decode(OcpPlaybackSnapshot.self)
        }
    }

    private static func decodePlayback(from value: JSONValue) throws -> OcpPlaybackSnapshot {
        if case .object(let object) = value, let playback = object["playback"] {
            return try playback.decode(OcpPlaybackSnapshot.self)
        }
        return try value.decode(OcpPlaybackSnapshot.self)
    }
}
