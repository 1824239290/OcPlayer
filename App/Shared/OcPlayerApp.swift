import SwiftUI

@main
struct OcPlayerApp: App {
    /// 全局两件套：会话/浏览状态 + 播放控制。
    /// 放 App 层：命令行 / 「用 OcPlayer 打开」这类外部入口要在窗口之外也能喂文件。
    @State private var appModel = AppModel()
    @State private var controller = PlaybackController()

    var body: some Scene {
        // macOS 单窗口：播放引擎和覆盖层是 App 级单例，多窗口会争抢 surface
        // （WindowGroup 还会把上次会话的每个窗口都恢复出来）。媒体播放器就该一窗。
        // iOS 用 WindowGroup（iPhone 本就单 scene；iPad 多 scene 的争抢 M4 处理）。
        #if os(macOS)
        Window("OcPlayer", id: "main") {
            RootView()
                .environment(appModel)
                .environment(controller)
        }
        .defaultSize(width: 1280, height: 800)
        #else
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(controller)
        }
        #endif
    }
}
