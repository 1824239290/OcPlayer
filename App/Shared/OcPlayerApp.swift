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

/// iOS 方向控制：播放器覆盖层打开时锁横屏，退出后回浏览态。
/// iPhone 浏览态锁竖屏（浏览/设置等页面都是竖屏布局）；
/// iPad 浏览态跟随重力自由旋转（pbxproj 已声明四方向），只有播放中锁横屏。
/// SwiftUI 生命周期没有 AppDelegate，用 @UIApplicationDelegateAdaptor 桥接。
@MainActor
final class IOSApplicationDelegate: NSObject, UIApplicationDelegate {
    /// 播放器覆盖层打开时锁横屏；退出后按设备类型解锁。
    private(set) var playerIsActive = false
    /// setPlayerActive 时 scene 尚未连接（启动即播的自检路径）：把方向刷新攒下来，
    /// 等 scene 激活通知到达后补发——否则这次旋转请求会被整个丢掉，播放中横屏锁失效。
    private var pendingOrientationRefresh = false

    /// 浏览态允许的方向：iPhone 竖屏，iPad 四方向跟重力。
    private var browsingMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIScene.didActivateNotification, object: nil)
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        playerIsActive ? .landscape : browsingMask
    }

    /// 由 AppModel.presentedPlayer 的 didSet 回调调用：切换方向约束 + 主动旋转。
    func setPlayerActive(_ active: Bool) {
        guard active != playerIsActive else { return }
        playerIsActive = active
        pendingOrientationRefresh = true
        applyPendingOrientationRefresh()
    }

    /// 启动极早期 connectedScenes 可能为空，找不到 scene 就攒着；
    /// 有了 scene 就把当前 playerIsActive 对应的方向请求落下去。
    private func applyPendingOrientationRefresh() {
        guard pendingOrientationRefresh else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        else { return }
        pendingOrientationRefresh = false
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: playerIsActive ? .landscape : browsingMask))
        scene.windows.first(where: \.isKeyWindow)?
            .rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// scene 首次连接 / 激活：补发启动即播时攒下的方向请求。
    @objc private func sceneDidActivate(_ notification: Notification) {
        applyPendingOrientationRefresh()
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
        // 先把设置里的日志级别落到管线上，再动别的东西——第一条日志的级别要先对。
        // trace 文件按会话清一次（它们无上限增长，不清就跨次累积）。
        DiagnosticsSettings.apply()
        KernelTraceSwitches.prepareForLaunch(
            logDirectory: AppDiagnostics.fileURL.deletingLastPathComponent())
        // 接住内核 stderr（`ErikaHDR` / 内核 trace 的 stderr 回声）：GUI 启动时 fd 2
        // 归 launchd，不接就永远看不到；必须在第一次内核调用（播放时的引擎创建）之前启动。
        KernelStderrPump.shared.start()
        // 内核注册必须在任何播放之前：PlaybackController.prepareEngine() 会从
        // 注册表现取当前选择。见 PlaybackEngineAssembly（唯一认识具体内核的地方）。
        PlaybackEngineAssembly.registerAll()
        #if os(iOS)
        // 方向回调必须在**任何播放可能发生之前**装配：启动即播的自检路径在
        // RootView.task 里同步 present，装配若放在 WindowGroup.onAppear 会晚于
        // 首次 presentedPlayer 赋值，setPlayerActive 永远不会被调用，
        // 播放中的横屏锁整个失效。
        appModel.orientationChangeHandler = { [weak iosAppDelegate] active in
            iosAppDelegate?.setPlayerActive(active)
        }
        #endif
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
                        // 有界等待：2 秒内没落完就放行退出（别吊住用户关窗口）。
                        AppDiagnostics.flush(timeout: 2)
                        return task
                    }
                }
                // 首页英雄区需要保留标题两侧边距和操作按钮；低于这个宽度时，
                // macOS 的 NavigationSplitView 会把详情列压到不可读，窗口不再继续缩窄。
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
        // 文件菜单：播放入口（本地文件 / 直连链接）从设置页迁来，补上
        // macOS 惯例的 Cmd+O。直接引用 App 层的 appModel 置请求标志，
        // RootView 上的 fileImporter / URLEntrySheet 负责真正呈现。
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开本地视频文件…") {
                    appModel.isLocalFileImporterPresented = true
                }
                .keyboardShortcut("o")
                Button("打开直连链接…") {
                    appModel.isDirectLinkSheetPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
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