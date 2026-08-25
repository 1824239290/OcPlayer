import Foundation

/// 登录/登出编排（与 Bangumi-iOS 的 AuthService 同构）。
///
/// 用 operationRevision 做乐观锁：登录/登出是异步操作，过期结果一律作废，
/// 避免「登出后旧登录响应把状态写回去」这类竞态。
@MainActor
public enum BangumiAuthService {
    private static var operationRevision: UInt64 = 0

    public static func buildOAuthURL() async -> URL {
        await BangumiAPIClient.shared.buildOAuthURL()
    }

    /// 换 code 拿 token 并拉取 profile，成功后置为已登录。
    public static func exchangeForAccessToken(code: String) async throws {
        let revision = beginOperation()
        let credentialGeneration = try await BangumiAPIClient.shared.exchangeForAccessToken(code: code)
        try ensureCurrentOperation(revision)
        do {
            _ = try await refreshProfile(revision: revision)
        } catch {
            if (try? ensureCurrentOperation(revision)) != nil {
                _ = await BangumiAPIClient.shared.clearCredentials(ifCurrent: credentialGeneration)
            }
            throw error
        }
    }

    /// 已登录状态下主动刷新 profile（启动恢复时用）。
    public static func refreshProfile() async throws -> BangumiProfile {
        let revision = beginOperation()
        return try await refreshProfile(revision: revision)
    }

    public static func logout() async {
        let revision = beginOperation()
        BangumiContext.shared.clearAuthState()
        _ = await BangumiAPIClient.shared.clearCredentials()
        guard revision == operationRevision else { return }
        let db = BangumiContext.shared.database
        try? await db?.clearAccountLocalState()
    }

    /// 401 时被动失效会话（只清当前代次的凭证）。
    public static func invalidateSession(expectedCredentialGeneration: UInt64) async {
        guard BangumiContext.shared.isAuthenticated else { return }
        let observedRevision = operationRevision
        guard
            let clearedGeneration = await BangumiAPIClient.shared.clearCredentials(
                ifCurrent: expectedCredentialGeneration)
        else { return }
        guard observedRevision == operationRevision else { return }
        guard await BangumiAPIClient.shared.isCurrentCredentialGeneration(clearedGeneration) else {
            return
        }
        guard observedRevision == operationRevision else { return }
        _ = beginOperation()
        BangumiContext.shared.clearAuthState()
    }

    private static func refreshProfile(revision: UInt64) async throws -> BangumiProfile {
        let profile = try await fetchProfile()
        try ensureCurrentOperation(revision)
        // 通过 context 写入：store 持久化 + 内存存储属性同步（触发 UI 刷新）。
        BangumiContext.shared.setAuthenticated(profile)
        return profile
    }

    private static func fetchProfile() async throws -> BangumiProfile {
        let url = BangumiURL.next(path: "p1/me")
        let data = try await BangumiAPIClient.shared.request(
            url: url, method: "GET", auth: .required)
        guard let rawValue = String(data: data, encoding: .utf8) else {
            throw BangumiError(request: "profile data error")
        }
        return BangumiProfile(from: rawValue)
    }

    private static func ensureCurrentOperation(_ revision: UInt64) throws {
        guard revision == operationRevision else {
            throw BangumiError(ignore: "Discarded stale authentication operation")
        }
    }

    private static func beginOperation() -> UInt64 {
        operationRevision &+= 1
        return operationRevision
    }
}
