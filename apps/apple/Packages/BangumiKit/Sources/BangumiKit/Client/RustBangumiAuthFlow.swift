import Foundation
import OcPlayerCore

/// Account/profile effects use the HTTP client's retained account Core.
final class RustBangumiAuthFlow: Sendable {
    let core: OcpCoreClient
    init(_ core: OcpCoreClient) { self.core = core }
    struct Start: Encodable { var operation: String; var authenticated = false; var expectedGeneration: UInt64? }
    struct Step: Decodable {
        var token, sequence, operationRevision: UInt64
        var done: Bool
        var success, result, cleanup: Bool?
        var effect: String?
        var arguments: Arguments?
    }
    struct Arguments: Decodable { var operationRevision: UInt64; var expectedGeneration: UInt64? }
    struct Receipt: Encodable { var token, sequence: UInt64 }
    struct Cleared: Encodable { var generation: UInt64? }
    private struct Resume<T: Encodable>: Encodable { var token, sequence: UInt64; var response: T }
    func call<Input: Encodable, Output: Decodable>(_ method: String, _ input: Input, as: Output.Type = Output.self) throws -> Output {
        let reply = try core.call("bangumiAuthFlow." + method,
            argumentsJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self))
        guard reply.ok else {
            if reply.code == 1003 { throw BangumiError(ignore: "Authentication work was retired") }
            if reply.code == 1002, reply.message == "too many authentication flows" {
                throw BangumiError(ignore: "Credential invalidation is already pending")
            }
            throw BangumiError.request(reply.message)
        }
        return try reply.decodeData(Output.self)
    }
    func resume<T: Encodable>(_ step: Step, _ response: T) throws -> Step {
        try call("resume", Resume(token: step.token, sequence: step.sequence, response: response))
    }
    func validate(_ step: Step) throws {
        let accepted: Bool = try call("validate", Receipt(token: step.token, sequence: step.sequence))
        guard accepted else { throw BangumiError.request("Invalid authentication effect receipt") }
    }
    func cancel(_ token: UInt64) {
        do { let _: Bool = try call("cancel", ["token":token]) }
        catch { preconditionFailure("Cannot retire Bangumi authentication work") }
    }
}
