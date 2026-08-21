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

    var isAuthenticated: Bool { context.isAuthenticated }
    var profile: BangumiProfile? { context.profile }
    var isDatabaseReady: Bool { context.isDatabaseReady }

    /// 是否配置了 OAuth 凭证（未配置时登录按钮显示引导文案）。
    var hasCredentials: Bool {
        // Bundle 里已注入的凭证非空才算可用。
        let info = Bundle.main.infoDictionary
        let clientID = info?["BANGUMI_APP_ID"] as? String ?? ""
        let secret = info?["BANGUMI_APP_SECRET"] as? String ?? ""
        return !clientID.isEmpty && !secret.isEmpty
    }

    /// 启动时调用一次：异步建库。
    func setup() {
        context.setupIfNeeded()
    }

    // MARK: - 登录 / 登出

    /// 处理 OAuth 回调 URL（提取 code 并换 token）。返回错误文案（nil = 成功）。
    func handleOAuthCallback(url: URL) async -> String? {
        // 回调形如 ocplayer://oauth/callback?code=xxx：
        // host 是 "oauth"，path 是 "/callback"，code 在 query 里。
        guard url.scheme == "ocplayer", url.host == "oauth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return "回调地址无效" }
        do {
            try await BangumiAuthService.exchangeForAccessToken(code: code)
            return nil
        } catch {
            let message = (error as? BangumiError)?.userMessage ?? "\(error)"
            return message
        }
    }

    func signOut() async {
        await context.signOutBangumi()
    }

    // MARK: - 数据

    func refreshCollections(force: Bool = false) async throws -> Int {
        try await context.refreshAllCollections(force: force)
    }
}
