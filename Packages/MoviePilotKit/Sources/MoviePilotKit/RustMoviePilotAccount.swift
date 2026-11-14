import Foundation
import OcPlayerCore

/// Typed effects protocol for the retained account owner; no secrets cross it.
final class RustMoviePilotAccount: Sendable {
    let core: OcpCoreClient
    init(_ core: OcpCoreClient) { self.core = core }
    func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as: T.Type = T.self) throws -> T {
        let response = try core.call("moviepilotAccount." + method, arguments: args)
        guard response.ok else { throw MoviePilotError.generic(response.message) }
        return try response.decodeData(T.self)
    }
    func invariant<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as: T.Type = T.self) -> T {
        do { return try call(method, args, as: T.self) }
        catch { preconditionFailure("MoviePilot account Core contract failed: \(method)") }
    }
    struct Snapshot: Decodable {
        var generation, configurationRevision, refreshID: UInt64
        var exhaustedGeneration: UInt64?
        var loginActive, refreshActive: Bool
    }
    struct Transition: Decodable {
        var generation: UInt64
        var id: UInt64?
        var cancelRefresh, cancelRequests, clearSessions: Bool
    }
    struct Decision: Decodable {
        var accepted: Bool; var generation: UInt64
        var clearToken, notify: Bool?
    }
    struct Claim: Decodable {
        var action: String; var id, generation, timeoutSeconds: UInt64
        var clearToken, notify: Bool
    }
    var snapshot: Snapshot { invariant("snapshot") }
}
