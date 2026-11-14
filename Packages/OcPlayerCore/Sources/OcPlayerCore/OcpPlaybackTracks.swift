import Foundation

/// Decoder effects and receipts for one retained track workflow per Core handle.
public final class OcpPlaybackTracks: @unchecked Sendable {
    public struct Snapshot: Decodable, Sendable {
        public let manualChoice: Bool
        public let batchId: String?
        public let externalNames: [String: String]
        public let pendingOperationId: UInt64?
    }
    public struct Effect: Decodable, Sendable {
        public let action: String
        public let id: Int64?
        public let path: String?
    }
    public struct Step: Decodable, Sendable {
        public let operationId: UInt64?
        public let effect: Effect?
        public let snapshot: Snapshot
    }
    public struct Selection: Decodable, Sendable {
        public let action: String
        public let id: Int64?
    }
    public let client: OcpCoreClient
    public private(set) var snapshot: Snapshot
    public init?(client: OcpCoreClient? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do {
            self.client = try client ?? OcpCoreClient()
            let response = try self.client.call("playbackTracks.snapshot")
            guard response.ok else { return nil }
            snapshot = try response.decodeData(Snapshot.self)
        } catch { return nil }
    }
    public func selection(tracks: [[String: Any]], preference: String, current: Int64?) throws -> Selection {
        try call("selection", ["tracks": tracks, "preference": preference, "current": current as Any])
    }
    public func begin(_ request: [String: Any]) throws -> Step {
        let step: Step = try call("begin", ["request": request]); snapshot = step.snapshot; return step
    }
    public func complete(operationID: UInt64, success: Bool, trackID: Int64? = nil) throws -> Step {
        let step: Step = try call("complete", ["operationId": operationID, "success": success, "trackId": trackID as Any])
        snapshot = step.snapshot; return step
    }
    public func reset() throws { snapshot = try call("reset") }
    public func beginBatch(id: String) throws { snapshot = try call("beginBatch", ["batchId": id]) }
    public func endBatch(id: String) throws { snapshot = try call("endBatch", ["batchId": id]) }
    public func registerName(id: Int64, name: String) throws { snapshot = try call("registerName", ["id": id, "name": name]) }
    private func call<T: Decodable>(_ method: String, _ arguments: [String: Any] = [:]) throws -> T {
        let response = try client.call("playbackTracks.\(method)", arguments: arguments)
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.decodeData(T.self)
    }
}
