import Foundation
import OcPlayerCore

/// A continuation adapter; request bytes/tokens/errors remain with their effects.
final class RustMoviePilotFlow: Sendable {
    let core: OcpCoreClient
    init(_ core: OcpCoreClient) { self.core = core }
    struct Effect: Decodable {
        var kind: String
        var replay: Bool?
        var attempt, maxAttempts, baseSeconds: UInt64?
        var minimumSeconds, maximumSeconds: Double?
    }
    struct Step: Decodable {
        var token, sequence: UInt64
        var done: Bool
        var success: Bool?
        var effect: Effect?
    }
    func call<T: Decodable>(_ method: String, _ args: [String: Any], as: T.Type = T.self) throws -> T {
        let response = try core.call("moviepilotFlow." + method, arguments: args)
        if response.code == 1003 { throw CancellationError() }
        guard response.ok else { throw MoviePilotError.generic(response.message) }
        return try response.decodeData(T.self)
    }
    func resume(_ step: Step, revision: UInt64, outcome: String, tokenChanged: Bool? = nil) throws -> Step {
        var args: [String: Any] = ["token": step.token, "sequence": step.sequence,
            "revision": revision, "outcome": outcome]
        if let tokenChanged { args["tokenChanged"] = tokenChanged }
        return try call("resume", args)
    }
    func cancel(_ token: UInt64) {
        do {
            struct Cancelled: Decodable { var cancelled: Bool }
            let _: Cancelled = try call("cancel", ["token": token])
        } catch { preconditionFailure("MoviePilot flow retirement failed") }
    }
    var activeCount: UInt64 {
        do {
            struct Stats: Decodable { var active: UInt64 }
            return try call("stats", [:], as: Stats.self).active
        } catch { preconditionFailure("MoviePilot flow diagnostics failed") }
    }
}
