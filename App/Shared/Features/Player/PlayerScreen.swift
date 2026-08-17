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
    /// 所有 HUD 共用一个不受视频画面影响的深灰承载层。Liquid Glass 只负责
    /// 高光、边缘和交互，避免顶部、中央、底部因各自取样不同而变色。
    private var hudSurfaceBase: Color { Color(red: 0.105, green: 0.11, blue: 0.12) }
    private var hudGlassTint: Color { .black.opacity(0.12) }

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
            hudGlassSurface(in: RoundedRectangle(cornerRadius: 18), interactive: true) {
                HStack(spacing: 14) {
                    Label(controller.state.lastError ?? controller.setupError ?? "播放出错",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.white, .red)
                    hudProminentButton(tint: .red, action: controller.retryLast) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 4)
                    }
                    .disabled(controller.lastRequest == nil)
                }
                .padding(12)
            }
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
        // Liquid Glass 没有可选的 dark 材质；深色 scheme 统一原生控件外观，
        // 前景则明确使用白色，避免 vibrancy 在黑色 Glass 上把图标反转成黑色。
        .environment(\.colorScheme, .dark)
    }

    /// 顶栏只保留窗口级操作：关闭在左，音量 / 全屏 / 更多在右。
    /// 截图、分享和诊断信息属于低频动作，统一收进“更多”。
    private var topBar: some View {
        hudGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                circleButton("xmark", tip: "关闭播放器") { closePlayer() }
                Spacer(minLength: 8)
                volumeCapsule
                capsuleGroup {
                    #if os(macOS)
                    hudIconButton(isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tip: "全屏（F / 双击）") { toggleFullscreen() }
                    #endif
                    auxiliaryMenu
                }
            }
        }
        .padding(.horizontal, isNarrow ? 14 : 24)
        .padding(.top, isNarrow ? 12 : 20)
    }

    /// 右上音量胶囊：原生 Slider 会随系统自动采用对应的 Liquid Glass 控件外观。
    private var volumeCapsule: some View {
        hudGlassSurface(in: Capsule(), interactive: true) {
            HStack(spacing: 8) {
                Slider(value: volumeBinding, in: 0...1) {
                    Text("音量")
                }
                .labelsHidden()
                .tint(.white)
                .controlSize(.small)
                .frame(width: isNarrow ? 84 : 120)
                Button { controller.toggleMute() } label: {
                    Image(systemName: volumeIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(controller.muted ? .red : .white)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("静音（M）")
                .accessibilityLabel(controller.muted ? "取消静音" : "静音")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { controller.volume },
            set: { controller.applyVolume($0) }
        )
    }

    private var volumeIconName: String {
        if controller.muted || controller.volume == 0 { return "speaker.slash.fill" }
        return "speaker.wave.2.fill"
    }

    /// 中央：回退 10s / 播放暂停 / 快进 10s。
    private var centerControls: some View {
        hudGlassContainer(spacing: isNarrow ? 26 : 44) {
            HStack(spacing: isNarrow ? 26 : 44) {
                centerCircle("gobackward.10", tip: "后退 10 秒", size: isNarrow ? 48 : 58) {
                    controller.skip(by: -10)
                }
                playPauseButton
                centerCircle("goforward.10", tip: "前进 10 秒", size: isNarrow ? 48 : 58) {
                    controller.skip(by: 10)
                }
            }
        }
    }

    private func centerCircle(_ systemImage: String, tip: String, size: CGFloat,
                              action: @escaping () -> Void) -> some View {
        hudGlassCircleButton(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
        .contentShape(Circle())
        .help(tip)
        .accessibilityLabel(tip)
    }

    private var playPauseButton: some View {
        hudGlassCircleButton(action: { controller.togglePlayPause() }) {
            Image(systemName: controller.state.state == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: (isNarrow ? 64 : 76) * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: isNarrow ? 64 : 76, height: isNarrow ? 64 : 76)
        }
        .contentShape(Circle())
        .help(controller.state.state == .playing ? "暂停" : "播放")
        .accessibilityLabel(controller.state.state == .playing ? "暂停" : "播放")
    }

    /// 底部标题、进度和辅助操作共享一块玻璃。标题不直接压在视频上，
    /// 避免亮色画面让剧集名和系列名失去对比度。
    private var bottomBlock: some View {
        hudGlassSurface(in: RoundedRectangle(cornerRadius: isNarrow ? 16 : 20), interactive: true) {
            VStack(alignment: .leading, spacing: isNarrow ? 9 : 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if !titleKicker.isEmpty {
                        Text(titleKicker)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                    Text(mainTitle)
                        .font((isNarrow ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .layoutPriority(-1)

                VStack(spacing: isNarrow ? 6 : 8) {
                    progressSlider

                    HStack(spacing: isNarrow ? 2 : 6) {
                        Text(timeLabel(displayedPosition))
                        Text("/")
                            .foregroundStyle(.white.opacity(0.4))
                        Text(timeLabel(controller.state.duration))

                        Spacer(minLength: 8)

                        subtitleMenu
                        audioMenu
                        rateMenu
                        if app.nextEpisode != nil {
                            dockIconButton("forward.end.fill", tip: "播放下一集") {
                                app.playNextEpisode()
                            }
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                }
            }
            .padding(.horizontal, isNarrow ? 12 : 16)
            .padding(.vertical, isNarrow ? 11 : 14)
        }
        .padding(.horizontal, isNarrow ? 14 : 24)
        .padding(.bottom, isNarrow ? 16 : 26)
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
    }

    private func dockIconButton(
        _ systemImage: String,
        tip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 32, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip)
    }

    private var progressSlider: some View {
        Slider(value: progressBinding, in: 0...1) {
            Text("播放进度")
        } onEditingChanged: { editing in
            if editing {
                hideTask?.cancel()
            } else if let target = scrubFraction {
                controller.seek(toFraction: target)
                scrubFraction = nil
                scheduleAutoHide()
            }
        }
        .labelsHidden()
        .tint(.white)
        .controlSize(isNarrow ? .small : .regular)
        .disabled(controller.state.duration == .zero)
        .accessibilityValue("\(timeLabel(displayedPosition)) / \(timeLabel(controller.state.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skip(by: 10)
            case .decrement: controller.skip(by: -10)
            @unknown default: break
            }
        }
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { scrubFraction ?? controller.state.progress },
            set: { value in
                hideTask?.cancel()
                scrubFraction = min(max(value, 0), 1)
            }
        )
    }

    private func hudProminentButton<Label: View>(
        tint: Color,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Group {
            if #available(macOS 26.0, iOS 26.0, *) {
                Button(action: action) { label() }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { label() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .tint(tint)
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
        hudGlassSurface(in: Capsule(), interactive: true) {
            HStack(spacing: 2) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }

    private func hudIconButton(_ systemImage: String, tip: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip)
    }

    private var auxiliaryMenu: some View {
        Menu {
            Button {
                showInfoCard.toggle()
            } label: {
                Label(showInfoCard ? "隐藏播放信息" : "显示播放信息",
                      systemImage: showInfoCard ? "info.circle.fill" : "info.circle")
            }
            Button {
                showStats.toggle()
            } label: {
                Label(showStats ? "隐藏播放统计" : "显示播放统计",
                      systemImage: showStats ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle")
            }

            Divider()

            #if os(macOS)
            Button(action: captureNow) {
                Label("截图", systemImage: "camera.fill")
            }
            if shareURL != nil {
                Button(action: shareNow) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
            #else
            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
            #endif
        } label: {
            hudMenuIcon("ellipsis")
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        // macOS Menu 的 button style 会覆盖 label 内部的 foregroundStyle。
        .tint(.white)
        .foregroundStyle(.white)
        .help("更多")
        .accessibilityLabel("更多播放选项")
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

    /// 自定义 HUD 容器使用统一深灰承载层 + 系统 Liquid Glass。
    /// 承载层负责颜色和对比，Glass 不再直接以视频画面作为可读性来源。
    @ViewBuilder
    private func hudGlassSurface<ShapeType: Shape, Content: View>(
        in shape: ShapeType,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content()
                .glassEffect(.regular.tint(hudGlassTint).interactive(interactive), in: shape)
                .background(hudSurfaceBase, in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            content()
                .background(.ultraThinMaterial, in: shape)
                .background(hudSurfaceBase, in: shape)
                .environment(\.colorScheme, .dark)
        }
    }

    /// 圆形按钮也通过 hudGlassSurface 渲染，不再使用另一套 GlassButtonStyle
    /// 调色逻辑。interactive Glass 仍然提供原生 hover / press 反馈。
    @ViewBuilder
    private func hudGlassCircleButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            hudGlassSurface(in: Circle(), interactive: true) {
                label()
            }
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
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
        return hudGlassSurface(in: RoundedRectangle(cornerRadius: 14)) {
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
