import Foundation
import OcPlayerCore

/// A typed adapter to retained Core account policy. No credentials cross this API.
final class RustBangumiAccount: Sendable {
    let core: OcpCoreClient
    init(_ core: OcpCoreClient) { self.core = core }
    func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as: T.Type = T.self) throws -> T {
        let response = try core.call("bangumiAccount." + method, arguments: args)
        guard response.ok else { throw BangumiError.request(response.message) }
        return try response.data.decode(T.self)
    }
    // Synchronous nonthrowing native APIs only send valid local commands. A
    // violated ABI contract cannot silently switch to another credential owner.
    func invariant<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as: T.Type = T.self) -> T {
        do { return try call(method, args, as: T.self) }
        catch { preconditionFailure("Bangumi account Core contract failed: \(method)") }
    }
    struct Snapshot: Decodable {
        var generation, exchangeGeneration, refreshGeneration, operationRevision: UInt64
        var refreshActive: Bool
    }
    struct Decision: Decodable { var accepted: Bool; var generation: UInt64 }
    struct Transition: Decodable {
        var accepted: Bool; var generation: UInt64
        var cancelRefresh, cancelRequests, invalidateSession: Bool?
    }
    struct Claim: Decodable {
        var id, generation: UInt64; var joined: Bool; var timeoutSeconds: UInt64
    }
    struct Access: Decodable { var action: String; var generation: UInt64 }
    var snapshot: Snapshot { invariant("snapshot") }
    func current(_ generation: UInt64) -> Bool { invariant("current", ["generation": generation]) }
}
