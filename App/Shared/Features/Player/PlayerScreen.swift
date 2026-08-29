import PlaybackKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import Combine
#elseif os(iOS)
import UIKit
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
    @Environment(DanmakuModel.self) private var danmakuModel
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

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
    #if os(iOS)
    /// 画面手势层尺寸（左右半屏分界、纵滑量程都按它折算）。
    @State private var panAreaSize: CGSize = .zero
    /// 活动中的滑动手势；nil = 手指不在屏上。驱动 seek 预览条与亮度/音量 OSD。
    @State private var panSession: PlayerPanSession?
    /// 一次触摸的起点（nil = 手指不在屏上）。单击/双击/长按全靠它计时判定。
    @State private var touchStart: TouchStart?
    /// 本触摸最近一次位移；长按定时器到点时判断「手指是否还停在原地」用。
    @State private var touchTranslation: CGSize = .zero
    /// 上一次轻点时刻（双击判定窗口）。
    @State private var lastTapDate: Date?
    /// 单击延迟任务：等双击窗口过期才切 HUD，第二击来了就取消。
    @State private var singleTapTask: Task<Void, Never>?
    /// 长按判定任务：到点仍停在原地才进 2x。
    @State private var holdTask: Task<Void, Never>?

    struct TouchStart {
        let date: Date
        let location: CGPoint
    }

    /// 触摸判定阈值。移动判定统一用 slop；时间用秒（Date 差值）或 Duration（Task.sleep）。
    private enum TouchLimits {
        static let holdDuration: Duration = .milliseconds(350)
        static let tapMaxDuration: TimeInterval = 0.3
        static let movementSlop: CGFloat = 12
        static let panThreshold: CGFloat = 14
        static let doubleTapInterval: TimeInterval = 0.35
        static let singleTapDelay: Duration = .milliseconds(320)
    }
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerVideoSurface(
                engine: controller.engine,
                title: request?.title ?? "没有正在播放的内容",
                setupError: controller.setupError
            )
            #if os(macOS)
            PlayerMouseTrackingView { location in
                hudVisibility.pointerMoved(to: location, canAutoHide: canAutoHideControls)
            } onExited: {
                hudVisibility.pointerExited()
                hudVisibility.hideOnPointerExit()
            }
            #endif
            // 弹幕一律走 App 层 overlay（内核弹幕当前版本被禁用）。垫在视频之上、手势层之下。
            if controller.usesOverlayDanmakuRenderer {
                DanmakuOverlayHost(controller: controller.danmakuOverlay)
            }
            playerGestureLayer

            if controller.state.isBuffering && controller.state.state == .playing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if controller.state.state == .error || controller.setupError != nil {
                PlayerPlaybackErrorBadge()
            }

            // 两阶段显隐：`isMounted` 控制 `if` 卸载（隐藏时动画跑完才真正卸载，
            // 卸载期间 HUD 不再随播放 tick 重排）；`isVisible` 控制 `.opacity`
            // 驱动淡入淡出——macOS 上 `.transition` 的 removal 不被动画化，
            // 所以淡出必须用 `.opacity` 属性动画（协调器 setVisible 里两拍错开）。
            if hudVisibility.isMounted {
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
                    onUserInteraction: revealControls
                )
                .opacity(hudVisibility.isVisible ? 1 : 0)
                .allowsHitTesting(hudVisibility.isVisible)
                .accessibilityHidden(!hudVisibility.isVisible)
            }

            if showStats {
                PlayerHUDStatsPanel()
            }
            if showInfoCard {
                PlayerHUDInfoPanel(title: mainTitle, kicker: titleKicker, isNarrow: isNarrow)
            }
            // 浮动跳过片头/片尾按钮:放在 ZStack 最上方(HUD 之上),提高位置避免被底栏遮挡。
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    PlayerSkipPromptView()
                        .padding(.trailing, isNarrow ? 16 : 28)
                        .padding(.bottom, isNarrow ? 150 : 168)
                }
            }
            .allowsHitTesting(true)

            // 长按右键 2x 提示徽章：独立于 HUD 显隐（加速不唤醒 HUD），浮在顶部中央。
            VStack(spacing: 0) {
                PlayerHoldFastForwardBadge()
                    .padding(.top, holdBadgeTopPadding)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            #if os(iOS)
            // 滑动手势的独立反馈层：进度条 / OSD 单独显示，不唤醒整套 HUD。
            if let session = panSession, session.mode == .seek {
                PlayerSeekPreviewBar(
                    fraction: PlayerPanGestureModel.fraction(
                        seconds: session.previewSeconds,
                        duration: session.durationSeconds
                    ),
                    targetSeconds: session.previewSeconds,
                    durationSeconds: session.durationSeconds
                )
            }
            if let session = panSession, session.mode != .seek {
                VStack(spacing: 0) {
                    PlayerAdjustOSDBadge(
                        systemImage: session.mode == .brightness
                            ? "sun.max.fill" : "speaker.wave.2.fill",
                        value: session.verticalValue
                    )
                    .padding(.top, 14)
                    Spacer(minLength: 0)
                }
            }
            #endif

            PlayerScreenshotToast(message: screenshotToast)
        }
        // HUD 显隐动画：`.animation(value:)` 挂在容器上，`.opacity` 属性动画
        // 两个方向都渐变（macOS 上 transition removal 不生效，见上方注释）。
        .motionAnimation(.easeInOut(duration: 0.2), value: hudVisibility.isVisible, reduceMotion: reduceMotion)
        // opening→ready/playing 时让 loading 层、缓冲圈、错误徽章的显隐柔和过渡。
        .motionAnimation(.easeInOut(duration: 0.2), value: controller.state.state, reduceMotion: reduceMotion)
        #if os(iOS)
        // 滑动手势预览层（seek 进度条 / OSD）的出现消失过渡：跟着手势模式走。
        .motionAnimation(.easeInOut(duration: 0.15), value: panSession?.mode, reduceMotion: reduceMotion)
        #endif
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
            let suggestion = danmakuModel.danmaku.searchSuggestion(for: request?.id)
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
                // 播放器视图铺满窗口，移出视图 = 移出窗口：收起 HUD。
                // 不置 userHidden，鼠标移回来仍能唤出。
                hudVisibility.pointerExited()
                hudVisibility.hideOnPointerExit()
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
        // 长按 2x 期间切走 App：keyUp 会丢，主动收尾恢复原速（幂等）。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            controller.endHoldFastForward()
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
        // 协调器没有 Environment，减弱动态效果由这里解析后灌给它。
        .onChange(of: reduceMotion, initial: true) {
            hudVisibility.motionAnimation = reduceMotion ? nil : .easeInOut(duration: 0.2)
            // 卸载延时跟随动画：无动画（reduceMotion）时立即卸载。
            hudVisibility.unmountDelay = reduceMotion ? .zero : .milliseconds(200)
        }
        .onChange(of: controller.state.state, initial: true) { _, newState in
            PlaybackLog.append("PlayerState -> \(newState)")
            // 只有真在出画面时才压着不让息屏；暂停 / 出错立刻放手。
            // 同一处顺带把系统「正在播放」的播放/暂停状态对齐。
            controller.syncSystemPlaybackState()
        }
        // 系统「正在播放」的进度：跟着**整秒**才变的 displayPosition 走，约 1 Hz，
        // 顺带覆盖 seek / 变速这些不改 state 的路径。
        .onChange(of: controller.state.timeline.displayPosition) {
            controller.syncSystemPlaybackState()
        }
        // 标题要等 AppModel 的 nowPlayingItem 到位才拼得出来，所以单独跟一次。
        .onChange(of: NowPlayingTitle(title: mainTitle, kicker: titleKicker), initial: true) {
            _, titles in
            controller.updateNowPlayingMetadata(title: titles.title, subtitle: titles.kicker)
        }
        // 暂停、缓冲、错误、菜单面板和辅助功能统一走同一条显隐资格规则，
        // 避免新增一个阻止自动隐藏的状态时漏掉对应监听。
        .onChange(of: canAutoHideControls, initial: true) {
            revealControls()
        }
        .onDisappear {
            hudVisibility.cancel()
            // 覆盖层没了就一定看不见画面：无条件还掉息屏令牌和系统登记。
            // （取消准备 / 注销这两条路只清 presentedPlayer，不停引擎，
            // 所以这里不能"按当前状态推导"，见 releaseSystemPlaybackState 注释。）
            controller.releaseSystemPlaybackState()
            // 长按 2x 的兜底收尾（幂等）：iOS 手势被系统打断收不到抬起、
            // macOS keyUp 丢失时也走这里。正常路径触摸状态机 / keyUp 已先收。
            controller.endHoldFastForward()
            #if os(iOS)
            holdTask?.cancel()
            singleTapTask?.cancel()
            touchStart = nil
            lastTapDate = nil
            #endif
        }
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
            // iOS 画面手势（单击 HUD / 双击暂停 / 长按 2x / 滑动 seek·亮度·音量）
            // 由**一个** minimumDistance = 0 的 DragGesture 统一计时判定。
            // SwiftUI 的 tap / longPress 独立仲裁和滑动手势叠在一起抢不出稳定
            // 优先级（实测双击会被吞），自己分类是确定性的，行为同 bilibili。
            .gesture(playerTouchGesture)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { panAreaSize = $0 }
            // 切后台 / 来电中断：被打断的触摸不会再有 onEnded，在场景切换时收尾，
            // 避免回前台后 hold 任务到点触发 2x、或滑动会话从旧起点继续。
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                interruptTouchSession()
            }
            #endif
    }

    // MARK: - iOS 画面触摸状态机（单击 / 双击 / 长按 2x / 滑动）

    #if os(iOS)
    private var playerTouchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { handleTouchChanged($0) }
            .onEnded { handleTouchEnded($0) }
    }

    private func handleTouchChanged(_ value: DragGesture.Value) {
        if let existing = touchStart {
            // 极少见：上次触摸被系统手势打断没收尾（onEnded 没来）。
            // 不在 2x / 滑动中且明显超时，就当新触摸重新开始。
            let stale = Date().timeIntervalSince(existing.date) > 2
                && !controller.isHoldFastForwarding && panSession == nil
            if !stale {
                touchTranslation = value.translation
                classifyPanIfNeeded(at: value)
                return
            }
            touchStart = nil
        }
        touchStart = TouchStart(date: Date(), location: value.startLocation)
        touchTranslation = value.translation
        scheduleHoldDetection()
    }

    /// 长按判定：到点时手指仍在屏上、没滑走、不在别的手势里，进临时 2 倍速。
    private func scheduleHoldDetection() {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: TouchLimits.holdDuration)
            guard !Task.isCancelled else { return }
            guard touchStart != nil,
                  abs(touchTranslation.width) < TouchLimits.movementSlop,
                  abs(touchTranslation.height) < TouchLimits.movementSlop,
                  panSession == nil,
                  !controller.isHoldFastForwarding
            else { return }
            controller.beginHoldFastForward()
        }
    }

    /// 滑动分类（横滑 seek / 左右半屏亮度音量）。长按 2x 已就位时忽略：互斥，2x 优先。
    private func classifyPanIfNeeded(at value: DragGesture.Value) {
        guard !controller.isHoldFastForwarding else { return }
        let translation = value.translation
        guard abs(translation.width) >= TouchLimits.panThreshold
            || abs(translation.height) >= TouchLimits.panThreshold
        else { return }
        if panSession != nil {
            updatePan(translation: translation)
            return
        }
        guard panAreaSize.width > 1, panAreaSize.height > 1 else { return }
        guard let mode = PlayerPanGestureModel.mode(
            translation: translation,
            startX: value.startLocation.x,
            width: panAreaSize.width
        ) else { return }
        var session = PlayerPanSession(
            mode: mode,
            startSeconds: durationSeconds(controller.state.position),
            durationSeconds: durationSeconds(controller.state.duration)
        )
        switch mode {
        case .seek:
            // 没拿到时长无处可 seek，这次拖动不建会话。
            guard session.durationSeconds > 0 else { return }
            session.previewSeconds = session.startSeconds
        case .brightness:
            session.verticalStart = currentScreenBrightness()
            session.verticalValue = session.verticalStart
        case .volume:
            session.verticalStart = controller.volume
            session.verticalValue = controller.volume
        }
        panSession = session
        updatePan(translation: translation)
    }

    private func updatePan(translation: CGSize) {
        guard var session = panSession else { return }
        switch session.mode {
        case .seek:
            session.previewSeconds = PlayerPanGestureModel.seekTarget(
                startSeconds: session.startSeconds,
                translation: translation.width,
                width: panAreaSize.width,
                duration: session.durationSeconds
            )
        case .brightness:
            let value = PlayerPanGestureModel.verticalTarget(
                start: session.verticalStart,
                translation: translation.height,
                extent: panAreaSize.height
            )
            session.verticalValue = value
            keyWindowSceneScreen?.brightness = CGFloat(value)
        case .volume:
            let value = PlayerPanGestureModel.verticalTarget(
                start: session.verticalStart,
                translation: translation.height,
                extent: panAreaSize.height
            )
            session.verticalValue = value
            controller.applyVolume(value)
        }
        panSession = session
    }

    /// 系统打断（切后台 / 来电）时的触摸收尾。与 handleTouchEnded 的差异：
    /// seek 不落盘——被打断的拖动不该当成用户确认过的跳转。
    private func interruptTouchSession() {
        holdTask?.cancel()
        holdTask = nil
        singleTapTask?.cancel()
        singleTapTask = nil
        lastTapDate = nil
        touchStart = nil
        touchTranslation = .zero
        panSession = nil
        if controller.isHoldFastForwarding {
            controller.endHoldFastForward()
        }
    }

    private func handleTouchEnded(_ value: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        let start = touchStart
        touchStart = nil
        touchTranslation = .zero

        // 长按 2x 中抬指：收尾恢复原速（与 macOS 右箭头共用 controller 状态机）。
        if controller.isHoldFastForwarding {
            controller.endHoldFastForward()
            return
        }
        // 滑动中抬指：seek 落盘（拖动中只出预览，松手才跳）；亮度音量已实时生效。
        if let session = panSession {
            panSession = nil
            commitPan(session)
            return
        }
        // 轻点判定：时间短、位移小。
        guard let start,
              PlayerPanGestureModel.isQuickTap(
                elapsed: Date().timeIntervalSince(start.date),
                translation: value.translation,
                slop: TouchLimits.movementSlop,
                maxDuration: TouchLimits.tapMaxDuration
              )
        else { return }
        handleTap()
    }

    /// 单击 / 双击分流：第二击落到窗口内立即切播放暂停；单击延迟到窗口过期才切 HUD。
    private func handleTap() {
        let now = Date()
        if let last = lastTapDate,
           PlayerPanGestureModel.isDoubleTap(
            interval: now.timeIntervalSince(last),
            window: TouchLimits.doubleTapInterval
           ) {
            singleTapTask?.cancel()
            singleTapTask = nil
            lastTapDate = nil
            controller.togglePlayPause()
            return
        }
        lastTapDate = now
        singleTapTask?.cancel()
        singleTapTask = Task { @MainActor in
            try? await Task.sleep(for: TouchLimits.singleTapDelay)
            guard !Task.isCancelled else { return }
            lastTapDate = nil
            toggleControls()
        }
    }

    private func commitPan(_ session: PlayerPanSession) {
        switch session.mode {
        case .seek:
            controller.seek(toFraction: PlayerPanGestureModel.fraction(
                seconds: session.previewSeconds,
                duration: session.durationSeconds
            ))
        case .brightness, .volume:
            break  // 已实时生效
        }
    }

    private var keyWindowSceneScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    private func currentScreenBrightness() -> Double {
        Double(keyWindowSceneScreen?.brightness ?? 0.5)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.microseconds) / 1_000_000
    }
    #endif

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
        // PlayerWindowFitter 只有 App/macOS 一份，iOS 没有窗口可还原。
        #if os(macOS)
        PlayerWindowFitter.restore()
        #endif
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

    /// 2x 徽章的顶部间距：窗口模式避开系统标题栏拖动区（与 HUD 顶栏同一挡位），全屏贴顶。
    private var holdBadgeTopPadding: CGFloat {
        #if os(macOS)
        if !hudIsFullscreen { return 58 }
        #endif
        return isNarrow ? 14 : 22
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
    /// 同时监听 keyUp：右箭头的「长按 2x / 轻点快进」要靠 keyUp 与 autorepeat 分辨。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
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
        // 只让位给**文本输入**环境（如系统保存面板的文件名框）：那里空格 / 方向键是编辑键。
        // 不再让给 NSSlider 等控件——HUD 的进度 / 音量滑杆被点过之后会一直占着
        // firstResponder，空格和方向键会被它吃掉，表现就是「按键绑定偶尔失效」
        // （点一下别处才恢复）。视频播放器里这些键永远属于播放控制（IINA/QuickTime 行为）。
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView {
            return false
        }

        // 右箭头特殊：长按 = 临时 2 倍速（松手恢复原速），轻点 = 快进 10 秒。
        // 首按不动作——是轻点还是长按，要等 autorepeat（长按）或 keyUp（轻点）才能分辨。
        if event.keyCode == 124 {
            switch event.type {
            case .keyDown:
                if event.isARepeat {
                    controller.beginHoldFastForward()
                    // 加速期间不唤醒 HUD：提示由独立的 2x 徽章承担，HUD 保持原显隐。
                }
                return true
            case .keyUp:
                if controller.isHoldFastForwarding {
                    controller.endHoldFastForward()
                    // 长按收尾同样不唤醒 HUD；轻点快进才走 reveal（与左箭头一致）。
                    return true
                }
                controller.skip(by: 10)
                revealControls()
                return true
            default:
                return false
            }
        }

        // 通用键只响应首按：按住会触发 autorepeat keyDown，空格/回车/静音/全屏这些
        // 开关类动作会被重复触发造成快速闪断（右箭头在上一段已单独处理长按 2x）。
        if event.isARepeat { return true }

        guard event.type == .keyDown else { return false }
        switch PlayerKeyAction.action(keyCode: event.keyCode) {
        case .togglePlayPause:
            controller.togglePlayPause(); revealControls(); return true
        case .closePlayer:
            closePlayer(); return true
        case .seekBackward:
            controller.skip(by: -10); revealControls(); return true
        case .seekForward:
            controller.skip(by: 10); revealControls(); return true
        case .volumeDown:
            controller.adjustVolume(by: -0.1); revealControls(); return true
        case .volumeUp:
            controller.adjustVolume(by: 0.1); revealControls(); return true
        case .toggleMute:
            controller.toggleMute(); revealControls(); return true
        case .toggleFullscreen:
            toggleFullscreen(); return true
        case nil:
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

/// `onChange` 只接一个 Equatable，标题和小字要一起比就得包一层。
private struct NowPlayingTitle: Equatable {
    var title: String
    var kicker: String
}

#if os(macOS)
/// 使用 AppKit 原生 NSTrackingArea 跟踪窗口鼠标移动与移出。
/// 彻底解决 macOS 上 SwiftUI `.onContinuousHover` 鼠标移出窗口不触发 `.ended` 的问题。
private struct PlayerMouseTrackingView: NSViewRepresentable {
    let onMoved: (CGPoint) -> Void
    let onExited: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onMoved = onMoved
        view.onExited = onExited
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onMoved = onMoved
        nsView.onExited = onExited
    }

    final class TrackingNSView: NSView {
        var onMoved: ((CGPoint) -> Void)?
        var onExited: (() -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 不拦截任何点击事件，完全透明传递给底层手势与上层控件
            return nil
        }

        override func mouseMoved(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            onMoved?(location)
        }

        override func mouseEntered(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            onMoved?(location)
        }

        override func mouseExited(with event: NSEvent) {
            onExited?()
        }
    }
}
#endif

