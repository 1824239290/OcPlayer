import Foundation

/// Retained preparation effects. Original wire decoding preserves receipt IDs.
public final class OcpPlaybackPreparation: @unchecked Sendable {
    public struct Payload: Decodable, Sendable {
        public struct Alternate: Decodable, Sendable { public let key: String; public let id: String; public let uri: String }
        public let itemId: String?
        public let itemKey: String?
        public let seriesId: String?
        public let recursive: Bool?
        public let role: String?
        public let sourceKey: String?
        public let mediaSourceId: String?
        public let playSessionId: String?
        public let title: String?
        public let resumeSeconds: Double?
        public let uri: String?
        public let fallback: Bool?
        public let alternates: [Alternate]?
        public let status: String?
        public let phase: String?
        public let error: String?
    }
    public struct Step: Decodable, Sendable {
        public let token: UInt64
        public let sequence: UInt64
        public let effect: String?
        public let arguments: Payload?
        public let done: Bool
        public let result: Payload?
    }
    public let client: OcpCoreClient
    public init?(client: OcpCoreClient? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do { self.client = try client ?? OcpCoreClient() }
        catch { return nil }
    }
    public func start(item: [String: Any], mode: String, resumeSeconds: Double? = nil) throws -> Step {
        try call("start", ["item": item, "mode": mode, "resumeSeconds": resumeSeconds as Any])
    }
    public func resume(_ step: Step, response: Any) throws -> Step {
        try call("resume", ["token": step.token, "sequence": step.sequence, "response": response])
    }
    public func fail(_ step: Step, message: String, cancelled: Bool) throws -> Step {
        try call("fail", ["token": step.token, "sequence": step.sequence, "message": message, "cancelled": cancelled])
    }
    public func validate(_ step: Step) throws {
        struct Valid: Decodable { let valid: Bool }
        let _: Valid = try call("validate", ["token": step.token, "sequence": step.sequence])
    }
    public func cancel(token: UInt64) throws {
        struct Result: Decodable { let cancelled: Bool }
        let _: Result = try call("cancel", ["token": token])
    }
    public func invalidate() throws {
        struct Result: Decodable { let active: Int }
        let _: Result = try call("invalidate")
    }
    public func preferredSource(_ sources: [[String: Any]]) throws -> Int? {
        struct Result: Decodable { let index: Int? }
        let result: Result = try call("preferredSource", ["sources": sources]); return result.index
    }
    private func call<T: Decodable>(_ method: String, _ arguments: [String: Any] = [:]) throws -> T {
        let response = try client.call("playbackPreparation.\(method)", arguments: arguments)
        if response.code == 1003 { throw CancellationError() }
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return try response.decodeData(T.self)
    }
}
