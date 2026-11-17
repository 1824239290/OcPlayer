import Foundation

/// JSON bridge for Bangumi commands. Domain packages can decode the returned
/// payload into their existing models while authentication tokens stay in the
/// platform credential store.
public final class OcpBangumiClient: @unchecked Sendable {
    private let core: OcpCoreClient
    private let baseURL: String
    private let accessToken: String?

    public init(core: OcpCoreClient, baseURL: String = "https://api.bgm.tv/", accessToken: String? = nil) {
        self.core = core
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    public func call(_ method: String, arguments: [String: Any] = [:]) async throws -> JSONValue {
        var merged = arguments
        merged["baseURL"] = baseURL
        if let accessToken { merged["accessToken"] = accessToken }
        let response = try await core.callAsync(
            method,
            argumentsJSON: String(
                decoding: JSONSerialization.data(withJSONObject: merged),
                as: UTF8.self))
        guard response.ok else { throw OcpCoreError(message: response.message) }
        return response.data
    }
}
