import AppDesignKit
import JellyfinKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

/// 根视图：有会话 → 主框架（侧栏 / Tab）；没有 → 登录流程。
/// 播放器是盖在这一切之上的**全 App 覆盖层**（`presentedPlayer` 非 nil 时）。
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackController.self) private var controller
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var updateChecker = AppUpdateChecker.shared

    var body: some View {
        Group {
            switch app.phase {
            case .boot:
                VStack(spacing: 12) {
                    Image(systemName: "cat.fill")
                        .font(.system(size: 40))
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.section)
            case .onboarding:
                OnboardingView()
                    .transition(.section)
            case .ready:
                AppShellView()
                    .transition(.section)
            }
        }
        .motionAnimation(Motion.slide, value: app.phase, reduceMotion: reduceMotion)
        #if os(macOS)
        // 播放时藏掉窗口工具栏（侧栏收缩钮 / 标题都住在里面），内容铺满整个窗口
        .toolbar((app.presentedPlayer == nil && app.playbackPreparation == nil) ? .visible : .hidden, for: .windowToolbar)
        #endif
        .overlay {
            if let request = app.presentedPlayer {
                PlayerScreen(request: request)
                    .ignoresSafeArea()
                    // 红绿灯（macOS）/ Home 指示条（iOS）也藏，退出播放自动回来
                    .persistentSystemOverlays(.hidden)
                    #if os(iOS)
                    .statusBarHidden(true)
                    #endif
                    .transition(.cinematic)
            }
            // 准备态 loading 盖在 PlayerScreen 之上，一直盖到内核真正出帧
            // （ready/playing）才由 AppModel 撤除——全程一段 loading，不再
            // 「loading 退出后还要再等内核 open」。
            if let prep = app.playbackPreparation {
                PlayerLoadingLayer(preparation: prep,
                                   onCancel: app.cancelPlaybackOpening,
                                   onRetry: app.retryPlayback)
                    .ignoresSafeArea()
                    .persistentSystemOverlays(.hidden)
                    .transition(.section)
                    .zIndex(1)
            }
        }
        .motionAnimation(Motion.standard, value: app.presentedPlayer, reduceMotion: reduceMotion)
        // loading 淡出（首帧已上屏后）稍长一点：黑屏 loading 与画面交叉融化，
        // 出画面是"浮现"而不是"闪现"。
        .motionAnimation(Motion.slide, value: app.playbackPreparation, reduceMotion: reduceMotion)
        .onOpenURL { url in
            if url.scheme == "ocplayer", url.host == "oauth" {
                // 错误由 BangumiCoordinator.authError 承接，登录页会显示出来。
                Task { await app.handleBangumiOAuthURL(url) }
            } else {
                app.presentLocalFile(url)
            }
        }
        // Bangumi / MoviePilot 凭证失效：监听放根视图（401 可能来自任何页面，
        // 那时对应分区的视图未必存在）。解码 + 挂载共用 `onAuthenticationRequired`。
        .onAuthenticationRequired(BangumiCoordinator.authenticationRequiredNotification) { generation in
            await app.bangumi.handleAuthenticationRequired(generation: generation)
        }
        .onAuthenticationRequired(MoviePilotCoordinator.authenticationRequiredNotification) { generation in
            await moviepilot.handleAuthenticationRequired(generation: generation)
        }
        // Jellyfin token 失效（鉴权 API 401，包内无重登兜底）：清死 token 回登录流程。
        // 包内已在主线程投递且带 profileID，App 侧按会话状态去重。
        .onReceive(NotificationCenter.default.publisher(
            for: JellyfinAuthentication.authenticationRequired)) { note in
            guard let profileID = note.object as? String else { return }
            app.handleJellyfinAuthenticationRequired(profileID: profileID)
        }
        .task {
            app.playback = controller
            // 媒体键 / 控制中心的回调装一次就够（命令中心是全局单例）。
            controller.installRemoteCommandHandlers()
            app.bootstrap()
            await LaunchOptions.run(with: controller, presentPlayer: { url in
                app.presentLocalFile(url)
            })
        }
        // 播放入口（本地文件 / 直连链接）挂在根视图：macOS 文件菜单 Cmd+O 在
        // 任何分区（设置 / Bangumi / MoviePilot…）下都可能触发，挂在某个分区
        // 页里会够不到；isPresented 直接绑 AppModel 标志，入口只管置 true。
        .fileImporter(
            isPresented: Binding(
                get: { app.isLocalFileImporterPresented },
                set: { app.isLocalFileImporterPresented = $0 }
            ),
            allowedContentTypes: Self.playableTypes
        ) { result in
            if case .success(let url) = result { app.presentLocalFile(url) }
        }
        .sheet(isPresented: Binding(
            get: { app.isDirectLinkSheetPresented },
            set: { app.isDirectLinkSheetPresented = $0 }
        )) {
            URLEntrySheet { uri, token in
                app.presentRequest(PlaybackController.request(uri: uri, jellyfinToken: token))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                _ = app.playbackDidEnterBackground()
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            _ = app.playbackWillTerminate()
        }
        #endif
        .sheet(item: $updateChecker.promptRelease) { release in
            UpdateReleaseSheet(release: release)
        }
    }

    /// fileImporter 接受的媒体类型。
    private static var playableTypes: [UTType] {
        [.audiovisualContent, .movie, .video, .mpeg4Movie, .quickTimeMovie]
            + [UTType("org.matroska.mkv")].compactMap { $0 }
    }
}

/// 直连链接输入弹窗（M0 验证 `open_with_headers` 用）。
/// 入口：首页工具栏「打开」菜单 / macOS 文件菜单（Cmd+Shift+O）。
struct URLEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var uri = ""
    @State private var token = ""
    let onSubmit: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开直连链接").font(.headline)
            TextField("http://…/Videos/{id}/stream?static=true", text: $uri)
                .textFieldStyle(.roundedBorder)
            SecureField("服务器 AccessToken（可留空）", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("token 只作为请求头发给内核，不写进 URL、不落日志。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("播放") {
                    onSubmit(uri.trimmingCharacters(in: .whitespacesAndNewlines),
                             token.isEmpty ? nil : token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
