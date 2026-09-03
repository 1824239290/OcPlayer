import JellyfinKit
import SwiftUI

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
        // Bangumi 凭证失效：监听放在根视图，因为 401 也可能来自详情页标记章节、
        // 或者播放结束自动标记——那时 Bangumi 分区的视图未必存在。
        .onReceive(NotificationCenter.default.publisher(
            for: BangumiCoordinator.authenticationRequiredNotification)) { note in
            guard let generation = BangumiCoordinator.authenticationGeneration(from: note) else { return }
            Task { await app.bangumi.handleAuthenticationRequired(generation: generation) }
        }
        // MoviePilot 同理：401 且静默重登失败（密码改了）时把设置页拉回未登录态。
        .onReceive(NotificationCenter.default.publisher(
            for: MoviePilotCoordinator.authenticationRequiredNotification)) { note in
            guard let generation = MoviePilotCoordinator.authenticationGeneration(from: note) else { return }
            Task { await moviepilot.handleAuthenticationRequired(generation: generation) }
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
}
