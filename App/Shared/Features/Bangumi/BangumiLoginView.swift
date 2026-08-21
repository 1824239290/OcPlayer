import BangumiKit
import SwiftUI

#if os(iOS)
import AuthenticationServices
import UIKit
#endif

/// Bangumi 登录视图：未登录时显示登录引导，已登录时显示用户信息。
/// 放在 Bangumi 功能区的根，作为未登录态的门面。
///
/// 错误文案统一记在 `BangumiCoordinator.authError`：macOS 走系统浏览器 + `onOpenURL`
/// 回来，换 token 失败发生在这个视图之外，只有存在协调器上才显示得出来。
struct BangumiLoginView: View {
    @Environment(BangumiCoordinator.self) private var bangumi

    @State private var pendingAuthURL: URL?
    #if os(iOS)
    /// ASWebAuthenticationSession 必须被强引用住，否则 start() 之后立刻释放、回调永不触发。
    @State private var authSession: ASWebAuthenticationSession?
    @State private var presentationProvider = BangumiAuthPresentationProvider()
    #endif

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

            if let authError = bangumi.authError {
                BangumiNotice(message: authError)
                    .frame(maxWidth: 420)
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
        bangumi.authError = nil
        pendingAuthURL = await BangumiAuthService.buildOAuthURL()
    }

    #if os(macOS)
    private func presentAuthSession(url: URL) {
        // macOS 打开系统浏览器完成授权，回调经 RootView 的 onOpenURL 回到 App。
        NSWorkspace.shared.open(url)
        pendingAuthURL = nil
    }
    #else
    private func presentAuthSession(url: URL) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "ocplayer"
        ) { callbackURL, error in
            Task { @MainActor in
                pendingAuthURL = nil
                authSession = nil
                if let error {
                    // 用户自己取消不算错误，不用报红。
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                    bangumi.authError = "授权失败：\(error.localizedDescription)"
                    return
                }
                guard let callbackURL else {
                    bangumi.authError = "授权回调为空"
                    return
                }
                await bangumi.handleOAuthCallback(url: callbackURL)
            }
        }
        session.presentationContextProvider = presentationProvider
        session.prefersEphemeralWebBrowserSession = false
        // 先持有再 start：局部变量出作用域就会被释放，回调也就没了。
        authSession = session
        session.start()
    }
    #endif
}

#if os(iOS)
/// ASWebAuthenticationSession 的呈现锚点。iOS 上没有它 start() 直接失败。
final class BangumiAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
#endif
