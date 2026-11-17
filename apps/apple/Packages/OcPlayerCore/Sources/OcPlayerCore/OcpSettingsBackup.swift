import Foundation

/// Host preference getter facts feed Core's portable backup and restore policy.
public final class OcpSettingsBackup: @unchecked Sendable {
    public struct Preference: @unchecked Sendable {
        public let present: Bool
        public let value: Any?
        public init(present: Bool, value: Any?) { self.present = present; self.value = value }
    }
    public struct Summary: Decodable, Sendable {
        public let hasTMDb: Bool
        public let tmdbKeyTail: String?
        public let tmdbLanguage: String?
        public let hasPlayback: Bool
        public let hasDanmaku: Bool
        public let hasGeneral: Bool
        public let hasMirror: Bool
        public let deviceName: String?
    }
    public struct Effect: Decodable, Sendable {
        public let target: String
        public let field: String
        public let operation: String
        public let valueJSON: String
        public func value() throws -> Any {
            try JSONSerialization.jsonObject(with: Data(valueJSON.utf8), options: [.fragmentsAllowed])
        }
    }
    public struct Projection: Decodable, Sendable {
        public let backupJSON: String
        public let summary: Summary
        public let effects: [Effect]
        public var backupData: Data { Data(backupJSON.utf8) }
    }
    public struct Failure: Error, LocalizedError, Sendable {
        public let kind: String
        public let version: Int?
        public let message: String
        public var errorDescription: String? { message }
    }
    private struct ErrorPayload: Decodable { let kind: String; let version: Int? }
    private let client: OcpCoreClient
    public init?(client: OcpCoreClient? = nil, libraryPath: String? = nil) {
        guard OcpCoreFeature.isEnabled else { return nil }
        do {
            self.client = try client ?? OcpCoreClient(libraryPath: libraryPath)
            guard try self.client.call("settings.backup.capabilities").ok else { return nil }
        } catch { return nil }
    }
    private func result(_ method: String, _ arguments: [String: Any]) throws -> Projection {
        let reply = try client.call(method, arguments: arguments)
        guard reply.ok else {
            let error = try reply.decodeData(ErrorPayload.self)
            throw Failure(kind: error.kind, version: error.version, message: reply.message)
        }
        return try reply.decodeData(Projection.self)
    }
    public func decode(_ data: Data) throws -> Projection {
        try result("settings.backup.decode", ["inputBase64": data.base64EncodedString()])
    }
    /// Preparing an in-memory value preserves the native encoder's ability to
    /// generate newer-version fixtures; file import performs the version gate.
    public func prepare(_ data: Data) throws -> Projection {
        try result("settings.backup.prepare", ["inputBase64": data.base64EncodedString()])
    }
    public func snapshot(preferences: [String: Preference], tmdb: [String: Any],
                         exportedAt: String, appVersion: String, deviceName: String?,
                         dandanplayGatewayURL: String?) throws -> Projection {
        try result("settings.backup.snapshot", [
            "preferences": preferences.mapValues { ["present": $0.present, "value": $0.value ?? NSNull()] as [String: Any] },
            "tmdb": tmdb, "exportedAt": exportedAt, "appVersion": appVersion,
            "deviceName": deviceName as Any, "dandanplayGatewayURL": dandanplayGatewayURL as Any,
        ])
    }
}
