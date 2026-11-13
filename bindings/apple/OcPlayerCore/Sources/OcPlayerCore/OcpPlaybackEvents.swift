import Foundation

/// Shared event ownership and failure folding. Native adapters retain rendering,
/// Observation publishing and elapsed-time logging.
public final class OcpPlaybackEvents: @unchecked Sendable {
    public struct Failure: Decodable, Sendable { public let code: Int32; public let message: String? }
    public struct Snapshot: Decodable, Sendable {
        public let generation: UInt64
        public let state: String
        public let positionSeconds: Double
        public let durationSeconds: Double
        public let errorCount: UInt64
        public let failure: Failure?
        public let foldedStaleTailFailure: Bool
    }
    public struct Decision: Decodable, Sendable {
        public let accepted: Bool
        public let reportedFailure: Bool
        public let foldedTailFailure: Bool
        public let snapshot: Snapshot
    }
    public let client: OcpCoreClient
    public private(set) var snapshot: Snapshot
    public init?(client: OcpCoreClient? = nil, libraryPath: String? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do {
            self.client = try client ?? OcpCoreClient(libraryPath: libraryPath)
            let response = try self.client.call("playbackEvents.begin")
            guard response.ok else { return nil }
            snapshot = try response.data.decode(Snapshot.self)
        } catch { return nil }
    }
    public func reset() throws {
        let response = try client.call("playbackEvents.begin")
        guard response.ok else { throw OcpCoreError(message: response.message) }
        snapshot = try response.data.decode(Snapshot.self)
    }
    public func apply(_ event: [String: Any]) throws -> Decision {
        let response = try client.call("playbackEvents.apply", arguments: ["generation": snapshot.generation, "event": event])
        guard response.ok else { throw OcpCoreError(message: response.message) }
        let decision = try response.data.decode(Decision.self)
        // A stale adapter must retain its old generation; it cannot adopt the
        // new engine merely by receiving a snapshot from a rejected event.
        if decision.accepted { snapshot = decision.snapshot }
        return decision
    }
}
