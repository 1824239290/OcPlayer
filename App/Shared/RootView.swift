import SwiftUI

#if os(iOS)
import UIKit
#endif

/// 根视图：有会话 → 主框架（侧栏 / Tab）；没有 → 登录流程。
/// 播放器是盖在这一切之上的**全 App 覆盖层**（`presentedPlayer` 非 nil 时）。
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

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
            case .onboarding:
                OnboardingView()
            case .ready:
                AppShellView()
            }
        }
        #if os(macOS)
        // 播放时藏掉窗口工具栏（侧栏收缩钮 / 标题都住在里面），内容铺满整个窗口
        .toolbar((app.presentedPlayer == nil && app.playbackPreparation == nil) ? .visible : .hidden, for: .windowToolbar)
        #endif
        .overlay {
            // 准备态覆盖层：点击播放后、URI 解析完成前。presentedPlayer 一旦设值，
            // preparation 即被清空，loading 层淡出、PlayerScreen 淡入，无缝衔接。
            if app.presentedPlayer == nil, let prep = app.playbackPreparation {
                PlayerLoadingLayer(preparation: prep,
                                   onCancel: app.cancelPlaybackOpening,
                                   onRetry: app.retryPlayback)
                    .ignoresSafeArea()
                    .persistentSystemOverlays(.hidden)
                    .transition(.opacity)
            }
            if let request = app.presentedPlayer {
                PlayerScreen(request: request)
                    .ignoresSafeArea()
                    // 红绿灯（macOS）/ Home 指示条（iOS）也藏，退出播放自动回来
                    .persistentSystemOverlays(.hidden)
                    #if os(iOS)
                    .statusBarHidden(true)
                    #endif
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: app.presentedPlayer)
        .animation(.easeInOut(duration: 0.18), value: app.playbackPreparation)
        .onOpenURL { url in
            app.presentLocalFile(url)
        }
        .task {
            app.playback = controller
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
    }
}
