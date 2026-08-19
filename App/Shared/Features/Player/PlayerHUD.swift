import ErikaKit
import Foundation
import Observation
import SwiftUI

enum PlayerHUDInteraction: Hashable {
    case volumeDrag
    case timelineDrag
    case menuTracking
}

/// HUD 的显示计时不属于视图状态。鼠标坐标和 Task 都不参与 Observation，
/// 窗口移动时只重排视频，不会连带整套 Liquid Glass 反复失效。
@MainActor
@Observable
final class PlayerHUDVisibilityCoordinator {
    private(set) var isVisible = true

    @ObservationIgnored private var activeInteractions: Set<PlayerHUDInteraction> = []
    @ObservationIgnored private var trackedMenus: Set<ObjectIdentifier> = []
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hideDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var scheduledWake: ContinuousClock.Instant?
    @ObservationIgnored private var hideScheduleID = 0
    @ObservationIgnored private var lastPointerLocation: CGPoint?
    /// 用户主动点击关闭 HUD 后置 true：鼠标移动不再自动唤出，要再点一下才打开。
    /// 自动隐藏（计时到点）不置位，所以自动隐藏后滑动仍能唤出。
    @ObservationIgnored private var userHidden = false

    @ObservationIgnored private let clock = ContinuousClock()
    private let autoHideDelay: Duration

    init(autoHideDelay: Duration = .seconds(3)) {
        self.autoHideDelay = autoHideDelay
    }

    func reveal(canAutoHide: Bool) {
        // 任何主动显示都解除「用户关闭」锁定。
        userHidden = false
        if !isVisible { isVisible = true }
        scheduleHide(after: autoHideDelay, canAutoHide: canAutoHide)
    }

    func hide() {
        cancelScheduledHide()
        if isVisible { isVisible = false }
        // 用户主动关闭：标记锁定，鼠标移动不再自动唤出（要再点一下才打开）。
        userHidden = true
    }

    func setInteraction(
        _ interaction: PlayerHUDInteraction,
        active: Bool,
        canAutoHide: Bool
    ) {
        if active {
            activeInteractions.insert(interaction)
        } else {
            activeInteractions.remove(interaction)
        }
        reveal(canAutoHide: canAutoHide && activeInteractions.isEmpty)
    }

    /// 原生 Menu 没有公开 isPresented；打开菜单时给足停留时间，选中动作后会恢复正常计时。
    func holdForMenu(canAutoHide: Bool) {
        if !isVisible { isVisible = true }
        scheduleHide(after: .seconds(30), canAutoHide: canAutoHide)
    }

    func pointerMoved(to location: CGPoint, canAutoHide: Bool) {
        // 用户主动关闭期间，鼠标移动不唤出（要点击才重新打开）。
        guard !userHidden else { return }
        guard location != lastPointerLocation else { return }
        lastPointerLocation = location
        reveal(canAutoHide: canAutoHide && activeInteractions.isEmpty)
    }

    func pointerExited() {
        lastPointerLocation = nil
    }

    /// SwiftUI Menu 没有公开 isPresented；macOS 用 NSMenu tracking 通知补齐真实生命周期。
    /// 用集合而不是 Bool，嵌套的倍速子菜单结束时不会提前释放父菜单的暂停状态。
    func menuTrackingDidBegin(_ menu: AnyObject, canAutoHide: Bool) {
        trackedMenus.insert(ObjectIdentifier(menu))
        setInteraction(.menuTracking, active: true, canAutoHide: canAutoHide)
    }

    func menuTrackingDidEnd(_ menu: AnyObject, canAutoHide: Bool) {
        trackedMenus.remove(ObjectIdentifier(menu))
        guard trackedMenus.isEmpty else {
            reveal(canAutoHide: false)
            return
        }
        setInteraction(.menuTracking, active: false, canAutoHide: canAutoHide)
    }

    func cancel() {
        cancelScheduledHide()
        activeInteractions.removeAll()
        trackedMenus.removeAll()
        lastPointerLocation = nil
        userHidden = false
    }

    private func scheduleHide(after delay: Duration, canAutoHide: Bool) {
        guard canAutoHide, activeInteractions.isEmpty else {
            cancelScheduledHide()
            return
        }

        let deadline = clock.now.advanced(by: delay)
        hideDeadline = deadline

        // 鼠标连续移动通常只会把截止时间往后延。保留当前 sleeper，等它醒来后
        // 再睡到最新 deadline，避免每个像素都取消并创建一个新 Task。
        if let scheduledWake, hideTask != nil, deadline >= scheduledWake {
            return
        }

        startHideTask(wakingAt: deadline)
    }

    private func startHideTask(wakingAt firstWake: ContinuousClock.Instant) {
        hideScheduleID &+= 1
        let scheduleID = hideScheduleID
        hideTask?.cancel()
        scheduledWake = firstWake

        hideTask = Task { @MainActor [weak self] in
            var wake = firstWake
            while let self, !Task.isCancelled {
                do {
                    try await self.clock.sleep(until: wake)
                } catch {
                    break
                }
                guard scheduleID == self.hideScheduleID,
                      self.activeInteractions.isEmpty,
                      let latestDeadline = self.hideDeadline
                else {
                    break
                }

                if self.clock.now < latestDeadline {
                    wake = latestDeadline
                    self.scheduledWake = latestDeadline
                    continue
                }

                self.isVisible = false
                self.hideDeadline = nil
                self.scheduledWake = nil
                self.hideTask = nil
                return
            }

            guard let self, scheduleID == self.hideScheduleID else { return }
            self.hideTask = nil
            self.hideDeadline = nil
            self.scheduledWake = nil
        }
    }

    private func cancelScheduledHide() {
        guard hideTask != nil || hideDeadline != nil || scheduledWake != nil else { return }
        hideScheduleID &+= 1
        hideTask?.cancel()
        hideTask = nil
        hideDeadline = nil
        scheduledWake = nil
    }
}

/// Infuse 式 HUD：对比度由单一全屏暗幕保证，Glass 只用于少量工具分组。
struct PlayerHUDOverlay: View {
    let isNarrow: Bool
    let playbackID: String
    let title: String
    let kicker: String

    @Binding var isImportingSubtitle: Bool
    @Binding var isSelectingDanmaku: Bool
    @Binding var showStats: Bool
    @Binding var showInfoCard: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onClose: () -> Void
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void
    let onUserInteraction: () -> Void
    let onMenuPresented: () -> Void

    var body: some View {
        ZStack {
            PlayerHUDReadabilityScrim()

            VStack(spacing: 0) {
                PlayerHUDTopBar(
                    isNarrow: isNarrow,
                    isFullscreen: isFullscreen,
                    onClose: onClose,
                    onToggleFullscreen: onToggleFullscreen,
                    onInteractionChanged: onInteractionChanged,
                    onUserInteraction: onUserInteraction
                )
                Spacer(minLength: 0)
            }

            PlayerHUDTransportControls(isNarrow: isNarrow)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PlayerHUDBottomDock(
                    isNarrow: isNarrow,
                    playbackID: playbackID,
                    title: title,
                    kicker: kicker,
                    isImportingSubtitle: $isImportingSubtitle,
                    isSelectingDanmaku: $isSelectingDanmaku,
                    showStats: $showStats,
                    showInfoCard: $showInfoCard,
                    shareURL: shareURL,
                    isFullscreen: isFullscreen,
                    onToggleFullscreen: onToggleFullscreen,
                    onCapture: onCapture,
                    onShare: onShare,
                    onInteractionChanged: onInteractionChanged,
                    onUserInteraction: onUserInteraction,
                    onMenuPresented: onMenuPresented
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(PlayerHUDPalette.primary)
    }
}

/// 只有一层、全屏同色。上下不再使用不同深度，也不分析视频颜色。
private struct PlayerHUDReadabilityScrim: View {
    var body: some View {
        Color.black
            .opacity(0.32)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PlayerHUDTopBar: View {
    let isNarrow: Bool
    let isFullscreen: Bool
    let onClose: () -> Void
    let onToggleFullscreen: () -> Void
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void
    let onUserInteraction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            leadingControls
            Spacer(minLength: 12)
            PlayerHUDVolumeControl(
                isNarrow: isNarrow,
                onInteractionChanged: onInteractionChanged,
                onUserInteraction: onUserInteraction
            )
        }
        .padding(.horizontal, isNarrow ? 16 : 28)
        .padding(.top, topPadding)
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        // 窗口模式的标题栏是系统拖动区。HUD 覆盖 safe area 后若把 Slider 放进去，
        // macOS 会优先移动窗口；顶栏整体下移到标题栏之外，全屏则保持原布局。
        if !isFullscreen { return 58 }
        #endif
        return isNarrow ? 14 : 22
    }

    @ViewBuilder
    private var leadingControls: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                leadingButtons
            }
        } else {
            leadingButtons
        }
    }

    private var leadingButtons: some View {
        HStack(spacing: 10) {
            PlayerHUDGlassIconButton(
                systemImage: "xmark",
                accessibilityLabel: "关闭播放器",
                action: onClose
            )
            #if os(macOS)
            PlayerHUDGlassIconButton(
                systemImage: isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityLabel: "全屏（F / 双击）"
            ) {
                onToggleFullscreen()
                onUserInteraction()
            }
            #endif
        }
    }
}

private struct PlayerHUDVolumeControl: View {
    @Environment(PlaybackController.self) private var controller

    let isNarrow: Bool
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void
    let onUserInteraction: () -> Void

    private var controlDiameter: CGFloat {
        #if os(iOS)
        44
        #else
        42
        #endif
    }

    private var sliderControlSize: ControlSize {
        #if os(iOS)
        .regular
        #else
        .small
        #endif
    }

    var body: some View {
        PlayerHUDGlassSurface(in: Capsule()) {
            HStack(spacing: 8) {
                Slider(value: volumeBinding, in: 0...1) {
                    Text("音量")
                } onEditingChanged: { editing in
                    onInteractionChanged(.volumeDrag, editing)
                }
                .labelsHidden()
                .tint(PlayerHUDPalette.primary)
                .controlSize(sliderControlSize)
                .frame(width: isNarrow ? 88 : 124)
                .frame(minHeight: controlDiameter)
                .accessibilityValue(volumeAccessibilityValue)

                Button {
                    controller.toggleMute()
                    onUserInteraction()
                } label: {
                    Image(systemName: volumeIconName)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PlayerHUDPalette.primary)
                        .frame(width: controlDiameter, height: controlDiameter)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(controller.muted ? "取消静音（M）" : "静音（M）")
                .accessibilityLabel(controller.muted ? "取消静音" : "静音")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .fixedSize(horizontal: true, vertical: true)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("音量控制")
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { controller.volume },
            set: { controller.applyVolume($0) }
        )
    }

    private var volumeIconName: String {
        if controller.muted || controller.volume == 0 { return "speaker.slash.fill" }
        if controller.volume < 0.34 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var volumeAccessibilityValue: String {
        if controller.muted { return "已静音" }
        return "\(Int((controller.volume * 100).rounded()))%"
    }
}

/// 中央操作不再各自取样 Glass；固定白色图标 + 轻阴影由统一暗幕托底。
private struct PlayerHUDTransportControls: View {
    @Environment(PlaybackController.self) private var controller

    let isNarrow: Bool

    var body: some View {
        HStack(spacing: isNarrow ? 38 : 58) {
            transportButton("gobackward.10", label: "后退 10 秒", primary: false) {
                controller.skip(by: -10)
            }
            transportButton(
                controller.state.state == .playing ? "pause.fill" : "play.fill",
                label: controller.state.state == .playing ? "暂停" : "播放",
                primary: true,
                action: controller.togglePlayPause
            )
            transportButton("goforward.10", label: "前进 10 秒", primary: false) {
                controller.skip(by: 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放控制")
    }

    private func transportButton(
        _ systemImage: String,
        label: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let hitSize: CGFloat = primary ? (isNarrow ? 70 : 82) : (isNarrow ? 58 : 66)
        let symbolSize: CGFloat = primary ? hitSize * 0.48 : hitSize * 0.44

        return Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: symbolSize, weight: primary ? .semibold : .medium))
                .foregroundStyle(PlayerHUDPalette.primary)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
        }
        .buttonStyle(PlayerHUDTransportButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PlayerHUDTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PlayerHUDBottomDock: View {
    let isNarrow: Bool
    let playbackID: String
    let title: String
    let kicker: String

    @Binding var isImportingSubtitle: Bool
    @Binding var isSelectingDanmaku: Bool
    @Binding var showStats: Bool
    @Binding var showInfoCard: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void
    let onUserInteraction: () -> Void
    let onMenuPresented: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isNarrow ? 10 : 14) {
            header

            PlayerHUDTimeline(
                playbackID: playbackID,
                onInteractionChanged: onInteractionChanged
            )
        }
        .padding(.horizontal, isNarrow ? 16 : 28)
        .padding(.bottom, isNarrow ? 16 : 28)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var header: some View {
        if isNarrow {
            VStack(alignment: .leading, spacing: 10) {
                PlayerHUDTitleBlock(title: title, kicker: kicker, isNarrow: true)
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(alignment: .bottom, spacing: 20) {
                PlayerHUDTitleBlock(title: title, kicker: kicker, isNarrow: false)
                    .frame(minWidth: 0)
                actions
            }
        }
    }

    private var actions: some View {
        PlayerHUDActionsCapsule(
            isImportingSubtitle: $isImportingSubtitle,
            isSelectingDanmaku: $isSelectingDanmaku,
            showStats: $showStats,
            showInfoCard: $showInfoCard,
            shareURL: shareURL,
            isFullscreen: isFullscreen,
            onToggleFullscreen: onToggleFullscreen,
            onCapture: onCapture,
            onShare: onShare,
            onUserInteraction: onUserInteraction,
            onMenuPresented: onMenuPresented
        )
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(2)
    }
}

private struct PlayerHUDTitleBlock: View {
    let title: String
    let kicker: String
    let isNarrow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !kicker.isEmpty {
                Text(kicker)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PlayerHUDPalette.secondary)
                    .lineLimit(1)
            }
            Text(title)
                .font((isNarrow ? Font.headline : Font.title2).weight(.semibold))
                .foregroundStyle(PlayerHUDPalette.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.72), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }
}

/// 高频 position/duration 只在这一棵子树观察，顶部和其他 Glass 不随播放 tick 重建。
private struct PlayerHUDTimeline: View {
    @Environment(PlaybackController.self) private var controller

    let playbackID: String
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void

    @State private var draftFraction: Double?

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: progressBinding, in: 0...1) {
                Text("播放进度")
            } onEditingChanged: { editing in
                if editing {
                    beginScrubbing()
                } else {
                    finishScrubbing()
                }
            }
            .labelsHidden()
            .tint(PlayerHUDPalette.primary)
            .controlSize(.regular)
            .frame(minHeight: 44)
            .disabled(controller.state.duration == .zero)
            .accessibilityValue(
                "\(playerHUDTimeLabel(displayedPosition)) / \(playerHUDTimeLabel(controller.state.duration))"
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: controller.skip(by: 10)
                case .decrement: controller.skip(by: -10)
                @unknown default: break
                }
            }

            HStack {
                Text(playerHUDTimeLabel(displayedPosition))
                Spacer(minLength: 16)
                Text(playerHUDTimeLabel(controller.state.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(PlayerHUDPalette.secondary)
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        }
        .onChange(of: playbackID) { resetScrubbing() }
        .onDisappear { resetScrubbing() }
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { draftFraction ?? controller.state.progress },
            set: { draftFraction = min(max($0, 0), 1) }
        )
    }

    private var displayedPosition: Duration {
        guard let draftFraction, controller.state.duration > .zero else {
            return controller.state.position
        }
        return .microseconds(Int64(Double(controller.state.duration.microseconds) * draftFraction))
    }

    private func beginScrubbing() {
        if draftFraction == nil { draftFraction = controller.state.progress }
        onInteractionChanged(.timelineDrag, true)
    }

    private func finishScrubbing() {
        if let target = draftFraction {
            controller.seek(toFraction: target)
        }
        draftFraction = nil
        onInteractionChanged(.timelineDrag, false)
    }

    private func resetScrubbing() {
        guard draftFraction != nil else { return }
        draftFraction = nil
        onInteractionChanged(.timelineDrag, false)
    }
}

private struct PlayerHUDDanmakuMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(PlaybackController.self) private var controller

    @Binding var isSelectingDanmaku: Bool
    let controlSide: CGFloat
    let onUserInteraction: () -> Void
    let onMenuPresented: () -> Void

    private let opacities = [0.25, 0.5, 0.75, 1.0]
    private let displayAreas = [0.25, 0.5, 0.75, 1.0]

    var body: some View {
        Menu {
            Toggle("显示弹幕", isOn: Binding(
                get: { controller.danmakuEnabled },
                set: {
                    controller.setDanmakuEnabled($0)
                    onUserInteraction()
                }
            ))

            Text(app.danmaku.status.label)

            Divider()
            Button {
                isSelectingDanmaku = true
                onUserInteraction()
            } label: {
                Label("选择弹幕…", systemImage: "magnifyingglass")
            }
            Button {
                app.danmaku.retryAutomaticMatch()
                onUserInteraction()
            } label: {
                Label("重新自动匹配", systemImage: "arrow.clockwise")
            }

            if !controller.danmakuTracks.isEmpty {
                Divider()
                Menu {
                    Button("提前 0.5 秒", systemImage: "backward.end") {
                        controller.adjustDanmakuOffset(by: -0.5)
                        onUserInteraction()
                    }
                    Button("重置时间", systemImage: "arrow.counterclockwise") {
                        controller.resetDanmakuOffset()
                        onUserInteraction()
                    }
                    Button("延后 0.5 秒", systemImage: "forward.end") {
                        controller.adjustDanmakuOffset(by: 0.5)
                        onUserInteraction()
                    }
                } label: {
                    Label("时间偏移：\(offsetLabel)", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }

            Menu("不透明度") {
                ForEach(opacities, id: \.self) { value in
                    Button {
                        controller.setDanmakuOpacity(value)
                        onUserInteraction()
                    } label: {
                        optionLabel(
                            "\(Int(value * 100))%",
                            selected: abs(controller.danmakuOpacity - value) < 0.001
                        )
                    }
                }
            }

            Menu("显示区域") {
                ForEach(displayAreas, id: \.self) { value in
                    Button {
                        controller.setDanmakuDisplayArea(value)
                        onUserInteraction()
                    } label: {
                        optionLabel(
                            "顶部 \(Int(value * 100))%",
                            selected: abs(controller.danmakuDisplayArea - value) < 0.001
                        )
                    }
                }
            }

            Menu("弹幕类型") {
                Toggle("滚动", isOn: Binding(
                    get: { !controller.danmakuBlockScroll },
                    set: { controller.setDanmakuBlocked(scroll: !$0) }
                ))
                Toggle("顶部", isOn: Binding(
                    get: { !controller.danmakuBlockTop },
                    set: { controller.setDanmakuBlocked(top: !$0) }
                ))
                Toggle("底部", isOn: Binding(
                    get: { !controller.danmakuBlockBottom },
                    set: { controller.setDanmakuBlocked(bottom: !$0) }
                ))
            }

            Divider()
            Toggle("合并重复弹幕", isOn: Binding(
                get: { controller.danmakuMergeDuplicates },
                set: {
                    controller.setDanmakuMergeDuplicates($0)
                    onUserInteraction()
                }
            ))
            Toggle("允许堆叠", isOn: Binding(
                get: { controller.danmakuAllowStacking },
                set: {
                    controller.setDanmakuAllowStacking($0)
                    onUserInteraction()
                }
            ))
        } label: {
            PlayerHUDActionIcon(
                systemImage: controller.danmakuEnabled ? "text.bubble.fill" : "text.bubble",
                side: controlSide
            )
        }
        .menuIndicator(.hidden)
        .modifier(PlayerHUDMenuStyle())
        .frame(width: controlSide, height: controlSide)
        .help("弹幕")
        .accessibilityLabel("弹幕")
        .accessibilityValue(accessibilityValue)
        .simultaneousGesture(TapGesture().onEnded { onMenuPresented() })
    }

    @ViewBuilder
    private func optionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var offsetLabel: String {
        let value = controller.danmakuGlobalOffsetSeconds
        if abs(value) < 0.001 { return "0 秒" }
        return String(format: "%+.1f 秒", value)
    }

    private var accessibilityValue: String {
        let enabled = controller.danmakuEnabled ? "已开启" : "已关闭"
        return "\(enabled)，\(app.danmaku.status.label)"
    }
}

private struct PlayerHUDActionsCapsule: View {
    @Environment(PlaybackController.self) private var controller

    @Binding var isImportingSubtitle: Bool
    @Binding var isSelectingDanmaku: Bool
    @Binding var showStats: Bool
    @Binding var showInfoCard: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onUserInteraction: () -> Void
    let onMenuPresented: () -> Void

    private let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var controlSide: CGFloat {
        #if os(iOS)
        44
        #else
        40
        #endif
    }

    var body: some View {
        PlayerHUDGlassSurface(in: Capsule()) {
            HStack(spacing: 0) {
                PlayerHUDDanmakuMenu(
                    isSelectingDanmaku: $isSelectingDanmaku,
                    controlSide: controlSide,
                    onUserInteraction: onUserInteraction,
                    onMenuPresented: onMenuPresented
                )
                subtitleMenu
                audioMenu
                moreMenu
            }
            .padding(4)
            .fixedSize(horizontal: true, vertical: true)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放选项")
    }

    private var audioMenu: some View {
        Menu {
            ForEach(controller.state.audioTracks) { track in
                Button {
                    controller.selectAudio(track)
                    onUserInteraction()
                } label: {
                    if track.selected {
                        Label(track.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(track.displayTitle)
                    }
                }
            }
        } label: {
            PlayerHUDActionIcon(systemImage: "speaker.wave.2.fill", side: controlSide)
        }
        .menuIndicator(.hidden)
        .modifier(PlayerHUDMenuStyle())
        .frame(width: controlSide, height: controlSide)
        .disabled(controller.state.audioTracks.isEmpty)
        .help("音轨")
        .accessibilityLabel("音轨")
        .accessibilityValue(selectedAudioTitle)
        .simultaneousGesture(TapGesture().onEnded { onMenuPresented() })
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                controller.setSubtitle(nil)
                onUserInteraction()
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
                    onUserInteraction()
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
                onUserInteraction()
            } label: {
                Label("打开外挂字幕…", systemImage: "doc.badge.plus")
            }

            Divider()
            Button {
                controller.adjustSubtitleScale(by: 0.1)
                onUserInteraction()
            } label: {
                Label("字幕加大", systemImage: "textformat.size.larger")
            }
            Button {
                controller.adjustSubtitleScale(by: -0.1)
                onUserInteraction()
            } label: {
                Label("字幕减小", systemImage: "textformat.size.smaller")
            }
            Button {
                controller.resetSubtitleScale()
                onUserInteraction()
            } label: {
                Label("字幕默认大小", systemImage: "arrow.counterclockwise")
            }
        } label: {
            PlayerHUDActionIcon(
                systemImage: isSubtitleOn ? "captions.bubble.fill" : "captions.bubble",
                side: controlSide
            )
        }
        .menuIndicator(.hidden)
        .modifier(PlayerHUDMenuStyle())
        .frame(width: controlSide, height: controlSide)
        .help("字幕")
        .accessibilityLabel("字幕")
        .accessibilityValue(selectedSubtitleTitle)
        .simultaneousGesture(TapGesture().onEnded { onMenuPresented() })
    }

    private var moreMenu: some View {
        Menu {
            playbackRateMenu

            #if os(macOS)
            Divider()
            Button {
                onToggleFullscreen()
                onUserInteraction()
            } label: {
                Label(
                    isFullscreen ? "退出全屏" : "进入全屏",
                    systemImage: isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                )
            }
            #endif

            Divider()
            Button {
                showInfoCard.toggle()
                onUserInteraction()
            } label: {
                Label(
                    showInfoCard ? "隐藏播放信息" : "显示播放信息",
                    systemImage: showInfoCard ? "info.circle.fill" : "info.circle"
                )
            }
            Button {
                showStats.toggle()
                onUserInteraction()
            } label: {
                Label(
                    showStats ? "隐藏播放统计" : "显示播放统计",
                    systemImage: showStats
                        ? "waveform.path.ecg.rectangle.fill"
                        : "waveform.path.ecg.rectangle"
                )
            }

            Divider()
            #if os(macOS)
            Button {
                onCapture()
                onUserInteraction()
            } label: {
                Label("截图", systemImage: "camera.fill")
            }
            if shareURL != nil {
                Button {
                    onShare()
                    onUserInteraction()
                } label: {
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
            PlayerHUDActionIcon(systemImage: "gearshape.fill", side: controlSide)
        }
        .menuIndicator(.hidden)
        .modifier(PlayerHUDMenuStyle())
        .frame(width: controlSide, height: controlSide)
        .help("更多")
        .accessibilityLabel("更多播放选项")
        .simultaneousGesture(TapGesture().onEnded { onMenuPresented() })
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(rates, id: \.self) { value in
                Button {
                    controller.applyRate(value)
                    onUserInteraction()
                } label: {
                    if controller.rate == value {
                        Label(playerHUDRateLabel(value), systemImage: "checkmark")
                    } else {
                        Text(playerHUDRateLabel(value))
                    }
                }
            }
        } label: {
            Label("播放速度：\(playerHUDRateLabel(controller.rate))", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    private var isSubtitleOn: Bool {
        controller.state.subtitleTracks.contains { $0.selected }
    }

    private var selectedSubtitleTitle: String {
        controller.state.subtitleTracks.first(where: { $0.selected })?.displayTitle ?? "已关闭"
    }

    private var selectedAudioTitle: String {
        controller.state.audioTracks.first(where: { $0.selected })?.displayTitle ?? "未选择"
    }
}

private struct PlayerHUDActionIcon: View {
    let systemImage: String
    let side: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(PlayerHUDPalette.primary)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
    }
}

private struct PlayerHUDMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .menuStyle(.button)
            .buttonStyle(.borderless)
        #else
        content
            .buttonStyle(.plain)
        #endif
    }
}

enum PlayerHUDPalette {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.76)
    static let tertiary = Color.white.opacity(0.5)
    static let panelBackground = Color.black.opacity(0.72)
    static let outline = Color.white.opacity(0.16)
}

/// 静态 Glass 承载层：没有固定不透明底色，统一从已经压暗的画面取样。
struct PlayerHUDGlassSurface<SurfaceShape: Shape, Content: View>: View {
    let shape: SurfaceShape
    let content: Content

    init(in shape: SurfaceShape, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                }
        }
    }
}

/// 只有真实 Button 使用 interactive Glass。
private struct PlayerHUDGlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    private var side: CGFloat {
        #if os(iOS)
        44
        #else
        42
        #endif
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            button
                .glassEffect(
                    .regular.interactive(),
                    in: Circle()
                )
        } else {
            button
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                }
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.primary)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 信息、错误和调试内容需要绝对稳定的对比度，不参与视频取样。
struct PlayerHUDPanel<SurfaceShape: Shape, Content: View>: View {
    let shape: SurfaceShape
    let content: Content

    init(in shape: SurfaceShape, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }

    var body: some View {
        content
            .background(PlayerHUDPalette.panelBackground, in: shape)
            .overlay {
                shape.stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
            }
    }
}

/// 单独的观察边界：打开信息卡时，position 更新不会让 PlayerScreen 和主 HUD 一起失效。
struct PlayerHUDInfoPanel: View {
    @Environment(PlaybackController.self) private var controller

    let title: String
    let kicker: String
    let isNarrow: Bool

    var body: some View {
        PlayerHUDPanel(in: RoundedRectangle(cornerRadius: 14)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PlayerHUDPalette.primary)
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.caption)
                        .foregroundStyle(PlayerHUDPalette.secondary)
                }
                Text(
                    "\(stateLabel) · \(playerHUDTimeLabel(controller.state.position)) / "
                        + playerHUDTimeLabel(controller.state.duration)
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PlayerHUDPalette.secondary)
                if let params = controller.state.videoParams {
                    Text("\(params.width)×\(params.height)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PlayerHUDPalette.secondary)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isNarrow ? 16 : 28)
        .padding(.top, isNarrow ? 70 : 82)
        .allowsHitTesting(false)
    }

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
}

struct PlayerHUDStatsPanel: View {
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        PlayerHUDPanel(in: RoundedRectangle(cornerRadius: 14)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.statsLine())
                Text(verbatim: "surface=\(controller.state.hasSurface) · \(videoDescription)")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(PlayerHUDPalette.primary)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 28)
        .padding(.top, 90)
        .allowsHitTesting(false)
    }

    private var videoDescription: String {
        controller.state.videoParams.map { "\($0.width)×\($0.height)" } ?? "-"
    }
}

private func playerHUDRateLabel(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
}

private func playerHUDTimeLabel(_ duration: Duration) -> String {
    duration.formatted(
        .time(pattern: duration > .seconds(3600) ? .hourMinuteSecond : .minuteSecond)
    )
}
