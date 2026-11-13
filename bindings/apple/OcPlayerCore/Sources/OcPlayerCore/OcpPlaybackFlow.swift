import Foundation

/// Owns a request chain independently of native decoder lifetime.
public final class OcpPlaybackFlow: @unchecked Sendable {
    public struct Attempt: Decodable, Sendable {
        public let sourceId: String?
        public let kind: String
    }
    public struct Snapshot: Decodable, Sendable {
        public let playbackRequestId: String?
        public let sourceId: String?
        public let active: Bool
        public let generation: UInt64
        public let failoverCount: Int
        public let attempts: [Attempt]
        public let pendingSourceId: String?
    }
    public struct Decision: Decodable, Sendable {
        public let action: String
        public let reason: String
        public let snapshot: Snapshot
    }
    public struct Classification: Decodable, Sendable {
        public let kind: String
        public let isRetryable: Bool
        public let allowsSourceFailover: Bool
    }
    public struct Capabilities: Decodable, Sendable {
        public let isRetryable: Bool
        public let allowsSourceFailover: Bool
        public let maximumSourceFailovers: Int
    }
    public struct ReportDecision: Decodable, Sendable {
        public let action: String
        public let ticks: UInt64
        public let reportedPause: Bool
        public let reachedEnd: Bool
        public init(action: String, ticks: UInt64, reportedPause: Bool, reachedEnd: Bool) {
            self.action = action
            self.ticks = ticks
            self.reportedPause = reportedPause
            self.reachedEnd = reachedEnd
        }
    }
    public func reportStep(state: String, positionSeconds: Double, durationSeconds: Double,
                           sourceOpenFailed: Bool, mode: String, ticks: UInt64,
                           reportedPause: Bool, everyTicks: Int) throws -> ReportDecision {
        try call("reportStep", ["snapshot": ["state": state, "positionSeconds": positionSeconds,
                                           "durationSeconds": durationSeconds, "sourceOpenFailed": sourceOpenFailed],
                                "mode": mode, "ticks": ticks, "reportedPause": reportedPause,
                                "everyTicks": everyTicks], as: ReportDecision.self)
    }
    public func foregroundAction(intentToResume: Bool, state: String?, hasSetupError: Bool) throws -> String {
        struct Result: Decodable { let action: String }
        let response = try client.call("playbackEvents.foreground", arguments: ["intentToResume": intentToResume, "state": state as Any, "hasSetupError": hasSetupError])
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.data.decode(Result.self).action
    }
    public func staleTailIO(message: String?, positionSeconds: Double, durationSeconds: Double) throws -> Bool {
        struct Result: Decodable { let matches: Bool }
        let response = try client.call("playbackEvents.staleTailIO", arguments: ["message": message as Any, "positionSeconds": positionSeconds, "durationSeconds": durationSeconds])
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.data.decode(Result.self).matches
    }
    private struct Adoption: Decodable { let accepted: Bool; let snapshot: Snapshot }
    public let client: OcpCoreClient
    public private(set) var snapshot: Snapshot

    public init?(client: OcpCoreClient? = nil, libraryPath: String? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do {
            self.client = try client ?? OcpCoreClient(libraryPath: libraryPath)
            let response = try self.client.call("playbackFlow.snapshot")
            guard response.ok else { return nil }
            snapshot = try response.data.decode(Snapshot.self)
        } catch { return nil }
    }
    public func begin(requestID: String, sourceID: String?, alternates: [[String: Any]]) throws {
        snapshot = try call("begin", ["playbackRequestId": requestID, "sourceId": sourceID as Any, "alternates": alternates], as: Snapshot.self)
    }
    public func invalidate() throws { snapshot = try call("invalidate", as: Snapshot.self) }
    public func failed(requestID: String, kind: String, hasItem: Bool) throws -> Decision {
        let decision = try call("failed", ["playbackRequestId": requestID, "kind": kind, "hasItem": hasItem], as: Decision.self)
        snapshot = decision.snapshot
        return decision
    }
    public func adopt(fromRequestID: String, generation: UInt64, requestID: String, sourceID: String) throws -> Bool {
        let adoption = try call("adopt", ["fromPlaybackRequestId": fromRequestID, "generation": generation, "playbackRequestId": requestID, "sourceId": sourceID], as: Adoption.self)
        snapshot = adoption.snapshot
        return adoption.accepted
    }
    public func classify(message: String) throws -> Classification { try call("classify", ["message": message], as: Classification.self) }
    public func capabilities(kind: String) throws -> Capabilities { try call("capabilities", ["kind": kind], as: Capabilities.self) }
    private func call<T: Decodable>(_ suffix: String, _ args: [String: Any] = [:], as type: T.Type) throws -> T {
        let response = try client.call("playbackFlow." + suffix, arguments: args)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.data.decode(type)
    }
}
