import ErikaKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import Combine
#endif

/// 全 App 覆盖式播放器（Infuse 风格悬浮控件）：
/// - 画面铺满整个窗口 / 屏幕，控件浮在上面
/// - macOS：鼠标动一下就唤出，播放中 3 秒自动隐藏；iOS：点画面切换显示
/// - 暂停 / 缓冲 / 出错时控件常驻；顶部「×」或 ESC 关闭
///
/// 音轨 / 字幕菜单是 M2 范围（内核 `select_*_track` 已核实可用），这里先留位。
struct PlayerScreen: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 覆盖层出现时要打开的源；nil = 空画面（引擎失败等极端情况）。
    let request: PlaybackRequest?

    @State private var hudVisibility = PlayerHUDVisibilityCoordinator()
    @State private var showStats = false
    @State private var showInfoCard = false
    @State private var isImportingSubtitle = false
    @State private var isSelectingDanmaku = false
    @State private var screenshotToast: String?
    /// 只存布局档位，不存逐像素宽度，窗口缩放时不会让整套 HUD 每像素重建。
    @State private var isNarrow = false
    #if os(macOS)
    @State private var isFullscreen = false
    /// 键盘监听器引用（安装后持有，退出播放器时移除）。用 NSEvent local monitor 而不是
    /// `.onKeyPress`：后者要求视图先拿到键盘焦点，覆盖层播放器根本抢不到焦点，按键会静默丢失。
    @State private var keyMonitor: Any?
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerVideoSurface(
                engine: controller.engine,
                title: request?.title ?? "没有正在播放的内容",
                setupError: controller.setupError
            )
            playerGestureLayer

            if controller.state.isBuffering && controller.state.state == .playing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if controller.state.state == .error || controller.setupError != nil {
                PlayerPlaybackErrorBadge()
            }

            PlayerHUDOverlay(
                isNarrow: isNarrow,
                playbackID: request?.id.uuidString ?? "",
                title: mainTitle,
                kicker: titleKicker,
                isImportingSubtitle: $isImportingSubtitle,
                isSelectingDanmaku: $isSelectingDanmaku,
                showStats: $showStats,
                showInfoCard: $showInfoCard,
                shareURL: shareURL,
                isFullscreen: hudIsFullscreen,
                onClose: closePlayer,
                onToggleFullscreen: toggleFullscreenFromHUD,
                onCapture: captureNow,
                onShare: shareNow,
                onInteractionChanged: handleHUDInteraction,
                onUserInteraction: revealControls,
                onMenuPresented: holdControlsForMenu
            )
            .opacity(hudVisibility.isVisible ? 1 : 0)
            .allowsHitTesting(hudVisibility.isVisible)
            .accessibilityHidden(!hudVisibility.isVisible)
            .motionAnimation(.easeInOut(duration: 0.2), value: hudVisibility.isVisible, reduceMotion: reduceMotion)

            if showStats {
                PlayerHUDStatsPanel()
            }
            if showInfoCard {
                PlayerHUDInfoPanel(title: mainTitle, kicker: titleKicker, isNarrow: isNarrow)
            }
            PlayerScreenshotToast(message: screenshotToast)
        }
        // opening→ready/playing 时让 loading 层、缓冲圈、错误徽章的显隐柔和过渡。
        .motionAnimation(.easeInOut(duration: 0.2), value: controller.state.state, reduceMotion: reduceMotion)
        // HUD 只在播放器子树使用 dark scheme；系统 Glass、Menu、Slider 和语义前景色
        // 因此走同一套解析，不会把底层 AppShell 的外观一并切换。
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < 560
        } action: { isNarrow = $0 }
        .fileImporter(isPresented: $isImportingSubtitle,
                      allowedContentTypes: Self.subtitleTypes) { result in
            if case .success(let url) = result {
                controller.loadExternalSubtitle(fileURL: url)
            }
        }
        .sheet(isPresented: $isSelectingDanmaku) {
            let suggestion = app.danmaku.searchSuggestion(for: request?.id)
            DanmakuSelectionSheet(
                requestID: request?.id,
                initialAnime: suggestion?.anime
                    ?? app.nowPlayingItem?.seriesName
                    ?? app.nowPlayingItem?.name
                    ?? mainTitle,
                initialEpisode: suggestion?.episode
                    ?? app.nowPlayingItem?.episodeNumber.map(String.init)
                    ?? ""
            )
        }
        #if os(macOS)
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location):
                hudVisibility.pointerMoved(to: location, canAutoHide: canAutoHideControls)
            case .ended:
                hudVisibility.pointerExited()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) {
            notification in
            guard let menu = notification.object as? NSMenu else { return }
            hudVisibility.menuTrackingDidBegin(menu, canAutoHide: canAutoHideControls)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) {
            notification in
            guard let menu = notification.object as? NSMenu else { return }
            hudVisibility.menuTrackingDidEnd(menu, canAutoHide: canAutoHideControls)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
            notification in
            guard let window = notification.object as? NSWindow,
                  window.isKeyWindow || window.isMainWindow
            else { return }
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
            notification in
            guard let window = notification.object as? NSWindow,
                  window.isKeyWindow || window.isMainWindow || isFullscreen
            else { return }
            isFullscreen = false
        }
        #endif
        .onAppear {
            PlaybackLog.append("PlayerScreen onAppear request=\(request?.title ?? "nil")")
            #if os(macOS)
            playerLog.info("PlayerScreen onAppear")
            PlayerWindowFitter.saveOriginalIfNeeded()
            installKeyMonitor()
            isFullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            #endif
        }
        // task(id:)：覆盖层已开着时换片（onOpenURL / 播另一集）也能重新打开
        .task(id: request) {
            guard let request, !Task.isCancelled else { return }
            PlaybackLog.append("PlayerScreen task id=\(request.title)")
            controller.openIfNeeded(request)
            guard !Task.isCancelled else { return }
            revealControls()
        }
        .onChange(of: request?.id) {
            isSelectingDanmaku = false
        }
        .onChange(of: controller.state.state) { _, newState in
            PlaybackLog.append("PlayerState -> \(newState)")
        }
        // 暂停、缓冲、错误、菜单面板和辅助功能统一走同一条显隐资格规则，
        // 避免新增一个阻止自动隐藏的状态时漏掉对应监听。
        .onChange(of: canAutoHideControls, initial: true) {
            revealControls()
        }
        .onDisappear { hudVisibility.cancel() }
        #if os(macOS)
        .onChange(of: controller.state.videoParams) { _, params in
            // 视频参数到达 / 换片 → 窗口贴合视频比例（重复同规格不抖动，见 Fitter）
            if let params {
                PlayerWindowFitter.fit(videoWidth: params.width, videoHeight: params.height)
            }
        }
        .onDisappear {
            playerLog.info("PlayerScreen onDisappear")
            PlaybackLog.append("PlayerScreen onDisappear")
            PlayerWindowFitter.restore()
            uninstallKeyMonitor()
        }
        #endif
    }

    /// 画面手势使用独立命中层，位于视频之上、HUD 之下。
    /// Button、Menu 和 Slider 因此不会再把点击冒泡成播放暂停或隐藏 HUD。
    private var playerGestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            #if os(macOS)
            .onTapGesture(count: 2) { toggleFullscreen() }
            .onTapGesture { toggleControls() }
            #else
            .onTapGesture(count: 2) { controller.togglePlayPause() }
            .onTapGesture { toggleControls() }
            #endif
    }

    // MARK: - 显隐控制

    private func revealControls() {
        hudVisibility.reveal(canAutoHide: canAutoHideControls)
    }

    private func toggleControls() {
        if hudVisibility.isVisible {
            hudVisibility.hide()
        } else {
            revealControls()
        }
    }

    private func handleHUDInteraction(_ interaction: PlayerHUDInteraction, _ active: Bool) {
        hudVisibility.setInteraction(
            interaction,
            active: active,
            canAutoHide: canAutoHideControls
        )
    }

    private func holdControlsForMenu() {
        hudVisibility.holdForMenu(canAutoHide: canAutoHideControls)
    }

    /// 播放、拖动、缓冲和辅助面板都由同一条规则决定 HUD 是否可以自动收起。
    private var canAutoHideControls: Bool {
        controller.state.state == .playing
            && !controller.state.isBuffering
            && controller.setupError == nil
            && !showStats
            && !showInfoCard
            && !isImportingSubtitle
            && !isSelectingDanmaku
            && !isVoiceOverEnabled
    }

    private func closePlayer() {
        playerLog.info("closePlayer（ESC / ×）")
        PlaybackLog.append("closePlayer（ESC / ×）")
        hudVisibility.cancel()
        // 绑定本次关闭的 request：延迟 dismiss 期间若用户已开新片，不能误清新 presentedPlayer。
        let closingID = request?.id
        // 先触发窗口还原动画（画面还在，窗口缩小时播放内容跟着一起缩小），
        // 再停引擎，等窗口缩完再退出播放器——不会出现「播放器没了，窗口自己在动」的不连贯。
        PlayerWindowFitter.restore()
        controller.stopPlayback()
        Task { @MainActor in
            // 窗口弹性动画约 0.18-0.2s，等一下让它跑完再 dismiss。
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            guard PlayerClosePolicy.shouldDismiss(
                presentedID: app.presentedPlayer?.id,
                closingID: closingID
            ) else { return }
            app.dismissPlayer()
        }
    }

    private var hudIsFullscreen: Bool {
        #if os(macOS)
        isFullscreen
        #else
        false
        #endif
    }

    private func toggleFullscreenFromHUD() {
        #if os(macOS)
        toggleFullscreen()
        #endif
    }

    #if os(macOS)
    private func toggleFullscreen() {
        guard let window = NSApp.keyWindow else { return }
        // 不在这里翻转 isFullscreen：等 didEnter/didExit 通知与系统状态对齐，
        // 避免与绿键/菜单全屏抢状态。
        window.toggleFullScreen(nil)
        revealControls()
    }
    #endif

    // MARK: - 键盘（macOS）

    #if os(macOS)
    /// 安装全局本地键盘监听。`NSEvent.addLocalMonitorForEvents` 在主线程拦截 App 的按键，
    /// 不依赖视图焦点——播放器是覆盖层，`.onKeyPress` 抢不到焦点所以不响。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func uninstallKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// 处理一个按键；返回 true 表示已消费（不再下传），false 放行给系统。
    private func handleKey(_ event: NSEvent) -> Bool {
        // 只吃无修饰键的按键，Cmd/Ctrl/Option 组合留给系统（Cmd+Q 等）。
        let cmd = event.modifierFlags.intersection([.command, .control, .option])
        guard cmd.isEmpty else { return false }
        // Slider、Menu 或其他原生控件拿到键盘焦点时，方向键和空格应交还给控件。
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSControl || responder is NSTextView {
            return false
        }

        switch event.keyCode {
        case 49:  // space
            controller.togglePlayPause(); revealControls(); return true
        case 36:  // return
            controller.togglePlayPause(); revealControls(); return true
        case 53:  // escape
            closePlayer(); return true
        case 123: // left arrow
            controller.skip(by: -10); revealControls(); return true
        case 124: // right arrow
            controller.skip(by: 10); revealControls(); return true
        case 125: // down arrow
            controller.adjustVolume(by: -0.1); revealControls(); return true
        case 126: // up arrow
            controller.adjustVolume(by: 0.1); revealControls(); return true
        case 38:  // j
            controller.skip(by: -10); revealControls(); return true
        case 37:  // l
            controller.skip(by: 10); revealControls(); return true
        case 46:  // m
            controller.toggleMute(); revealControls(); return true
        case 3:   // f
            toggleFullscreen(); return true
        default:
            return false
        }
    }
    #endif

    /// 分享：macOS 弹系统分享面板——直连流分享 URL，本地文件分享文件本身。
    private func shareNow() {
        #if os(macOS)
        guard let view = NSApp.keyWindow?.contentView, let shareURL else { return }
        let picker = NSSharingServicePicker(items: [shareURL])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        #endif
    }

    /// Jellyfin 流依赖 Authorization 请求头，不能只分享裸 URL；这类源不显示分享入口。
    private var shareURL: URL? {
        if let local = request?.securityScopedURL { return local }
        if let uri = request?.uri, FileManager.default.fileExists(atPath: uri) {
            return URL(fileURLWithPath: uri)
        }
        guard request?.authHeader == nil,
              let uri = request?.uri, let url = URL(string: uri),
              url.scheme == "http" || url.scheme == "https"
        else {
            return nil
        }
        return url
    }

    private func captureNow() {
        guard let name = controller.captureScreenshot() else {
            revealControls()
            return
        }
        screenshotToast = "已保存：\(name)"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            screenshotToast = nil
        }
    }

    /// Infuse 版式：小字显示集号和单集名，大字显示系列名。
    private var titleKicker: String {
        guard let item = app.nowPlayingItem, let episodeLabel = item.episodeLabel else { return "" }
        return "\(episodeLabel) · \(item.name)"
    }

    private var mainTitle: String {
        if let item = app.nowPlayingItem {
            if item.episodeLabel != nil { return item.seriesName ?? item.name }
            return item.name
        }
        return controller.currentTitle ?? request?.title ?? ""
    }

    private static var subtitleTypes: [UTType] {
        ["srt", "ass", "ssa", "vtt"]
            .compactMap { UTType(filenameExtension: $0, conformingTo: .text) }
    }
}
