import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

public struct OcpCoreError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum OcpCoreFeature {
    public static let userDefaultsKey = "OCP_CORE_ENABLED"

    public static var isEnabled: Bool {
        if let value = ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] { return value == "1" }
        if let value = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool { return value }
        return Bundle.main.object(forInfoDictionaryKey: "OcpCoreEnabled") as? Bool ?? false
    }
    /// Foundation supplies built-in protocol classes even for a default session.
    /// Only caller-injected protocols indicate that URLSession must remain in use.
    public static func supportsNativeTransport(_ configuration: URLSessionConfiguration) -> Bool {
        let native = Set((URLSessionConfiguration.default.protocolClasses ?? []).map(ObjectIdentifier.init))
        return (configuration.protocolClasses ?? []).allSatisfy { native.contains(ObjectIdentifier($0)) }
    }

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

public extension JSONValue {
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(EncodableJSONValue(self))
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct EncodableJSONValue: Encodable {
    let value: JSONValue

    init(_ value: JSONValue) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .object(let value): try container.encode(value.mapValues(EncodableJSONValue.init))
        case .array(let value): try container.encode(value.map(EncodableJSONValue.init))
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private typealias OcpCore = OpaquePointer
private typealias CoreCreate = @convention(c) (UnsafePointer<CChar>?) -> OcpCore?
private typealias CoreDestroy = @convention(c) (OcpCore?) -> Void
private typealias AbiVersion = @convention(c) () -> UInt32
private typealias Call = @convention(c) (OcpCore?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias PollEvent = @convention(c) (OcpCore?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
private typealias Snapshot = @convention(c) (OcpCore?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
private typealias AttachSurface = @convention(c) (OcpCore?, UInt64, UInt32, UInt32, Double, UInt32) -> Void
private typealias ResizeSurface = @convention(c) (OcpCore?, UInt32, UInt32, Double) -> Void
private typealias DetachSurface = @convention(c) (OcpCore?) -> Void
private typealias RenderTick = @convention(c) (OcpCore?, Double) -> Void
private typealias StringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
private typealias LastErrorMessage = @convention(c) () -> UnsafeMutablePointer<CChar>?

private final class OcpNativeAPI: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    private let ownsHandle: Bool
    let create: CoreCreate
    let destroy: CoreDestroy
    let abiVersion: AbiVersion
    let call: Call
    let pollEvent: PollEvent
    let snapshot: Snapshot
    let attachSurface: AttachSurface
    let resizeSurface: ResizeSurface
    let detachSurface: DetachSurface
    let renderTick: RenderTick
    let stringFree: StringFree
    let lastErrorMessage: LastErrorMessage

    init(explicitPath: String? = nil) throws {
        let candidates = Self.libraryCandidates(explicitPath: explicitPath)
        var loaded: UnsafeMutableRawPointer?
        for candidate in candidates {
            loaded = candidate.withCString { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
            if loaded != nil { break }
        }
        var ownsHandle = loaded != nil
        if loaded == nil, explicitPath == nil {
            loaded = dlopen(nil, RTLD_NOW)
            ownsHandle = false
        }
        guard let handle = loaded else {
            throw OcpCoreError(message: "Rust Core library is unavailable; set OCP_CORE_LIBRARY_PATH or bundle libocp_ffi.dylib")
        }
        self.handle = handle
        self.ownsHandle = ownsHandle
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw OcpCoreError(message: "Rust Core library is missing symbol \(name)")
            }
            return unsafeBitCast(pointer, to: type)
        }
        create = try symbol("ocp_core_create", as: CoreCreate.self)
        destroy = try symbol("ocp_core_destroy", as: CoreDestroy.self)
        abiVersion = try symbol("ocp_core_abi_version", as: AbiVersion.self)
        call = try symbol("ocp_call", as: Call.self)
        pollEvent = try symbol("ocp_poll_event", as: PollEvent.self)
        snapshot = try symbol("ocp_snapshot", as: Snapshot.self)
        attachSurface = try symbol("ocp_attach_surface", as: AttachSurface.self)
        resizeSurface = try symbol("ocp_resize_surface", as: ResizeSurface.self)
        detachSurface = try symbol("ocp_detach_surface", as: DetachSurface.self)
        renderTick = try symbol("ocp_render_tick", as: RenderTick.self)
        stringFree = try symbol("ocp_string_free", as: StringFree.self)
        lastErrorMessage = try symbol("ocp_last_error_message", as: LastErrorMessage.self)
    }

    deinit {
        if ownsHandle { dlclose(handle) }
    }

    static func libraryCandidates(explicitPath: String? = nil) -> [String] {
        var values: [String] = []
        if let explicitPath { return [explicitPath] }
        if let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty { values.append(path) }
        if let path = Bundle.main.privateFrameworksPath { values.append((path as NSString).appendingPathComponent("libocp_ffi.dylib")) }
        if let path = Bundle.main.path(forResource: "libocp_ffi", ofType: "dylib") { values.append(path) }
        return values
    }
}

public final class OcpCoreClient: @unchecked Sendable {
    public static var abiVersion: UInt32 {
        (try? OcpNativeAPI().abiVersion()) ?? 0
    }
    private let lock = NSLock()
    private let api: OcpNativeAPI
    private let core: OcpCore?

    public init(config: [String: Any] = [:], libraryPath: String? = nil) throws {
        let native = try OcpNativeAPI(explicitPath: libraryPath)
        api = native
        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(decoding: data, as: UTF8.self)
        core = json.withCString { native.create($0) }
        guard core != nil else { throw NSError(domain: "OcPlayerCore", code: 1) }
    }

    deinit { synchronized { api.destroy(core) } }

    public func call(_ method: String, arguments: [String: Any] = [:]) throws -> OcpResponse {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try callJSON(method, json: String(decoding: data, as: UTF8.self))
    }

    /// Executes the blocking C ABI on a dispatch worker while the actor remains responsive.
    /// Capturing self retains both the core handle and the loaded library until completion.
    public func callAsync(_ method: String, argumentsJSON: String = "{}") async throws -> OcpResponse {
        try Task.checkCancellation()
        guard var arguments = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            throw OcpCoreError(message: "command arguments must be an object")
        }
        let requestID = arguments["requestId"] as? String ?? UUID().uuidString
        arguments["requestId"] = requestID
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let controlJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["requestId": requestID]), as: UTF8.self)
        let prepared = try callJSON("request.prepare", json: controlJSON)
        guard prepared.ok else { throw OcpCoreError(message: prepared.message) }
        let response: OcpResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try callJSON(method, json: json)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            _ = try? self.callJSON("request.cancel", json: controlJSON)
        }
        try Task.checkCancellation()
        return response
    }

    private func callJSON(_ method: String, json: String) throws -> OcpResponse {
        // Rust serializes shared state internally. Polling must stay available during network calls.
        let pointer = method.withCString { methodPointer in
            json.withCString { api.call(core, methodPointer, $0) }
        }
        guard let pointer else { throw OcpCoreError(message: lastError(fallback: "ocp_call failed")) }
        defer { api.stringFree(pointer) }
        return try JSONDecoder().decode(OcpResponse.self, from: Data(String(cString: pointer).utf8))
    }

    public func pollEvent() throws -> OcpEvent? {
        var pointer: UnsafeMutablePointer<CChar>?
        let result = synchronized { api.pollEvent(core, &pointer) }
        guard result >= 0 else { throw synchronized { OcpCoreError(message: lastError(fallback: "ocp_poll_event failed")) } }
        guard result == 1, let pointer else { return nil }
        defer { api.stringFree(pointer) }
        return try JSONDecoder().decode(OcpEvent.self, from: Data(String(cString: pointer).utf8))
    }

    public func snapshot(kind: String = "core") throws -> JSONValue {
        let pointer = synchronized { kind.withCString { api.snapshot(core, $0) } }
        guard let pointer else { throw synchronized { OcpCoreError(message: lastError(fallback: "ocp_snapshot failed")) } }
        defer { api.stringFree(pointer) }
        return try JSONDecoder().decode(JSONValue.self, from: Data(String(cString: pointer).utf8))
    }

    /// Versioned configuration backup payload. Secrets are kept out of this
    /// convenience API; platform credential stores remain the source of truth.
    public func exportConfiguration() throws -> JSONValue {
        try call("config.export").data
    }

    public func validateConfiguration(_ config: [String: Any]) throws -> OcpResponse {
        try call("config.validate", arguments: ["config": config])
    }

    public func importConfiguration(_ config: [String: Any]) throws -> OcpResponse {
        try call("config.import", arguments: ["config": config])
    }

    public func diagnosticsSnapshot(includeConfig: Bool = true, redact: Bool = true) throws -> JSONValue {
        try call("diag.snapshot", arguments: ["includeConfig": includeConfig, "redact": redact]).data
    }

    public func attachSurface(nativeHandle: UInt64, width: UInt32, height: UInt32, scale: Double, kind: UInt32) {
        synchronized { api.attachSurface(core, nativeHandle, width, height, scale, kind) }
    }

    public func resizeSurface(width: UInt32, height: UInt32, scale: Double) {
        synchronized { api.resizeSurface(core, width, height, scale) }
    }

    public func detachSurface() {
        synchronized { api.detachSurface(core) }
    }

    public func renderTick(timeSeconds: Double) {
        synchronized { api.renderTick(core, timeSeconds) }
    }

    private func lastError(fallback: String) -> String {
        guard let pointer = api.lastErrorMessage() else { return fallback }
        defer { api.stringFree(pointer) }
        return String(cString: pointer)
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
