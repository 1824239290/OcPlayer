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
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    /// 启动动画状态机（门控/时钟/撤除都在 presenter，见 LaunchPresenter）。
    @State private var launch = LaunchPresenter()
    /// iOS 预热可能在后台把 UI 建出来：后台不动画，激活再起表。
    @State private var launchAwaitingScene = false
    @State private var updateChecker = AppUpdateChecker.shared
    /// RootView 自身的系统安全区（灵动岛 / 圆角 / home indicator 禁区）。播放覆盖层
    /// 整体 `.ignoresSafeArea()` 全屏 bleed 后子树内读不到它，从这层读出来经
    /// PlayerScreen 注入给 HUD 锚点做让位（见 PlayerChromeMetrics）。
    @State private var chromeInsets: EdgeInsets = EdgeInsets()

    /// 按启动阶段选根页：有会话 → 主框架；没有 → 登录流程。
    ///
    /// 抽成属性只为让自检通道（`#if OCPLAYER_SELFTEST`）能在它之前插一层——
    /// 判断顺序本身没变，仍是 `.boot` → `.onboarding` → `.ready`。
    @ViewBuilder
    private var phaseContent: some View {
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

    var body: some View {
        Group {
            #if OCPLAYER_SELFTEST
            // 自检通道（Debug-only）：iPad 详情页翻页版式验收台。
            //
            // **必须判在 `app.phase` 之前**：它存在的意义就是「不接服务器也能看真实
            // 渲染」，而没有会话时 `phase == .onboarding`，登录页会挡住整个 AppShell。
            // 正常入口也进不去详情页——`OCPLAYER_START_ROUTE=detail*` 要求首页已载入
            // 带背景图的条目（见 `AppModel+LaunchRoute`），没服务器首页就是空的。
            if MyDashboardPreviewStage.isRequested {
                MyDashboardPreviewStage()
            } else if DetailFlipPreviewStage.isRequested {
                DetailFlipPreviewStage()
                    .transition(.section)
            } else {
                phaseContent
            }
            #else
            phaseContent
            #endif
        }
        .motion(Motion.slide, value: app.phase)
        // 全局恢复中性灰白，实底按钮与开关沿用原来的对比度配方。
        // 类型分布的品牌橙仅在图例处指定，不向其他控件传播。
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
            #if OCPLAYER_SELFTEST
            guard !MyDashboardPreviewStage.isRequested else { return }
            #endif
            app.playback = controller
            // 媒体键 / 控制中心的回调装一次就够（命令中心是全局单例）。
            controller.installRemoteCommandHandlers()
            await app.bootstrap()
            await LaunchOptions.run(with: controller, presentPlayer: { url in
                app.presentLocalFile(url)
            })
        }
        .task(id: app.viewingAvatarRequest(bangumiEnabled: bangumiEnabled)) {
            #if OCPLAYER_SELFTEST
            guard !MyDashboardPreviewStage.isRequested else { return }
            #endif
            // Prewarm globally, including while browsing Home. The dashboard never
            // decides between server/Bangumi avatars after its header has appeared.
            await app.viewingProfileAvatar.load(
                app.viewingAvatarRequest(bangumiEnabled: bangumiEnabled), pipeline: app.avatarImagePipeline)
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
                controller.checkpointLocalViewingRecord()
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
        #if OCPLAYER_SELFTEST
        guard !MyDashboardPreviewStage.isRequested else { return }
        #endif
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
        FormSheetShell(
            title: "打开直连链接",
            symbol: "play.rectangle",
            subtitle: "播放 HTTP/HTTPS 视频直链或本地文件。",
            confirmEnabled: isAcceptable,
            onConfirm: play,
            confirmLabel: { Label("播放", systemImage: "play.fill") }
        ) {
            LabeledCredentialField(
                label: "视频地址",
                text: $uri,
                prompt: "https://example.com/video.mkv",
                kind: .url
            )
            .onSubmit(play)

            if !trimmedURI.isEmpty && !isAcceptable {
                Label("请输入完整的 HTTP/HTTPS 链接，或以 /、~/ 开头的本地文件路径。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledCredentialField(
                label: "AccessToken（可选）",
                text: $token,
                prompt: "服务器访问令牌",
                caption: "用于需要登录的服务器，可留空。",
                kind: .secure
            )
            .onSubmit(play)
        }
    }

    private func play() {
        guard isAcceptable else { return }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(trimmedURI, trimmedToken.isEmpty ? nil : trimmedToken)
        dismiss()
    }
}
