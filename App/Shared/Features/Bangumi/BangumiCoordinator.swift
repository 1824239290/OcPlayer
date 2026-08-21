import BangumiKit
import Foundation
import Observation

/// Bangumi 功能的 App 层协调器：登录态、数据库就绪、收藏/章节操作。
///
/// 仿 `DanmakuCoordinator` 模式——AppModel 持有它，视图通过它访问 Bangumi 能力，
/// BangumiKit 的类型不漏到 App 层之外。
@MainActor
@Observable
final class BangumiCoordinator {

    let context = BangumiContext.shared

    /// 凭证失效通知。转发 BangumiKit 的名字 + 载荷解码，这样根视图不必 import BangumiKit。
    static let authenticationRequiredNotification =
        BangumiAPIClient.authenticationRequiredNotification

    static func authenticationGeneration(from note: Notification) -> UInt64? {
        (note.object as? NSNumber)?.uint64Value
    }

    var isAuthenticated: Bool { context.isAuthenticated }
    var profile: BangumiProfile? { context.profile }
    var isDatabaseReady: Bool { context.isDatabaseReady }

    /// 最近一次登录/授权失败的文案（登录页展示，成功或重试时清空）。
    /// macOS 的 OAuth 回调走系统浏览器 → `onOpenURL`，没有这个字段的话失败就是彻底静默。
    var authError: String?

    /// 是否配置了 OAuth 凭证（未配置时登录按钮显示引导文案）。
    var hasCredentials: Bool {
        // Bundle 里已注入的凭证非空才算可用。
        let info = Bundle.main.infoDictionary
        let clientID = info?["BANGUMI_APP_ID"] as? String ?? ""
        let secret = info?["BANGUMI_APP_SECRET"] as? String ?? ""
        return !clientID.isEmpty && !secret.isEmpty
    }

    /// 启动时调用一次：异步建库。
    ///
    /// 这里**不发网络请求**：`AppModel.init` 会调它，单元测试也会走到，
    /// 登录态校验放到真正打开 Bangumi 分区时（`revalidateSessionIfNeeded`）。
    func setup() {
        context.setupIfNeeded()
    }

    // MARK: - 登录 / 登出

    /// 处理 OAuth 回调 URL（提取 code 并换 token）。返回错误文案（nil = 成功）。
    @discardableResult
    func handleOAuthCallback(url: URL) async -> String? {
        // 回调形如 ocplayer://oauth/callback?code=xxx：
        // host 是 "oauth"，path 是 "/callback"，code 在 query 里。
        guard url.scheme == "ocplayer", url.host == "oauth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            authError = "回调地址无效"
            return authError
        }
        do {
            try await BangumiAuthService.exchangeForAccessToken(code: code)
            authError = nil
            return nil
        } catch {
            let message = (error as? BangumiError)?.userMessage ?? "\(error)"
            BangumiDiagnostics.log("OAuth 换取 token 失败 error=\(error)")
            authError = message
            return message
        }
    }

    func signOut() async {
        await context.signOutBangumi()
        authError = nil
    }

    /// 收到 401 通知：作废该代凭证并把 UI 拉回未登录态。
    ///
    /// 挂在 `RootView`（全生命周期都在）而不是 Bangumi 分区的视图上——在详情页标记章节、
    /// 或播放结束自动标记时撞到 401，Bangumi 页面可能根本没被创建过。
    func handleAuthenticationRequired(generation: UInt64) async {
        await BangumiAuthService.invalidateSession(expectedCredentialGeneration: generation)
        if !context.isAuthenticated {
            authError = BangumiError.requireLogin.userMessage
        }
    }

    /// 打开 Bangumi 分区时后台刷新一次 profile：顺带验证 refresh token 还活着。
    /// 每个 App 会话只做一次；失败不动登录态——真过期了会走 401 通知那条路。
    func revalidateSessionIfNeeded() {
        guard context.isAuthenticated, !didRevalidateSession else { return }
        didRevalidateSession = true
        Task {
            do {
                _ = try await BangumiAuthService.refreshProfile()
            } catch {
                BangumiDiagnostics.log("校验 Bangumi 登录态失败 error=\(error)")
            }
        }
    }

    private var didRevalidateSession = false

    // MARK: - 数据

    @discardableResult
    func refreshCollections(force: Bool = false) async throws -> Int {
        try await context.refreshAllCollections(force: force)
    }
}
