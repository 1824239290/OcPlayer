import Foundation
import DiagnosticsKit
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

    /// 与 `MoviePilotAPIClient.shared` 共用同一份 store（原来两边各持一个实例，
    /// 只靠同一份 UserDefaults 碰巧同步）。
    let store = MoviePilotStore.shared

    /// 凭证失效通知。转发 MoviePilotKit 的名字，根视图不必 import MoviePilotKit。
    /// 载荷解码（NSNumber 代次）走共享的 `AuthNotification.credentialGeneration(from:)`。
    static let authenticationRequiredNotification =
        MoviePilotAPIClient.authenticationRequiredNotification

    /// 当前用户（登录成功或恢复会话后有值）。
    var profile: MPUser?

    /// 最近一次成功登录绑定的服务器标识（原始地址串），nil = 从未登录。
    /// @Observable 供分区首页感知换服，作废旧服务器的订阅/搜索等本地 @State 缓存。
    private(set) var boundServerID: String?

    /// 最近一次登录失败的文案（设置页展示，成功后清空）。
    var authError: String?

    var isLoggingIn = false

    /// 本地有 token 即视为已登录；token 死了会被 401 → 静默重登 → 通知这条链纠正。
    var isAuthenticated: Bool { store.hasToken }

    /// 分区首页与设置页共用的集成状态判据（未配置 / 未登录 / 可用）。
    /// 别在视图里自己拼 `isConfigured` + `isAuthenticated`——两处拼法一旦不一致，
    /// 就会出现「登出后显示未配置」这类自相矛盾的态。
    var integrationState: MoviePilotStore.IntegrationState { store.integrationState }

    /// 「记住密码」开关（默认关）。设置页直接绑定。
    ///
    /// 关掉时 `MoviePilotStore` 会立即删掉已落盘的密码——默认不保存密码是本项目的
    /// 明确取舍：MoviePilot 的 JWT 有效期 8 天且没有刷新端点，「保存密码」换来的
    /// 只是到期后的静默重登，而密码是这堆凭据里唯一不可更换的一个。
    var rememberPassword: Bool {
        get { store.rememberPassword }
        set { store.rememberPassword = newValue }
    }

    // MARK: - 登录 / 登出

    /// 验证新凭据后提交；失败保留原会话，迟到尝试不更新 UI。
    @discardableResult
    func login(serverURLString: String, username: String, password: String) async -> String? {
        guard MoviePilotStore.normalizedURL(from: serverURLString) != nil else {
            authError = "服务器地址无效，应为 http(s)://域名或IP[:端口]"
            return authError
        }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // 密码只 trim 来判空，落盘与发送都用原值（含空格的密码不能被改写）。
        guard !username.isEmpty, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            authError = "请填写用户名和密码"
            return authError
        }

        attemptGeneration &+= 1
        let attempt = attemptGeneration
        didRefreshProfile = false
        isLoggingIn = true
        authError = nil
        defer { if attempt == attemptGeneration { isLoggingIn = false } }
        do {
            let user = try await MoviePilotAPIClient.shared.login(
                serverURLString: serverURLString, username: username, password: password)
            guard attempt == attemptGeneration else { return nil }
            profile = user
            authError = nil
            boundServerID = store.serverURLString
            return nil
        } catch {
            guard attempt == attemptGeneration, !CancellationClassifier.isCancellation(error) else { return nil }
            let message = MoviePilotError.userMessage(of: error)
            authError = message
            return message
        }
    }

    /// 收到 401 通知：清会话、拉回未登录态。挂在 `RootView`（与 Bangumi 同理，
    /// 401 可能来自任何页面的请求，那时设置页未必存在）。
    func handleAuthenticationRequired(generation: UInt64) async {
        let attempt = attemptGeneration
        guard await MoviePilotAPIClient.shared.clearSession(ifCurrent: generation) != nil,
              attempt == attemptGeneration else { return }
        attemptGeneration &+= 1
        isLoggingIn = false
        didRefreshProfile = false
        profile = nil
        authError = MoviePilotError.requireLogin.userMessage
    }

    func signOut() async {
        attemptGeneration &+= 1
        let attempt = attemptGeneration
        isLoggingIn = false
        didRefreshProfile = false
        profile = nil
        authError = nil
        _ = await MoviePilotAPIClient.shared.signOut()
        guard attempt == attemptGeneration else { return }
    }

    // MARK: - 会话恢复

    /// 设置页出现时补一次用户信息：跨启动后 profile 是空的，token 还在的话
    /// 拉回来顺便验证 token 活着。失败不动登录态——真过期会走 401 通知那条路。
    func refreshProfileIfNeeded() {
        guard !isLoggingIn, store.hasToken, profile == nil, !didRefreshProfile else { return }
        didRefreshProfile = true
        let attempt = attemptGeneration
        let revision = store.configurationRevision
        Task {
            do {
                let user = try await MoviePilotAPIClient.shared.currentUser()
                guard attempt == attemptGeneration, revision == store.configurationRevision else { return }
                profile = user
            } catch {
                MoviePilotNetworkLog.logger.error("拉取 MoviePilot 用户信息失败 error=\(error)")
            }
        }
    }

    private var didRefreshProfile = false
    @ObservationIgnored private var attemptGeneration: UInt64 = 0
}
