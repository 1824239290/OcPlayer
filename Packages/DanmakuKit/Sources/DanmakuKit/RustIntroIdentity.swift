import Foundation
import OcPlayerCore

private struct IdentityPayload: Decodable { let payloadJSON: String }
struct IntroIdentityPlan: Decodable {
    let cacheKey: String?
    let ready: AniSkipResolvedIDs?
    let anilistID: Int?
    let searchTitles: [String]
}
struct IntroIdentityMatch: Decodable { let index: Int; let rule: AniListClient.MatchRule }
struct IntroIDResolution: Decodable {
    let ids: AniSkipResolvedIDs
    let title: String?
    let rule: AniListClient.MatchRule?
    let attempts: [Attempt]
    struct Attempt: Decodable { let title: String?; let status: Int?; let error: String? }
}
struct IntroIDStoredResolution: Decodable {
    let ids: AniSkipResolvedIDs
    let cacheKey: String?
    let needsCommit: Bool
    let resolution: IntroIDResolution?
}

extension RustDanmakuPolicy {
    func identity<V: Encodable, T: Decodable>(_ method: String, value: V,
        arguments: [String: Any] = [:], as: T.Type = T.self) -> T {
        do {
            var arguments = arguments
            arguments["payloadJSON"] = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            let response = try core.call("introIdentity." + method, arguments: arguments)
            guard response.ok else { preconditionFailure("Core intro identity: \(response.message)") }
            let payload = try response.data.decode(IdentityPayload.self)
            return try JSONDecoder().decode(T.self, from: Data(payload.payloadJSON.utf8))
        } catch { preconditionFailure("Core intro identity: \(error)") }
    }
    func identityPlan(_ identity: AniSkipAnimeIdentity, record: AniSkipIDRecord?, force: Bool, now: Date) -> IntroIdentityPlan {
        var arguments: [String: Any] = ["forceRefresh": force, "now": now.timeIntervalSinceReferenceDate]
        if let record, let encoded = try? JSONEncoder().encode(record) {
            arguments["recordJSON"] = String(decoding: encoded, as: UTF8.self)
        }
        return self.identity("plan", value: identity, arguments: arguments)
    }
}

/// The resolver and store share this exact Core handle and its cached map.
struct RustIntroIDStore: Sendable {
    let core: OcpCoreClient
    init(directory: URL) throws {
        core = try OcpCoreClient()
        let response = try core.call("introIDs.open", arguments: ["directory": directory.path])
        guard response.ok else { throw OcpCoreError(message: response.message) }
    }
    private func call<T: Decodable>(_ method: String, arguments: [String: Any]) -> T {
        do {
            let response = try core.call("introIDs." + method, arguments: arguments)
            guard response.ok else { preconditionFailure("Core intro IDs: \(response.message)") }
            let payload = try response.data.decode(IdentityPayload.self)
            return try JSONDecoder().decode(T.self, from: Data(payload.payloadJSON.utf8))
        } catch { preconditionFailure("Core intro IDs: \(error)") }
    }
    func record(_ key: String) -> AniSkipIDRecord? { call("record", arguments: ["key": key]) }
    func write(_ record: AniSkipIDRecord, key: String) {
        guard let encoded = try? JSONEncoder().encode(record) else { return }
        let _: Bool = call("write", arguments: ["key": key, "payloadJSON": String(decoding: encoded, as: UTF8.self)])
    }
}

extension RustIntroProvider {
    func resolveIDs(anilistID: Int?, titles: [String]) async throws -> IntroIDResolution {
        var arguments: [String: Any] = ["baseURL": baseURL.absoluteString, "timeoutSeconds": timeout, "searchTitles": titles]
        if let anilistID { arguments["anilistID"] = anilistID }
        let response = try await core.callAsync("introProvider.resolveIDs", argumentsJSON:
            String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        guard response.ok else {
            if response.code == 1003 { throw CancellationError() }
            throw OcpCoreError(message: response.message)
        }
        let payload = try response.data.decode(IdentityPayload.self)
        return try JSONDecoder().decode(IntroIDResolution.self, from: Data(payload.payloadJSON.utf8))
    }
    func resolveStored(_ identity: AniSkipAnimeIdentity, force: Bool, now: Date) async throws -> IntroIDStoredResolution {
        let encoded = try JSONEncoder().encode(identity)
        let arguments: [String: Any] = ["baseURL": baseURL.absoluteString, "timeoutSeconds": timeout,
            "payloadJSON": String(decoding: encoded, as: UTF8.self), "forceRefresh": force,
            "now": now.timeIntervalSinceReferenceDate, "commit": false]
        let response = try await core.callAsync("introIDs.resolve", argumentsJSON:
            String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        guard response.ok else {
            if response.code == 1003 { throw CancellationError() }
            throw OcpCoreError(message: response.message)
        }
        let payload = try response.data.decode(IdentityPayload.self)
        return try JSONDecoder().decode(IntroIDStoredResolution.self, from: Data(payload.payloadJSON.utf8))
    }
}
