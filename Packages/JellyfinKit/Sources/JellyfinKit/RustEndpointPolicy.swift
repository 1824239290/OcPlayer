import Foundation
import OcPlayerCore

/// Shared decision state; the host keeps probe tasks and change callbacks.
final class RustEndpointPolicy: @unchecked Sendable {
    struct Snapshot: Decodable {
        let currentURL: URL
        let pinned: Bool
        let candidateCount: Int
        let generation: UInt64
    }
    struct Plan: Decodable {
        let generation: UInt64
        let targets: [URL]
        let expectedServerID: String?
    }
    struct Applied: Decodable {
        let snapshot: Snapshot
        let changed: Bool
        let stale: Bool
        let latency: Double?
    }
    enum Decision: String, Decodable { case immediate, background, awaitResolution = "await_resolution" }
    private struct DecisionResult: Decodable { let decision: Decision }
    private struct Gate: Decodable { let allowed: Bool }
    private let client: OcpCoreClient

    init?(profile: ServerProfile, enabled: Bool? = nil, libraryPath: String? = nil) {
        guard enabled ?? (libraryPath != nil || OcpCoreFeature.isEnabled) else { return nil }
        do {
            client = try OcpCoreClient(libraryPath: libraryPath)
            let _: Snapshot = try call("initialize", ["config": Self.config(profile)])
        } catch { return nil }
    }

    static func config(_ profile: ServerProfile) -> [String: Any] {
        var config: [String: Any] = ["baseURL": profile.baseURL.absoluteString,
                                    "candidates": profile.allAddresses.map { $0.url.absoluteString }]
        if let pinned = profile.pinnedURL { config["pinnedURL"] = pinned.absoluteString }
        if let expected = profile.resolvedServerID { config["expectedServerID"] = expected }
        return config
    }

    private func call<T: Decodable>(_ suffix: String, _ arguments: [String: Any] = [:]) throws -> T {
        let response = try client.call("endpoint.\(suffix)", arguments: arguments)
        guard response.ok else { throw RustCoreMediaServerError(response: response) }
        return try response.data.decode(T.self)
    }

    private func safely<T>(_ operation: () throws -> T) -> T? {
        do { return try operation() }
        catch {
            NetworkLog.logger.warning("共享地址策略失败，保留当前地址：\(error)")
            return nil
        }
    }

    func current() -> Snapshot? { safely { try call("current") } }
    func decision(options: [String: Any]) -> Decision? {
        safely { let value: DecisionResult = try call("decision", ["options": options]); return value.decision }
    }
    func begin() -> Plan? { safely { try call("begin") } }
    func apply(results: [ServerProbeResult], generation: UInt64, options: [String: Any]) -> Applied? {
        safely {
            let values: [[String: Any]] = results.map { result in
                var value: [String: Any] = ["url": result.url.absoluteString, "latency": result.latency]
                if let serverID = result.serverID { value["serverID"] = serverID }
                return value
            }
            return try call("apply", ["results": values, "generation": generation, "options": options])
        }
    }
    func sync(profile: ServerProfile) -> Snapshot? { safely { try call("sync", ["config": Self.config(profile)]) } }
    func invalidate() -> Snapshot? { safely { try call("invalidate") } }
    func failureAllowed(failed: URL, options: [String: Any]) -> Bool {
        safely { let gate: Gate = try call("failureGate", ["failedURL": failed.absoluteString, "options": options]); return gate.allowed } ?? false
    }
}

/// One host client keeps the Rust probe executor and connection pool alive.
enum RustServerProbe {
    static let client = try? OcpCoreClient()
    private struct WireResult: Decodable {
        let url: URL
        let latency: Double
        let serverID: String?
        let serverName: String?
        let productName: String?
        let version: String?
        var result: ServerProbeResult {
            ServerProbeResult(url: url, latency: latency, serverID: serverID,
                              serverName: serverName, productName: productName, version: version)
        }
    }
    static func probe(client: OcpCoreClient, url: URL, timeout: Double, authorization: String?, expected: String?) async -> ServerProbeResult? {
        var arguments: [String: Any] = ["url": url.absoluteString, "timeout": timeout]
        if let authorization { arguments["authorizationHeader"] = authorization }
        if let expected { arguments["expectedServerID"] = expected }
        if let agent = ClientIdentity.customUserAgent { arguments["userAgent"] = agent }
        do {
            let payload = try JSONSerialization.data(withJSONObject: arguments)
            let response = try await client.callAsync("endpoint.probe", argumentsJSON: String(decoding: payload, as: UTF8.self))
            guard response.ok else { return nil }
            return try response.data.decode(WireResult?.self)?.result
        } catch { return nil }
    }
}
