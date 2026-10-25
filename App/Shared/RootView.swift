import AppDesignKit
import JellyfinKit
import PlaybackKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

/// 根视图：有会话 → 主框架（顶栏药丸 / Tab）；没有 → 登录流程。
/// 播放器是盖在这一切之上的**全 App 覆盖层**（`presentedPlayer` 非 nil 时）。
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackController.self) private var controller
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 启动动画状态机（门控/时钟/撤除都在 presenter，见 LaunchPresenter）。
    @State private var launch = LaunchPresenter()
    /// iOS 预热可能在后台把 UI 建出来：后台不动画，激活再起表。
    @State private var launchAwaitingScene = false
    @State private var updateChecker = AppUpdateChecker.shared
    /// RootView 自身的系统安全区（灵动岛 / 圆角 / home indicator 禁区）。播放覆盖层
    /// 整体 `.ignoresSafeArea()` 全屏 bleed 后子树内读不到它，从这层读出来经
    /// PlayerScreen 注入给 HUD 锚点做让位（见 PlayerChromeMetrics）。
    @State private var chromeInsets: EdgeInsets = EdgeInsets()

    var body: some View {
        Group {
            switch app.phase {
            case .boot:
                // 占位与启动动画层同一块底（见 LaunchBackdrop）：系统启动屏 →
                // 首帧 → 交棒全程无跳色。标志与编排都在最上层的动画 overlay 里。
                LaunchBackdrop()
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
        .motion(Motion.slide, value: app.phase)
        // 全 App 的强调色语言 = **中性**：只用前景色亮暗差表达「选中 / 强调」，
        // 色相不参与（与 macOS 顶栏药丸、iOS 标签栏同一套，见 `AppShellSectionGroup`）。
        //
        // **钉在根节点这一个地方**，不再按 Tab 或按平台各钉一遍。tint 是环境值，
        // `Color.accentColor` 与 `.foregroundStyle(.tint)` 都会跟着它走，所以这一行
        // 覆盖：iOS 标签栏选中色、导航栏 / 工具栏按钮、`.bordered*` 按钮、Toggle /
        // Picker / Stepper / Slider / ProgressView 这些吃 tint 的系统控件、以及 40 处
        // 显式 `Color.accentColor` 与 13 处 `.foregroundStyle(.tint)`。macOS 原先没有
        // 任何 pin、跟着用户的系统强调色走（可能是粉 / 石墨），这里一并统一。
        //
        // **曾经的做法别再回去**：`TabView` 上钉 `.tint(Color.primary)` 改标签栏选中色，
        // 再给每个 Tab 根页挂 `.tabContentAccent()`（钉 `Color.blue`）把强调色"钉回去"。
        // 那条路有三重代价——① 每新增一个 Tab 都要记得补一句，漏了不报错、只是那个 Tab
        // 的强调元素悄悄变白；② 钉的是**具体色值** `Color.blue`，等于把全 App 的强调色
        // 写死成系统蓝；③ `.tint` 无法用公开 API 还原成"未设置"（`\.tint` 是 `package`
        // 保护级，`.environment(\.tint, nil)` 编译不过），于是那次"改标签栏"顺带把
        // Toggle（绿→蓝）、菜单式 Picker 取值（灰→蓝）、圆形不定 ProgressView（灰→蓝）、
        // 工具栏按钮（label→蓝）、`.bordered` 底（中性→蓝）一起换了色。
        .tint(Color.primary)
        // 安全区要在 ignoresSafeArea 之外读：RootView 本体处于正常安全区内，
        // 播放锁横屏时这里会跟着重排出新值（横屏顶部归零、侧边变灵动岛禁区）。
        .onGeometryChange(for: EdgeInsets.self) { proxy in
            proxy.safeAreaInsets
        } action: { insets in
            // macOS 不接系统 insets：窗口样式（windowStyle 等）将来若给出非零值，
            // 那属于窗口布局语义、不该混进 HUD 让位——结构性保持恒零
            // （PlayerChromeMetrics 对 macOS 的「恒零退化」承诺因此成立）。
            #if os(iOS)
            chromeInsets = insets
            #endif
        }
        #if os(macOS)
        // 播放时藏掉窗口工具栏（侧栏收缩钮 / 标题都住在里面），内容铺满整个窗口
        // 启动动画**不**藏窗口工具栏（试过藏，回退了）：退场时 hidden→visible 会触发
        // NSToolbar 重建，实测顶栏比首页晚 ~1s 才出现（用户可见的「导航胶囊/搜索框
        // 迟到」）。全程可见的代价只是启动期顶栏条目在 phase 就绪（~100ms）时就位，
        // 玻璃条透出的就是启动底色，深浅色都连续。
        .toolbar((app.presentedPlayer == nil && app.playbackPreparation == nil) ? .visible : .hidden, for: .windowToolbar)
        #endif
        .overlay {
            if let request = app.presentedPlayer {
                PlayerScreen(request: request, chromeInsets: chromeInsets)
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
        .motion(Motion.standard, value: app.presentedPlayer)
        // loading 淡出（首帧已上屏后）稍长一点：黑屏 loading 与画面交叉融化，
        // 出画面是"浮现"而不是"闪现"。
        .motion(Motion.slide, value: app.playbackPreparation)
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
            for: MediaServerAuthentication.authenticationRequired)) { note in
            guard let profileID = note.object as? String else { return }
            app.handleAuthenticationRequired(profileID: profileID)
        }
        .onAppear {
            beginLaunchWhenSceneActive()
            // 氛围池/首页可能在挂载前就已就绪（缓存命中）：onChange 不为初始值
            // 触发，补一拍（两个信号 presenter 内部都会先存后补，早到不丢）。
            if app.ambiencePoolReady {
                launch.ambienceBecameReady()
            }
            if app.homeContentLoaded {
                launch.homeBecameReady()
            }
            #if os(macOS)
            // begin 与 isVisible 变化发生在同一回合，onChange 可能先于窗口就绪：
            // 这里补一拍（present 自身幂等，窗口已存在则跳过）。
            if launch.isVisible {
                LaunchOverlayWindow.shared.present(presenter: launch)
            }
            #endif
        }
        .onChange(of: reduceMotion) { _, newValue in
            launch.updateReduceMotion(newValue)
        }
        .onChange(of: app.phase) { _, phase in
            // 启动数据就绪 → 启动动画开始交棒（begin 之前就绪则 presenter 内部兜底）。
            // 有会话才等氛围池与首页骨架（onboarding / 本地播放没有这些可等）。
            if phase != .boot {
                launch.contentBecameReady(expectAmbience: app.server != nil, expectHome: app.server != nil)
            }
        }
        .onChange(of: app.ambiencePoolReady) { _, ready in
            // 氛围池就绪（池子非空 = 首图已预热）→ 撤掉品牌帧交棒。
            if ready {
                launch.ambienceBecameReady()
            }
        }
        .onChange(of: app.homeContentLoaded) { _, ready in
            // 首页脱离骨架期（有内容可看 / 空库空态 / 错误态）→ 才允许交棒，
            // 否则揭过去是一页空白（用户实测：logo 退场时首页还没加载好）。
            if ready {
                launch.homeBecameReady()
            }
        }
        .task {
            app.playback = controller
            // 媒体键 / 控制中心的回调装一次就够（命令中心是全局单例）。
            controller.installRemoteCommandHandlers()
            await app.bootstrap()
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
            switch phase {
            case .background:
                _ = app.playbackDidEnterBackground()
            case .active:
                if launchAwaitingScene {
                    launchAwaitingScene = false
                    beginLaunchWhenSceneActive()
                }
                // iOS 从挂起里回来：内核的音频出口 / 解码会话未必撑得过来，
                // 由 AppModel 按离开前的意图续播（或静默重建）。
                app.playbackDidEnterForeground()
                // 挂起期间网络可能已经换了（回家 / 出门 / Tailscale 起停）：地址
                // 结论作废，下一个请求重新探活。macOS 不挂起进程，这条基本空转。
                app.invalidateServerEndpoints()
            default:
                break
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            _ = app.playbackWillTerminate()
            // iOS 退出前也要把排队的 JSONL 落盘（此前只收播放上报，最后几条日志会随进程丢）；
            // 有界等待，别在 willTerminate 里吊住系统。
            AppDiagnostics.flush(timeout: 1)
            // 播放日志是另一个 logger 实例，抑制计数在它自己那儿，得一起 flush。
            PlaybackLog.flush(timeout: 1)
        }
        #endif
        .sheet(item: $updateChecker.promptRelease) { release in
            UpdateReleaseSheet(release: release)
        }
        // 启动动画：macOS 用**窗口级覆盖层**（主窗口的工具栏/红绿灯全程不碰，
        // 交棒时整窗揭开，没有任何 chrome 跳变，见 LaunchOverlayWindow）；iOS 用
        // 窗口内 overlay（系统 chrome 没有这个问题）。自检通道整体跳过，不会盖住
        // 自动化画面；纯展示不拦点击，交棒完成后由 presenter 撤除。
        #if os(macOS)
        .onChange(of: launch.isVisible) { _, visible in
            if visible {
                LaunchOverlayWindow.shared.present(presenter: launch)
            } else {
                LaunchOverlayWindow.shared.dismiss()
            }
        }
        #else
        .overlay {
            if launch.isVisible {
                LaunchExperienceView(presenter: launch)
                    .ignoresSafeArea()
            }
        }
        #endif
    }

    /// 启动动画进场：激活态立即起表；后台（iOS 预热）攒到激活。
    private func beginLaunchWhenSceneActive() {
        if scenePhase == .active {
            launch.begin(reduceMotion: reduceMotion)
        } else {
            launchAwaitingScene = true
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

    private var trimmedURI: String {
        uri.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAcceptable: Bool {
        DirectLinkInput.isAcceptable(uri)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开直连链接").font(.headline)
            TextField("http://…/Videos/{id}/stream?static=true", text: $uri)
                .textFieldStyle(.roundedBorder)
            if !trimmedURI.isEmpty && !isAcceptable {
                Text("只支持 http/https 直链，或本地文件绝对路径（/… 或 ~/…）。本地文件也可以直接用 ⌘O 打开。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            SecureField("服务器 AccessToken（可留空）", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("token 只作为请求头发给内核，不写进 URL、不落日志。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("播放") {
                    onSubmit(trimmedURI, token.isEmpty ? nil : token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isAcceptable)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
