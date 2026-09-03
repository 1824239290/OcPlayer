import PlaybackKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

enum PlayerHUDActionTab: String, CaseIterable, Identifiable, Sendable {
    case danmaku = "弹幕"
    case subtitle = "字幕"
    case audio = "音轨"
    case chapters = "章节"
    case more = "更多"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .danmaku: "text.alignleft"
        case .subtitle: "captions.bubble"
        case .audio: "speaker.wave.2.fill"
        case .chapters: "list.bullet.rectangle.portrait"
        case .more: "gearshape.fill"
        }
    }
}

// MARK: - Action Cluster (Bottom-Trailing Overlay)

/// 右下角动作簇：静息态 5 颗按钮在容器内融合成一颗胶囊；点开的 Tab 按钮条件移除、
/// 以同一 `glassEffectID` 液态形变为面板，其余按钮回流成短胶囊。全部玻璃元素收在
/// 同一个 `GlassEffectContainer` 内共享取样区域（玻璃不能取样玻璃）。
struct PlayerHUDActionCluster: View {
    @Binding var expandedTab: PlayerHUDActionTab?
    // 面板内容自然高度（卡片内实测回传），供 PlayerScreen 把跳过钮抬到面板上方。
    @Binding var panelContentHeight: CGFloat

    @Binding var isImportingSubtitle: Bool
    @Binding var isSelectingDanmaku: Bool
    @Binding var showInfoPanel: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void
    let onUserInteraction: () -> Void

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controlSide: CGFloat {
        #if os(iOS)
        44
        #else
        40
        #endif
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .trailing, spacing: 12) {
                if let tab = expandedTab {
                    PlayerHUDExpandedActionCard(
                        tab: tab,
                        panelContentHeight: $panelContentHeight,
                        isImportingSubtitle: $isImportingSubtitle,
                        isSelectingDanmaku: $isSelectingDanmaku,
                        showInfoPanel: $showInfoPanel,
                        shareURL: shareURL,
                        isFullscreen: isFullscreen,
                        onToggleFullscreen: onToggleFullscreen,
                        onCapture: onCapture,
                        onShare: onShare,
                        onUserInteraction: onUserInteraction
                    )
                    .playerHUDGlassCard(cornerRadius: 22)
                    .glassEffectID(tab.id, in: glassNamespace)
                    // 面板与按钮行间距(12)超出容器 spacing(10)，显式声明借用邻近按钮几何做形变
                    .glassEffectTransition(.matchedGeometry)
                }

                HStack(spacing: 8) {
                    ForEach(PlayerHUDActionTab.allCases) { tab in
                        // 展开中的 Tab 整体移出布局，其玻璃形由同 ID 的面板接管
                        if expandedTab != tab {
                            Button {
                                withAnimation(reduceMotion ? nil : Motion.glass) {
                                    expandedTab = tab
                                }
                                onInteractionChanged(.menuTracking, true)
                                onUserInteraction()
                            } label: {
                                PlayerHUDActionIconContent(tab: tab, controlSide: controlSide)
                            }
                            .buttonStyle(PlayerHUDInteractiveButtonStyle())
                            .playerHUDGlassButton()
                            .glassEffectID(tab.id, in: glassNamespace)
                            .help(tab.rawValue)
                            .accessibilityLabel(tab.rawValue)
                        }
                    }
                }
                .frame(height: controlSide)
            }
        }
    }
}

struct PlayerHUDActionIconContent: View {
    @Environment(PlaybackController.self) private var controller

    let tab: PlayerHUDActionTab
    let controlSide: CGFloat

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(PlayerHUDPalette.primary)
            .opacity(isActive ? 1 : 0.45)
            .motion(Motion.standard, value: isActive)
            .frame(width: controlSide, height: controlSide)
            .contentShape(Circle())
    }

    private var iconName: String {
        switch tab {
        case .danmaku:
            "text.alignleft"
        case .subtitle:
            controller.state.subtitleTracks.contains { $0.selected } ? "captions.bubble.fill" : "captions.bubble"
        case .audio:
            "speaker.wave.2.fill"
        case .chapters:
            "list.bullet.rectangle.portrait"
        case .more:
            "gearshape.fill"
        }
    }

    private var isActive: Bool {
        switch tab {
        case .danmaku:
            controller.danmakuEnabled
        case .subtitle, .chapters, .more:
            true
        case .audio:
            !controller.state.audioTracks.isEmpty
        }
    }
}

// MARK: - Expanded Action Card (Infuse 式「行 + 子菜单」)

/// 面板内二级导航的目标。
enum PlayerHUDPanelSubmenu: Hashable {
    case danmakuOffset
    case danmakuOpacity
    case danmakuDisplayArea
    case danmakuFontSize
    case danmakuFilters
    case subtitleTracks
    case subtitleScale
    case playbackRate

    var title: String {
        switch self {
        case .danmakuOffset: "时间偏移"
        case .danmakuOpacity: "不透明度"
        case .danmakuDisplayArea: "显示区域"
        case .danmakuFontSize: "字号大小"
        case .danmakuFilters: "过滤与显示规则"
        case .subtitleTracks: "字幕轨道"
        case .subtitleScale: "字体大小"
        case .playbackRate: "播放速度"
        }
    }
}

/// 展开面板：根层是「图标 + 标题 + 当前值 + 箭头」的行列表，点击推入子菜单，
/// 子菜单头部提供返回。切换 Tab 依赖按钮簇自身（面板下方就是其余按钮），
/// 收起依赖点击面板外——与 Infuse 一致，面板自身不放关闭按钮。
/// 玻璃底由 `PlayerHUDActionCluster` 统一施加，这里只负责内容与导航。
struct PlayerHUDExpandedActionCard: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(DanmakuModel.self) private var danmakuModel

    let tab: PlayerHUDActionTab

    // 面板内容自然高度（本视图内实测）。Binding 归 PlayerScreen 所有：
    // 跳过按钮层用它计算「面板上方空位」的锚点。
    @Binding var panelContentHeight: CGFloat

    @Binding var isImportingSubtitle: Bool
    @Binding var isSelectingDanmaku: Bool
    @Binding var showInfoPanel: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onUserInteraction: () -> Void

    @State private var submenu: PlayerHUDPanelSubmenu?

    private var maxPanelContentHeight: CGFloat { 320 }

    var body: some View {
        VStack(spacing: 0) {
            if let submenu {
                header(submenu)
            }

            ZStack(alignment: .top) {
                if let submenu {
                    panelBody(submenuContent(submenu))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    panelBody(rootContent)
                        .transition(.section)
                }
            }
            // 子菜单推入时内容从右滑入，裁到卡片圆角内
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .frame(width: 320)
        .motion(Motion.glass, value: submenu)
        .onChange(of: tab) { submenu = nil }
    }

    /// 面板主体高度随内容收缩：放得下就原生高度，超过 320 才滚动。
    /// 不能只给 ScrollView 套 `frame(maxHeight:)`——ScrollView 是贪婪布局，
    /// 两三行的小面板也会被撑满。这里用隐藏镜像（fixedSize 实测自然高度）
    /// 驱动分支，不依赖 ViewThatFits 在 GlassEffectContainer 内的提案表现。
    @ViewBuilder
    private func panelBody(_ content: some View) -> some View {
        let padded = content
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        Group {
            if panelContentHeight > maxPanelContentHeight {
                ScrollView(.vertical, showsIndicators: false) {
                    padded
                }
                .frame(height: maxPanelContentHeight)
            } else {
                padded
            }
        }
        .overlay {
            padded
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    panelContentHeight = $0
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: 导航

    private func header(_ s: PlayerHUDPanelSubmenu) -> some View {
        HStack(spacing: 10) {
            Button {
                submenu = nil
                onUserInteraction()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlayerHUDPalette.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Text(s.title)
                .font(.headline)
                .foregroundStyle(PlayerHUDPalette.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func open(_ target: PlayerHUDPanelSubmenu) {
        submenu = target
        onUserInteraction()
    }

    // MARK: 根层行列表

    @ViewBuilder
    private var rootContent: some View {
        switch tab {
        case .danmaku: danmakuRoot
        case .subtitle: subtitleRoot
        case .audio: audioRoot
        case .chapters: chaptersRoot
        case .more: moreRoot
        }
    }

    private var danmakuRoot: some View {
        VStack(spacing: 2) {
            PlayerHUDToggleMenuRow(
                icon: "text.alignleft",
                title: "启用弹幕",
                badge: danmakuModel.danmaku.status.label,
                isOn: Binding(
                    get: { controller.danmakuEnabled },
                    set: {
                        controller.setDanmakuEnabled($0)
                        onUserInteraction()
                    }
                )
            )
            PlayerHUDActionMenuRow(icon: "magnifyingglass", title: "选择弹幕…") {
                isSelectingDanmaku = true
                onUserInteraction()
            }
            PlayerHUDActionMenuRow(icon: "arrow.clockwise", title: "重新匹配") {
                danmakuModel.danmaku.retryAutomaticMatch()
                onUserInteraction()
            }
            if controller.hasDanmakuLoaded {
                PlayerHUDNavRow(icon: "timer", title: "时间偏移", value: offsetLabel) {
                    open(.danmakuOffset)
                }
            }
            PlayerHUDNavRow(
                icon: "circle.lefthalf.filled",
                title: "不透明度",
                value: percentLabel(controller.danmakuOpacity)
            ) {
                open(.danmakuOpacity)
            }
            PlayerHUDNavRow(
                icon: "arrow.up.to.line",
                title: "显示区域",
                value: "顶部 \(percentLabel(controller.danmakuDisplayArea))"
            ) {
                open(.danmakuDisplayArea)
            }
            PlayerHUDNavRow(icon: "textformat.size", title: "字号大小", value: fontSizeLabel) {
                open(.danmakuFontSize)
            }
            PlayerHUDNavRow(icon: "line.3.horizontal", title: "过滤与显示规则") {
                open(.danmakuFilters)
            }
        }
    }

    private var subtitleRoot: some View {
        VStack(spacing: 2) {
            PlayerHUDNavRow(icon: "captions.bubble", title: "字幕轨道", value: currentSubtitleLabel) {
                open(.subtitleTracks)
            }
            PlayerHUDActionMenuRow(icon: "doc.badge.plus", title: "打开外挂字幕…") {
                isImportingSubtitle = true
                onUserInteraction()
            }
            PlayerHUDNavRow(
                icon: "textformat.size",
                title: "字体大小",
                value: percentLabel(controller.subtitleScale)
            ) {
                open(.subtitleScale)
            }
        }
    }

    private var audioRoot: some View {
        VStack(spacing: 2) {
            if controller.state.audioTracks.isEmpty {
                Text("当前媒体无独立多音轨")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            } else {
                ForEach(controller.state.audioTracks) { track in
                    PlayerHUDCheckRow(
                        icon: "speaker.wave.2.fill",
                        title: track.displayTitle,
                        isSelected: track.selected
                    ) {
                        controller.selectAudio(track)
                        onUserInteraction()
                    }
                }
            }
        }
    }

    private var chaptersRoot: some View {
        let chapters = controller.chapters
        return VStack(spacing: 2) {
            if chapters.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(PlayerHUDPalette.tertiary)
                    Text("当前片源没有章节信息")
                        .font(.caption)
                        .foregroundStyle(PlayerHUDPalette.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // 当前位置用 1Hz 发布的 displayPosition：position 是 @ObservationIgnored，
                // 读它的话高亮永远不会随播放刷新——面板打开就成了死数据。
                let currentIndex = PlaybackChapter.currentIndex(
                    in: chapters,
                    at: Double(controller.state.timeline.displayPosition.microseconds) / 1_000_000)
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    let isCurrent = index == currentIndex
                    Button {
                        controller.seek(toChapter: chapter)
                        onUserInteraction()
                    } label: {
                        HStack(spacing: 10) {
                            Text(timeString(chapter.startSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(PlayerHUDPalette.tertiary)
                                .frame(width: 52, alignment: .leading)
                            Text(chapter.name)
                                .font(.callout.weight(isCurrent ? .semibold : .medium))
                                .foregroundStyle(PlayerHUDPalette.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if isCurrent {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(PlayerHUDPalette.primary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlayerHUDMenuRowButtonStyle())
                    .help(chapter.name)
                }
            }
        }
    }

    private var moreRoot: some View {
        VStack(spacing: 2) {
            PlayerHUDNavRow(
                icon: "speedometer",
                title: "播放速度",
                value: playerHUDRateLabel(controller.rate)
            ) {
                open(.playbackRate)
            }
            PlayerHUDToggleMenuRow(icon: "info.circle", title: "播放信息", isOn: $showInfoPanel)
            #if os(macOS)
            PlayerHUDActionMenuRow(
                icon: isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                title: isFullscreen ? "退出全屏" : "进入全屏"
            ) {
                onToggleFullscreen()
                onUserInteraction()
            }
            PlayerHUDActionMenuRow(icon: "camera.fill", title: "画面截图") {
                onCapture()
                onUserInteraction()
            }
            #endif
            if let shareURL {
                #if os(macOS)
                PlayerHUDActionMenuRow(icon: "square.and.arrow.up", title: "分享媒体") {
                    onShare()
                    onUserInteraction()
                }
                #else
                ShareLink(item: shareURL) {
                    PlayerHUDMenuRowLabel(icon: "square.and.arrow.up", title: "分享媒体")
                }
                .buttonStyle(PlayerHUDMenuRowButtonStyle())
                #endif
            }
        }
    }

    // MARK: 子菜单

    @ViewBuilder
    private func submenuContent(_ s: PlayerHUDPanelSubmenu) -> some View {
        switch s {
        case .danmakuOffset:
            VStack(spacing: 2) {
                PlayerHUDActionMenuRow(icon: "minus", title: "提前 0.5 秒") {
                    controller.adjustDanmakuOffset(by: -0.5)
                    onUserInteraction()
                }
                PlayerHUDActionMenuRow(icon: "arrow.counterclockwise", title: "重置") {
                    controller.resetDanmakuOffset()
                    onUserInteraction()
                }
                PlayerHUDActionMenuRow(icon: "plus", title: "延后 0.5 秒") {
                    controller.adjustDanmakuOffset(by: 0.5)
                    onUserInteraction()
                }
            }
        case .danmakuOpacity:
            optionRows(
                [0.25, 0.5, 0.75, 1.0],
                current: controller.danmakuOpacity,
                title: { percentLabel($0) },
                select: { controller.setDanmakuOpacity($0) }
            )
        case .danmakuDisplayArea:
            optionRows(
                [0.25, 0.5, 0.75, 1.0],
                current: controller.danmakuDisplayArea,
                title: { "顶部 \(percentLabel($0))" },
                select: { controller.setDanmakuDisplayArea($0) }
            )
        case .danmakuFontSize:
            optionRows(
                Self.fontSizes.map(\.1),
                current: controller.danmakuFontSize,
                title: { fontSizeName($0) },
                select: { controller.setDanmakuFontSize($0) }
            )
        case .danmakuFilters:
            VStack(spacing: 2) {
                PlayerHUDToggleMenuRow(
                    icon: "arrow.left.to.line",
                    title: "滚动",
                    isOn: Binding(
                        get: { !controller.danmakuBlockScroll },
                        set: { controller.setDanmakuBlocked(scroll: !$0); onUserInteraction() }
                    )
                )
                PlayerHUDToggleMenuRow(
                    icon: "arrow.up.to.line",
                    title: "顶部",
                    isOn: Binding(
                        get: { !controller.danmakuBlockTop },
                        set: { controller.setDanmakuBlocked(top: !$0); onUserInteraction() }
                    )
                )
                PlayerHUDToggleMenuRow(
                    icon: "arrow.down.to.line",
                    title: "底部",
                    isOn: Binding(
                        get: { !controller.danmakuBlockBottom },
                        set: { controller.setDanmakuBlocked(bottom: !$0); onUserInteraction() }
                    )
                )
                PlayerHUDToggleMenuRow(
                    icon: "arrow.triangle.merge",
                    title: "合并重复",
                    isOn: Binding(
                        get: { controller.danmakuMergeDuplicates },
                        set: { controller.setDanmakuMergeDuplicates($0); onUserInteraction() }
                    )
                )
                PlayerHUDToggleMenuRow(
                    icon: "square.stack.3d.up",
                    title: "允许堆叠",
                    isOn: Binding(
                        get: { controller.danmakuAllowStacking },
                        set: { controller.setDanmakuAllowStacking($0); onUserInteraction() }
                    )
                )
            }
        case .subtitleTracks:
            VStack(spacing: 2) {
                PlayerHUDCheckRow(
                    title: "关闭字幕",
                    isSelected: !controller.state.subtitleTracks.contains { $0.selected }
                ) {
                    controller.setSubtitle(nil)
                    onUserInteraction()
                }
                ForEach(controller.state.subtitleTracks) { track in
                    PlayerHUDCheckRow(
                        title: subtitleTrackLabel(track),
                        isSelected: track.selected
                    ) {
                        controller.setSubtitle(track)
                        onUserInteraction()
                    }
                }
            }
        case .subtitleScale:
            VStack(spacing: 2) {
                PlayerHUDActionMenuRow(icon: "minus", title: "减小") {
                    controller.adjustSubtitleScale(by: -0.1)
                    onUserInteraction()
                }
                if abs(controller.subtitleScale - 1.0) > 0.01 {
                    PlayerHUDActionMenuRow(icon: "arrow.counterclockwise", title: "重置") {
                        controller.resetSubtitleScale()
                        onUserInteraction()
                    }
                }
                PlayerHUDActionMenuRow(icon: "plus", title: "加大") {
                    controller.adjustSubtitleScale(by: 0.1)
                    onUserInteraction()
                }
            }
        case .playbackRate:
            optionRows(
                Self.rates,
                current: controller.rate,
                title: { playerHUDRateLabel($0) },
                select: { controller.applyRate($0) }
            )
        }
    }

    /// 单选值列表（不透明度 / 显示区域 / 字号 / 倍速共用）：选中行带 checkmark。
    private func optionRows(
        _ values: [Double],
        current: Double,
        title: @escaping (Double) -> String,
        select: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                PlayerHUDCheckRow(
                    title: title(value),
                    isSelected: abs(current - value) < 0.01
                ) {
                    select(value)
                    onUserInteraction()
                }
            }
        }
    }

    // MARK: 值文案

    private static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private static let fontSizes: [(String, Double)] = [
        ("小", 18),
        ("标准", 22),
        ("大", 26),
        ("特大", 30),
    ]

    private var offsetLabel: String {
        let value = controller.danmakuGlobalOffsetSeconds
        if abs(value) < 0.001 { return "0 秒" }
        return String(format: "%+.1f 秒", value)
    }

    private var fontSizeLabel: String {
        fontSizeName(controller.danmakuFontSize)
    }

    private var currentSubtitleLabel: String {
        guard let track = controller.state.subtitleTracks.first(where: { $0.selected }) else {
            return "关闭"
        }
        return subtitleTrackLabel(track)
    }

    private func subtitleTrackLabel(_ track: TrackInfo) -> String {
        track.source == .external
            ? "\(controller.externalSubtitleDisplayName(for: track))（外挂）"
            : track.displayTitle
    }

    private func fontSizeName(_ size: Double) -> String {
        if let match = Self.fontSizes.first(where: { abs($0.1 - size) < 0.01 }) {
            return match.0
        }
        return "\(Int(size))"
    }

    private func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

struct PlayerHUDInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .motion(Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - Infuse 式菜单行组件

/// 行内容统一视觉：图标 + 标题 +（尾随值 / checkmark / 箭头）。供各按钮行与 ShareLink 复用。
private struct PlayerHUDMenuRowLabel: View {
    var icon: String? = nil
    let title: String
    var value: String? = nil
    var showsCheckmark = false
    var showsChevron = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlayerHUDPalette.secondary)
                    .frame(width: 22)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(PlayerHUDPalette.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)
                    .lineLimit(1)
            }
            if showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PlayerHUDPalette.primary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PlayerHUDPalette.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 行按压 + 悬停反馈：hover 微亮、按下更亮（macOS 鼠标 / iOS 触摸共用）。
struct PlayerHUDMenuRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.white.opacity(0.14)
                            : (isHovering ? Color.white.opacity(0.08) : Color.clear)
                    )
            )
            .motion(Motion.fast, value: configuration.isPressed)
            .motion(Motion.fast, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// 触发动作的行（无箭头）。
struct PlayerHUDActionMenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerHUDMenuRowLabel(icon: icon, title: title)
        }
        .buttonStyle(PlayerHUDMenuRowButtonStyle())
    }
}

/// 进入子菜单的行：尾随当前值 + 箭头。
struct PlayerHUDNavRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerHUDMenuRowLabel(icon: icon, title: title, value: value, showsChevron: true)
        }
        .buttonStyle(PlayerHUDMenuRowButtonStyle())
    }
}

/// 单选行：选中加粗 + 尾随 checkmark。
struct PlayerHUDCheckRow: View {
    var icon: String? = nil
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerHUDMenuRowLabel(
                icon: icon,
                title: title,
                showsCheckmark: isSelected
            )
            .font(.callout.weight(isSelected ? .semibold : .medium))
        }
        .buttonStyle(PlayerHUDMenuRowButtonStyle())
    }
}

/// 开关行：整行可点，尾随迷你开关。
struct PlayerHUDToggleMenuRow: View {
    let icon: String
    let title: String
    var badge: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlayerHUDPalette.secondary)
                    .frame(width: 22)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PlayerHUDPalette.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(PlayerHUDPalette.tertiary)
                        .lineLimit(1)
                }
                PlayerHUDMiniSwitch(isOn: isOn)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerHUDMenuRowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

/// HUD 内的迷你开关：系统 Switch 在玻璃底上对比度不稳，手绘胶囊 + 圆点。
private struct PlayerHUDMiniSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.white.opacity(0.22))
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .offset(x: isOn ? 16 : 2)
        }
        .frame(width: 32, height: 18)
        .motion(Motion.standard, value: isOn)
    }
}

// MARK: - 浮动「跳过」按钮

/// 播放到片头 / 片尾(识别命中或末 90s 保底)时,浮在视频上、独立于 HUD 显隐的「跳过」按钮。
///
/// 自己观察 position 派生出的 observable(`progress` 每 100ms 发布一次),不参与 HUD 的
/// 自动隐藏手势,也不随每个播放帧重建。出现 / 消失都走动画。
struct PlayerSkipPromptView: View {
    @Environment(PlaybackController.self) private var controller

    @State private var prompt: SkipPrompt?

    var body: some View {
        Group {
            if let prompt {
                Button {
                    controller.performSkip()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: prompt.kind == .opening ? "forward.fill" : "forward.end.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(prompt.kind.buttonTitle)
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(PlayerHUDPalette.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Capsule())
                }
                .buttonStyle(PlayerSkipButtonStyle())
                .playerHUDGlassButton(in: Capsule())
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .motion(Motion.standard, value: prompt)
        // 播放走帧时 top-level 的 position 不发布观察;用 100ms 发布的 progress 派生 prompt。
        .onChange(of: controller.state.timeline.progress, initial: true) {
            prompt = controller.currentSkipPrompt
        }
    }
}

struct PlayerSkipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .motion(Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass View Modifiers

extension View {
    /// 面板玻璃：圆角矩形取样。形变配对（glassEffectID）由调用方在 `GlassEffectContainer` 内施加。
    func playerHUDGlassCard(cornerRadius: CGFloat = 22) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// 按钮玻璃：interactive 取样，按压/悬停有液态反馈。
    func playerHUDGlassButton(in shape: some Shape = Circle()) -> some View {
        glassEffect(.regular.interactive(), in: shape)
    }
}



