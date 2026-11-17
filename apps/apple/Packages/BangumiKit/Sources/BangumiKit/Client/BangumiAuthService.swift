import Foundation

/// Account/profile orchestration delegates to the selected account Core.
@MainActor
public enum BangumiAuthService {
    private static let lifecycle = BangumiAuthLifecycle(client: .shared, effects: .init(
        retireWork: { BangumiContext.shared.database?.invalidateWork() },
        fetchProfile: { try await fetchProfile() },
        commitProfile: { BangumiContext.shared.setAuthenticated($0) },
        clearProfile: { BangumiContext.shared.clearAuthState() },
        clearDatabase: { revision in
            guard revision == syncOperationRevision else { throw BangumiError(ignore: "Retired account database clear") }
            guard let db = BangumiContext.shared.database else { return }
            let workRevision = db.captureWorkRevision()
            try await db.clearAccountLocalState(ifCurrentWorkRevision: workRevision)
        },
        authenticated: { BangumiContext.shared.isAuthenticated }))

    static var syncOperationRevision: UInt64 { lifecycle.operationRevision }

    /// OAuth and refresh use the configured gateway; secrets remain there.
    public static func configureGateway(_ configuration: BangumiGatewayConfiguration?) async {
        await BangumiAPIClient.shared.configureGateway(configuration)
    }
    public static func buildOAuthURL() async throws -> URL {
        try await BangumiAPIClient.shared.buildOAuthURL()
    }
    public static func exchangeForAccessToken(code: String, state: String) async throws {
        try await lifecycle.exchange(code: code, state: state)
    }
    public static func refreshProfile() async throws -> BangumiProfile {
        try await lifecycle.refreshProfile()
    }
    public static func logout() async { await lifecycle.logout() }
    public static func invalidateSession(expectedCredentialGeneration: UInt64) async {
        await lifecycle.invalidateSession(expectedGeneration: expectedCredentialGeneration)
    }
    private static func fetchProfile() async throws -> BangumiProfile {
        let data = try await BangumiAPIClient.shared.request(
            url: BangumiURL.next(path: "p1/me"), method: "GET", auth: .required)
        guard let rawValue = String(data: data, encoding: .utf8) else {
            throw BangumiError(request: "profile data error")
        }
        // Preserve the existing original-byte Codable/default profile behavior.
        return BangumiProfile(from: rawValue)
    }
}
