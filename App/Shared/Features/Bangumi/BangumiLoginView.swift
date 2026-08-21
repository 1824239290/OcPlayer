import BangumiKit
import SwiftUI

#if os(iOS)
import AuthenticationServices
#endif

/// Bangumi 登录视图：未登录时显示登录引导，已登录时显示用户信息。
/// 放在 Bangumi 功能区的根，作为未登录态的门面。
struct BangumiLoginView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @State private var isPresentingAuth = false
    @State private var authError: String?
    @State private var pendingAuthURL: URL?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("连接 Bangumi")
                .font(.title2.weight(.semibold))
            Text("登录后可以在这里管理你的观看进度、收藏和个人主页。\nOcPlayer 会同步你标记的「在看 / 看过」，播放器联动章节进度。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if !bangumi.hasCredentials {
                VStack(alignment: .leading, spacing: 6) {
                    Label("尚未配置 Bangumi OAuth 凭证", systemImage: "key.slash")
                        .font(.callout.weight(.medium))
                    Text("在 bgm.tv 的个人设置里创建 OAuth 应用（回调地址填 ocplayer://oauth/callback），然后把 client_id / client_secret 填进 Secrets.xcconfig。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: 420, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Button {
                    Task { await startOAuth() }
                } label: {
                    if bangumi.isAuthenticated {
                        Label("已登录，打开 Bangumi", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("登录 Bangumi", systemImage: "arrow.right.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let authError {
                Label(authError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: pendingAuthURL) { _, url in
            guard let url else { return }
            presentAuthSession(url: url)
        }
    }

    private func startOAuth() async {
        authError = nil
        let url = await BangumiAuthService.buildOAuthURL()
        pendingAuthURL = url
    }

    #if os(macOS)
    private func presentAuthSession(url: URL) {
        // macOS 打开系统浏览器完成授权，回调经 onOpenURL 回到 App。
        NSWorkspace.shared.open(url)
        isPresentingAuth = false
        pendingAuthURL = nil
    }
    #else
    private func presentAuthSession(url: URL) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "ocplayer"
        ) { callbackURL, error in
            pendingAuthURL = nil
            Task { @MainActor in
                if let error {
                    authError = "授权失败：\(error.localizedDescription)"
                    return
                }
                guard let callbackURL else {
                    authError = "授权回调为空"
                    return
                }
                authError = await app.handleBangumiOAuthURL(callbackURL)
            }
        }
        session.presentationContextProvider = nil
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }
    #endif
}
