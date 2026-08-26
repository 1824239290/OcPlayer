import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Task<Void, Never>?)?
    private var terminationInProgress = false
    private var terminationToken: UUID?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let task = terminationHandler?() else { return .terminateNow }
        terminationInProgress = true
        let token = UUID()
        terminationToken = token
        Task { @MainActor [weak self] in
            await task.value
            self?.finishTermination(sender, token: token)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.finishTermination(sender, token: token)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication, token: UUID) {
        guard terminationToken == token else { return }
        terminationToken = nil
        terminationInProgress = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}
#endif

#if os(iOS)
import UIKit

/// iOS 方向控制：播放器覆盖层打开时锁横屏，退出时回竖屏。
/// SwiftUI 生命周期没有 AppDelegate，用 @UIApplicationDelegateAdaptor 桥接。
@MainActor
final class IOSApplicationDelegate: NSObject, UIApplicationDelegate {
    /// 播放器覆盖层是否打开——true 时只允许横屏。
    private(set) var playerIsActive = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        playerIsActive ? .landscape : .all
    }

    /// 由 RootView 在 `presentedPlayer` 变化时调用：切换方向约束 + 主动旋转。
    func setPlayerActive(_ active: Bool) {
        guard active != playerIsActive else { return }
        playerIsActive = active
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: active ? .landscape : .portrait))
        scene.windows.first(where: \.isKeyWindow)?
            .rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif

@main
struct OcPlayerApp: App {
    /// 全局两件套：会话/浏览状态 + 播放控制。
    /// 放 App 层：命令行 / 「用 OcPlayer 打开」这类外部入口要在窗口之外也能喂文件。
    @State private var appModel = AppModel()
    @State private var controller = PlaybackController()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var appDelegate
    #endif
    #if os(iOS)
    @UIApplicationDelegateAdaptor(IOSApplicationDelegate.self) private var iosAppDelegate
    #endif

    init() {
        // 内核注册必须在任何播放之前：PlaybackController.prepareEngine() 会从
        // 注册表现取当前选择。见 PlaybackEngineAssembly（唯一认识具体内核的地方）。
        PlaybackEngineAssembly.registerAll()
        AppDiagnostics.recordLaunch()
        Task { @MainActor in
            await AppUpdateChecker.shared.checkForUpdates()
        }
    }

    var body: some Scene {
        // macOS 单窗口：播放引擎和覆盖层是 App 级单例，多窗口会争抢 surface
        // （WindowGroup 还会把上次会话的每个窗口都恢复出来）。媒体播放器就该一窗。
        // iOS 用 WindowGroup（iPhone 本就单 scene；iPad 多 scene 的争抢 M4 处理）。
        #if os(macOS)
        Window("OcPlayer", id: "main") {
            RootView()
                .environment(appModel)
                .environment(controller)
                .environment(appModel.bangumi)
                .environment(appModel.moviepilot)
                .environment(appModel.danmakuModel)
                .onAppear {
                    appDelegate.terminationHandler = {
                        let task = appModel.playbackWillTerminate()
                        AppDiagnostics.flush()
                        return task
                    }
                }
                // 首页英雄区需要保留标题两侧边距和操作按钮；低于这个宽度时，
                // macOS 的 NavigationSplitView 会把详情列压到不可读，窗口不再继续缩窄。
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
        #else
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(controller)
                .environment(appModel.bangumi)
                .environment(appModel.moviepilot)
                .environment(appModel.danmakuModel)
        }
        #endif
    }
}