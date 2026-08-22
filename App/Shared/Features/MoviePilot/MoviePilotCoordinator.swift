import Foundation
import MoviePilotKit
import Observation

/// MoviePilot 功能的 App 层协调器：登录态、当前用户、设置页交互。
///
/// 仿 `BangumiCoordinator` 模式——AppModel 持有它，视图通过它访问 MoviePilot
/// 能力。token 过期靠客户端 401 静默重登录兜底，只有重登也失败（密码改了）
/// 才通过通知把 UI 拉回未登录态。
@MainActor
@Observable
final class MoviePilotCoordinator {

    let store = MoviePilotStore()

    /// 凭证失效通知。转发 MoviePilotKit 的名字 + 载荷解码，根视图不必 import MoviePilotKit。
    static let authenticationRequiredNotification =
        MoviePilotAPIClient.authenticationRequiredNotification

    static func authenticationGeneration(from note: Notification) -> UInt64? {
        (note.object as? NSNumber)?.uint64Value
    }

    /// 当前用户（登录成功或恢复会话后有值）。
    var profile: MPUser?

    /// 最近一次登录失败的文案（设置页展示，成功后清空）。
    var authError: String?

    var isLoggingIn = false

    /// 本地有 token 即视为已登录；token 死了会被 401 → 静默重登 → 通知这条链纠正。
    var isAuthenticated: Bool { store.hasToken }

    var isConfigured: Bool { store.isConfigured }

    // MARK: - 登录 / 登出

    /// 设置页「保存并登录」：先落凭据（顺带作废旧 token），再登录取用户。
    /// 返回错误文案（nil = 成功）。
    @discardableResult
    func login(serverURLString: String, username: String, password: String) async -> String? {
        guard MoviePilotStore.normalizedURL(from: serverURLString) != nil else {
            authError = "服务器地址无效，应为 http(s)://域名或IP[:端口]"
            return authError
        }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            authError = "请填写用户名和密码"
            return authError
        }

        store.updateCredentials(
            serverURLString: serverURLString, username: username, password: password
        )
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            profile = try await MoviePilotAPIClient.shared.login()
            authError = nil
            return nil
        } catch {
            let message = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            MoviePilotNetworkLog.logger.error("MoviePilot 登录失败 error=\(error)")
            authError = message
            return message
        }
    }

    /// 收到 401 通知：清会话、拉回未登录态。挂在 `RootView`（与 Bangumi 同理，
    /// 401 可能来自任何页面的请求，那时设置页未必存在）。
    func handleAuthenticationRequired(generation: UInt64) async {
        _ = await MoviePilotAPIClient.shared.clearSession(ifCurrent: generation)
        profile = nil
        authError = MoviePilotError.requireLogin.userMessage
    }

    func signOut() async {
        _ = await MoviePilotAPIClient.shared.signOut()
        profile = nil
        authError = nil
    }

    // MARK: - 会话恢复

    /// 设置页出现时补一次用户信息：跨启动后 profile 是空的，token 还在的话
    /// 拉回来顺便验证 token 活着。失败不动登录态——真过期会走 401 通知那条路。
    func refreshProfileIfNeeded() {
        guard store.hasToken, profile == nil, !didRefreshProfile else { return }
        didRefreshProfile = true
        Task {
            do {
                profile = try await MoviePilotAPIClient.shared.currentUser()
            } catch {
                MoviePilotNetworkLog.logger.error("拉取 MoviePilot 用户信息失败 error=\(error)")
            }
        }
    }

    private var didRefreshProfile = false
}
