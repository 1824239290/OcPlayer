import Foundation

public struct OcpResponse: Decodable, Sendable {
    public let ok: Bool
    public let code: Int32
    public let retryable: Bool
    public let message: String
    public let data: JSONValue
}

public struct OcpEvent: Decodable, Sendable {
    public let sequence: UInt64
    public let kind: String
    public let data: JSONValue
}

public enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
}

private typealias OcpCore = OpaquePointer

@_silgen_name("ocp_core_create") private func ocp_core_create(_ config: UnsafePointer<CChar>?) -> OcpCore?
@_silgen_name("ocp_core_destroy") private func ocp_core_destroy(_ core: OcpCore?)
@_silgen_name("ocp_core_abi_version") private func ocp_core_abi_version() -> UInt32
@_silgen_name("ocp_call") private func ocp_call(_ core: OcpCore?, _ method: UnsafePointer<CChar>?, _ arguments: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("ocp_poll_event") private func ocp_poll_event(_ core: OcpCore?, _ output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
@_silgen_name("ocp_string_free") private func ocp_string_free(_ value: UnsafeMutablePointer<CChar>?)

public final class OcpCoreClient: @unchecked Sendable {
    public static var abiVersion: UInt32 { ocp_core_abi_version() }
    private var core: OcpCore?

    public init(config: [String: Any] = [:]) throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(decoding: data, as: UTF8.self)
        core = json.withCString { ocp_core_create($0) }
        guard core != nil else { throw NSError(domain: "OcPlayerCore", code: 1) }
    }

    deinit { ocp_core_destroy(core) }

    public func call(_ method: String, arguments: [String: Any] = [:]) throws -> OcpResponse {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let json = String(decoding: data, as: UTF8.self)
        let pointer = method.withCString { methodPointer in
            json.withCString { ocp_call(core, methodPointer, $0) }
        }
        guard let pointer else { throw NSError(domain: "OcPlayerCore", code: 2) }
        defer { ocp_string_free(pointer) }
        return try JSONDecoder().decode(OcpResponse.self, from: Data(String(cString: pointer).utf8))
    }

    public func pollEvent() throws -> OcpEvent? {
        var pointer: UnsafeMutablePointer<CChar>?
        let result = ocp_poll_event(core, &pointer)
        guard result >= 0 else { throw NSError(domain: "OcPlayerCore", code: 3) }
        guard result == 1, let pointer else { return nil }
        defer { ocp_string_free(pointer) }
        return try JSONDecoder().decode(OcpEvent.self, from: Data(String(cString: pointer).utf8))
    }
}
