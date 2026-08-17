import ErikaKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
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

    /// 覆盖层出现时要打开的源；nil = 空画面（引擎失败等极端情况）。
    let request: PlaybackRequest?

    @State private var controlsVisible = true
    @State private var showStats = false
    @State private var showInfoCard = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubFraction: Double?
    @State private var isImportingSubtitle = false
    @State private var screenshotToast: String?
    #if os(macOS)
    @State private var isFullscreen = false
    /// 键盘监听器引用（安装后持有，退出播放器时移除）。用 NSEvent local monitor 而不是
    /// `.onKeyPress`：后者要求视图先拿到键盘焦点，覆盖层播放器根本抢不到焦点，按键会静默丢失。
    @State private var keyMonitor: Any?
    #endif
    /// 上一次 hover 的指针位置。播放中 body 每帧重算会让 onContinuousHover 虚假重触发，
    /// 只有**坐标变了**才算真鼠标移动（才该重置自动隐藏计时）。
    @State private var lastHoverLocation: CGPoint?
    /// 覆盖层当前宽度：竖屏视频 / iPhone 上切紧凑 HUD（收音量条、缩按钮缩间距）。
    @State private var availableWidth: CGFloat = .infinity

    private let controlAutoHide: Duration = .seconds(3)

    private var isNarrow: Bool { availableWidth < 560 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surface
            if controller.state.isBuffering && controller.state.state == .playing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if controller.state.state == .error || controller.setupError != nil {
                errorBadge
            }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
            if showStats {
                statsPanel
            }
            if showInfoCard {
                infoCard
            }
            toast
        }
        // 播放器永远按暗色渲染：覆盖 surface / placeholder / errorBadge / toast / infoCard / statsPanel 全部层级。
        // 早先只压在 controlsOverlay 上，导致 placeholder 的 .white.opacity 在浅色系统下读不出。
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { availableWidth = $0 }
        .fileImporter(isPresented: $isImportingSubtitle,
                      allowedContentTypes: Self.subtitleTypes) { result in
            if case .success(let url) = result {
                controller.loadExternalSubtitle(fileURL: url)
            }
        }
        #if os(macOS)
        .onContinuousHover { phase in
            // 播放中 body 每帧重算会让 onContinuousHover 虚假重触发：只有坐标变了才算
            // 真鼠标移动（才重置自动隐藏计时）。移出视图时清掉位置，回来才算新移动。
            switch phase {
            case .active(let location):
                guard location != lastHoverLocation else { return }
                lastHoverLocation = location
                revealControls()
            case .ended:
                lastHoverLocation = nil
            }
        }
        .onTapGesture(count: 2) { toggleFullscreen() }
        .onTapGesture { controller.togglePlayPause() }
        .onAppear { isFullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
        #else
        .onTapGesture(count: 2) { controller.togglePlayPause() }
        .onTapGesture { toggleControls() }
        #endif
        .onAppear {
            revealControls()
            PlaybackLog.append("PlayerScreen onAppear request=\(request?.title ?? "nil")")
            #if os(macOS)
            playerLog.info("PlayerScreen onAppear")
            PlayerWindowFitter.saveOriginalIfNeeded()
            installKeyMonitor()
            #endif
        }
        // task(id:)：覆盖层已开着时换片（onOpenURL / 播另一集）也能重新打开
        .task(id: request) {
            guard let request else { return }
            PlaybackLog.append("PlayerScreen task id=\(request.title)")
            controller.openIfNeeded(request)
            revealControls()
        }
        .onChange(of: controller.state.state) { _, newState in
            // 暂停 / 出错时控件常驻；回到播放重新计时隐藏
            PlaybackLog.append("PlayerState -> \(newState)")
            revealControls()
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

    // MARK: - 画面

    @ViewBuilder
    private var surface: some View {
        if let engine = controller.engine {
            // .id(engine)：引擎每次 open / 换片都重建，而 MetalHostView 用 let 固定持有引擎——
            // SwiftUI 复用旧视图时新引擎不会 attach（没有渲染循环 → 收不到状态事件），
            // UI 停在 idle、再点播放就报 "invalid state transition"。用 ObjectIdentifier
            // 让承载视图跟随引擎身份重建（旧视图 dismantle 会 detach 旧引擎）。
            VideoSurfaceView(engine: engine)
                .id(ObjectIdentifier(engine))
                .ignoresSafeArea()
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text(request?.title ?? "没有正在播放的内容")
                .foregroundStyle(.white.opacity(0.7))
            if let error = controller.setupError {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(30)
    }

    private var errorBadge: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Label(controller.state.lastError ?? controller.setupError ?? "播放出错",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                Button {
                    controller.retryLast()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(controller.lastRequest == nil)
            }
            .padding(12)
            .background(.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 140)
        }
    }

    /// 截图成功的轻提示。
    private var toast: some View {
        VStack {
            Spacer()
            if let message = screenshotToast {
                hudGlassSurface(in: Capsule()) {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 120)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 悬浮控件（Apple TV 式胶囊 HUD）

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            centerControls
            Spacer(minLength: 12)
            bottomBlock
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    /// 顶栏：左「×」+ 功能胶囊（全屏 / 截图 / 分享）；右音量胶囊。
    private var topBar: some View {
        hudGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                circleButton("xmark", tip: "关闭播放器") { closePlayer() }

                capsuleGroup {
                    #if os(macOS)
                    hudIconButton(isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tip: "全屏（F / 双击）") { toggleFullscreen() }
                    hudIconButton("camera.fill", tip: "截图") { captureNow() }
                    if shareURL != nil {
                        hudIconButton("square.and.arrow.up", tip: "分享") { shareNow() }
                    }
                    #else
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                }

                Spacer(minLength: 8)

                volumeCapsule
            }
        }
        .padding(.horizontal, isNarrow ? 14 : 24)
        .padding(.top, isNarrow ? 12 : 20)
    }

    /// 右上音量胶囊：细音量条（无圆钮，同 Apple TV）+ 静音键。
    private var volumeCapsule: some View {
        hudGlassSurface(in: Capsule(), interactive: true) {
            HStack(spacing: 10) {
                volumeBar
                    .frame(width: isNarrow ? 84 : 120)
                Button { controller.toggleMute() } label: {
                    Image(systemName: volumeIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(controller.muted ? .red : .white)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("静音（M）")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private var volumeBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.32))
                Capsule().fill(.white)
                    .frame(width: max(proxy.size.width * controller.volume, 4))
            }
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        controller.applyVolume(min(max(value.location.x / proxy.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue(controller.muted ? "已静音" : "\(Int((controller.volume * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.adjustVolume(by: 0.05)
            case .decrement: controller.adjustVolume(by: -0.05)
            @unknown default: break
            }
        }
    }

    private var volumeIconName: String {
        if controller.muted || controller.volume == 0 { return "speaker.slash.fill" }
        return "speaker.wave.2.fill"
    }

    /// 中央：回退 10s / 播放暂停 / 快进 10s。
    private var centerControls: some View {
        hudGlassContainer(spacing: isNarrow ? 26 : 44) {
            HStack(spacing: isNarrow ? 26 : 44) {
                centerCircle("gobackward.10", size: isNarrow ? 48 : 58) { controller.skip(by: -10) }
                playPauseButton
                centerCircle("goforward.10", size: isNarrow ? 48 : 58) { controller.skip(by: 10) }
            }
        }
    }

    private func centerCircle(_ systemImage: String, size: CGFloat,
                              action: @escaping () -> Void) -> some View {
        hudGlassCircleButton(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
        .contentShape(Circle())
    }

    private var playPauseButton: some View {
        hudGlassCircleButton(action: { controller.togglePlayPause() }) {
            Image(systemName: controller.state.state == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: (isNarrow ? 64 : 76) * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: isNarrow ? 64 : 76, height: isNarrow ? 64 : 76)
        }
        .contentShape(Circle())
    }

    /// 底部：标题 + 设置胶囊（字幕 / 音轨 / 倍速）→ 全宽进度条 → Info / InSight / Continue Watching。
    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: isNarrow ? 12 : 16) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if !titleKicker.isEmpty {
                        Text(titleKicker)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    Text(mainTitle)
                        .font((isNarrow ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .layoutPriority(-1)

                Spacer(minLength: 8)

                capsuleGroup {
                    subtitleMenu
                    audioMenu
                    rateMenu
                }
            }

            progressBar

            hudGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    hudChip("Info", active: showInfoCard) { showInfoCard.toggle() }
                    hudChip("InSight", active: showStats) { showStats.toggle() }
                    if app.nextEpisode != nil {
                        hudChip("Continue Watching", active: false) { app.playNextEpisode() }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, isNarrow ? 14 : 24)
        .padding(.bottom, isNarrow ? 16 : 26)
    }

    /// 小字行：剧集名（大图配系列名，同 Apple TV 版式）；非剧集留空。
    private var titleKicker: String {
        guard let item = app.nowPlayingItem, item.episodeLabel != nil else { return "" }
        return item.name
    }

    /// 主标题：剧集 → 系列名；其余 → 条目名；兜底播放请求标题。
    private var mainTitle: String {
        if let item = app.nowPlayingItem {
            if item.episodeLabel != nil { return item.seriesName ?? item.name }
            return item.name
        }
        return controller.currentTitle ?? request?.title ?? ""
    }

    // MARK: - 胶囊零件

    /// 一组图标共享一块原生玻璃，避免在玻璃上再叠一层玻璃。
    private func capsuleGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        hudGlassSurface(in: Capsule()) {
            HStack(spacing: 2) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }

    private func hudIconButton(_ systemImage: String, tip: String, active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? .yellow : .white)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    /// 底部文字胶囊（Info / InSight / Continue Watching）。
    private func hudChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        hudGlassCapsuleButton(active: active, action: action) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    /// macOS / iOS 26 由系统合成相邻玻璃，旧系统只负责布局，不模拟融合动画。
    @ViewBuilder
    private func hudGlassContainer<Content: View>(
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }

    /// 自定义 HUD 容器使用系统 Liquid Glass；Material 仅作为旧系统兼容回退。
    ///
    /// 系统 `Glass.regular` 在亮场景底色是亮色磨砂玻璃（HUD 上覆在视频画面之上会把
    /// 整片内容洗白，白字看不清）。强制加一层深色 tint，把玻璃底压回暗调，文字始终可读。
    @ViewBuilder
    private func hudGlassSurface<ShapeType: Shape, Content: View>(
        in shape: ShapeType,
        interactive: Bool = false,
        fallbackShade: Double = 0.55,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content()
                .glassEffect(.regular.tint(.black.opacity(0.55)).interactive(interactive), in: shape)
        } else {
            // 旧系统回退：`.ultraThinMaterial` 在黑视频上也是亮色雾，必须叠一层
            // 够深的黑色把玻璃调暗；早先用 0.25 太浅，整片 HUD 会发白。
            content()
                .background(.ultraThinMaterial, in: shape)
                .background(.black.opacity(fallbackShade), in: shape)
        }
    }

    /// 独立圆形按钮直接采用系统 glass button style，获得原生 hover / press 反馈。
    ///
    /// 同 hudGlassSurface：`.glass` 默认偏亮，覆在黑视频上会把按钮洗成白色圆片，必须
    /// 再用 `.tint(.black.opacity(0.55))` 把底色压回暗调，确保中间图标保持白底深玻璃对比。
    @ViewBuilder
    private func hudGlassCircleButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            Button(action: action) {
                label()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.black.opacity(0.55))
        } else {
            Button(action: action) {
                label()
                    .background(.ultraThinMaterial, in: Circle())
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 选中态使用系统的 prominent glass，而不是再盖一层半透明白色形状。
    ///
    /// 关键：dark HUD 上选中态必须仍然是"暗玻璃更暗"，不是"亮玻璃"。
    /// `.glassProminent` 默认 tint 偏亮，直接用会把 Info / Continue Watching
    /// 选中时整块糊白；显式钉 `.black.opacity(0.78)` 让选中态在黑视频上呈现为
    /// "略亮一点的暗胶囊"，与未选中态有清晰对比且仍保留 dark HUD 整体调性。
    @ViewBuilder
    private func hudGlassCapsuleButton<Label: View>(
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            if active {
                Button(action: action) {
                    label()
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.black.opacity(0.78))
            } else {
                Button(action: action) {
                    label()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(.black.opacity(0.55))
            }
        } else {
            Button(action: action) {
                label()
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(.black.opacity(active ? 0.7 : 0.55), in: Capsule())
                    .overlay(Capsule().fill(.white.opacity(active ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 轨道菜单（M2：音轨 / 字幕切换 + 外挂字幕）

    private var audioMenu: some View {
        Menu {
            ForEach(controller.state.audioTracks) { track in
                Button {
                    controller.selectAudio(track)
                } label: {
                    if track.selected {
                        Label(track.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(track.displayTitle)
                    }
                }
            }
        } label: {
            hudMenuIcon("speaker.wave.2")
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .disabled(controller.state.audioTracks.isEmpty)
        .help("音轨")
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                controller.setSubtitle(nil)
            } label: {
                if !isSubtitleOn {
                    Label("关闭", systemImage: "checkmark")
                } else {
                    Text("关闭")
                }
            }
            .disabled(controller.state.subtitleTracks.isEmpty && !isSubtitleOn)

            ForEach(controller.state.subtitleTracks) { track in
                let label = track.source == .external ? "\(track.displayTitle)（外挂）" : track.displayTitle
                Button {
                    controller.setSubtitle(track)
                } label: {
                    if track.selected {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }

            Divider()
            Button {
                isImportingSubtitle = true
            } label: {
                Label("打开外挂字幕…", systemImage: "doc.badge.plus")
            }

            Divider()
            Button { controller.adjustSubtitleScale(by: 0.1) } label: {
                Label("字幕加大", systemImage: "textformat.size.larger")
            }
            Button { controller.adjustSubtitleScale(by: -0.1) } label: {
                Label("字幕减小", systemImage: "textformat.size.smaller")
            }
            Button { controller.resetSubtitleScale() } label: {
                Label("字幕默认大小", systemImage: "arrow.counterclockwise")
            }
        } label: {
            hudMenuIcon("captions.bubble", active: isSubtitleOn)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .help("字幕")
    }

    private var isSubtitleOn: Bool {
        controller.state.subtitleTracks.contains { $0.selected }
    }

    private func hudMenuIcon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? .yellow : .white)
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
    }

    private static var subtitleTypes: [UTType] {
        [("srt", false), ("ass", false), ("ssa", false), ("vtt", false)]
            .compactMap { UTType(filenameExtension: $0.0, conformingTo: .text) }
    }

    /// 全宽进度条：细轨道 + 白色已播段（Apple TV 式无圆钮）；拖动时出小圆点 + 目标时间预览。
    private var progressBar: some View {
        GeometryReader { proxy in
            let fraction = scrubFraction ?? controller.state.progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.32))
                Capsule()
                    .fill(.white)
                    .frame(width: max(proxy.size.width * fraction, 5))
                if scrubFraction != nil {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: proxy.size.width * fraction - 6)
                }
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        // 拖动期间不隐藏
                        hideTask?.cancel()
                        scrubFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                    }
                    .onEnded { value in
                        guard proxy.size.width > 0 else { return }
                        let target = min(max(value.location.x / proxy.size.width, 0), 1)
                        controller.seek(toFraction: target)
                        scrubFraction = nil
                        scheduleAutoHide()
                    }
            )
            .overlay(alignment: .topLeading) {
                if scrubFraction != nil {
                    Text("\(timeLabel(displayedPosition)) / \(timeLabel(controller.state.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(x: min(max(proxy.size.width * fraction - 40, 0),
                                       proxy.size.width - 90), y: -22)
                }
            }
        }
        .frame(height: 12)
        .disabled(controller.state.duration == .zero)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(timeLabel(displayedPosition)) / \(timeLabel(controller.state.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skip(by: 10)
            case .decrement: controller.skip(by: -10)
            @unknown default: break
            }
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button {
                    controller.applyRate(value)
                } label: {
                    if controller.rate == value {
                        Label(rateLabel(value), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(value))
                    }
                }
            }
        } label: {
            hudMenuIcon("gauge.with.dots.needle.67percent", active: controller.rate != 1.0)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .help("倍速")
    }

    /// 顶栏独立圆钮（关闭）：深色半透明圆，同胶囊一族。
    private func circleButton(_ systemImage: String, tip: String, action: @escaping () -> Void) -> some View {
        hudGlassCircleButton(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
        }
        .help(tip)
    }

    // MARK: - 统计（调试用，默认收起）

    /// Info 卡：当前播放的基本信息（标题 / 状态 / 进度 / 分辨率）。
    private var infoCard: some View {
        // 不显式传 fallbackShade，让 hudGlassSurface 默认值（0.55）生效，保持 HUD
        // 暗玻璃一致；显式 0.35 会让 Info 卡比周围胶囊更亮，与"统一暗 HUD"调性冲突。
        hudGlassSurface(in: RoundedRectangle(cornerRadius: 14)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mainTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                if !titleKicker.isEmpty {
                    Text(titleKicker)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text("\(stateLabel) · \(timeLabel(displayedPosition)) / \(timeLabel(controller.state.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                if let params = controller.state.videoParams {
                    Text("\(params.width)×\(params.height)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isNarrow ? 14 : 24)
        .padding(.top, isNarrow ? 64 : 76)
        .allowsHitTesting(false)
    }

    private var statsPanel: some View {
        let videoDescription = controller.state.videoParams.map {
            "\($0.width)×\($0.height)"
        } ?? "-"
        return hudGlassSurface(in: RoundedRectangle(cornerRadius: 10), fallbackShade: 0.65) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.statsLine())
                Text(verbatim: "surface=\(controller.state.hasSurface) · \(videoDescription)")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.9))
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 24)
        .padding(.top, 84)
        .allowsHitTesting(false)
    }

    // MARK: - 显隐控制

    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleAutoHide()
    }

    #if os(iOS)
    private func toggleControls() {
        if controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
            hideTask?.cancel()
        } else {
            revealControls()
        }
    }
    #endif

    /// 播放中 3 秒后收起；暂停 / 缓冲 / 出错 / 拖动进度时常驻。
    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard shouldAutoHide else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: controlAutoHide)
            guard !Task.isCancelled, shouldAutoHide else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private var shouldAutoHide: Bool {
        controller.state.state == .playing && scrubFraction == nil
    }

    private func closePlayer() {
        playerLog.info("closePlayer（ESC / ×）")
        PlaybackLog.append("closePlayer（ESC / ×）")
        hideTask?.cancel()
        controller.stopPlayback()
        app.dismissPlayer()
    }

    #if os(macOS)
    private func toggleFullscreen() {
        guard let window = NSApp.keyWindow else { return }
        window.toggleFullScreen(nil)
        isFullscreen.toggle()
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

    /// 拖动进度时，左侧时间显示将要跳到的位置。
    private var displayedPosition: Duration {
        guard let scrubFraction, controller.state.duration > .zero else {
            return controller.state.position
        }
        return .microseconds(Int64(Double(controller.state.duration.microseconds) * scrubFraction))
    }

    // MARK: - 文本

    private var stateLabel: String {
        switch controller.state.state {
        case .idle: "空闲"
        case .opening: "打开中"
        case .ready: "就绪"
        case .playing: "播放中"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case .closed: "已关闭"
        case .error: "错误"
        }
    }

    private func rateLabel(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    private func timeLabel(_ duration: Duration) -> String {
        duration.formatted(.time(pattern: duration > .seconds(3600) ? .hourMinuteSecond : .minuteSecond))
    }
}
