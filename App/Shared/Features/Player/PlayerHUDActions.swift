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

// MARK: - Action Buttons Bar (In Bottom Dock)

struct PlayerHUDActionButtonsBar: View {
    @Binding var expandedTab: PlayerHUDActionTab?
    let morphAnimation: Namespace.ID
    let onInteractionChanged: (PlayerHUDInteraction, Bool) -> Void
    let onUserInteraction: () -> Void

    private var controlSide: CGFloat {
        #if os(iOS)
        44
        #else
        40
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PlayerHUDActionTab.allCases) { tab in
                let isCurrentExpanded = expandedTab == tab
                Button {
                    withAnimation(.smooth(duration: 0.35)) {
                        expandedTab = tab
                    }
                    onInteractionChanged(.menuTracking, true)
                    onUserInteraction()
                } label: {
                    PlayerHUDActionIconContent(tab: tab, controlSide: controlSide)
                }
                .buttonStyle(PlayerHUDInteractiveButtonStyle())
                .playerHUDGlassButton(
                    in: Circle(),
                    id: tab.id,
                    namespace: morphAnimation
                )
                .opacity(expandedTab == nil ? 1 : (isCurrentExpanded ? 0 : 0.35))
                .scaleEffect(expandedTab == nil ? 1 : 0.85)
                .allowsHitTesting(expandedTab == nil)
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
            }
        }
        .frame(height: controlSide)
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
            .animation(.easeInOut(duration: 0.2), value: isActive)
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

// MARK: - Expanded Action Card (In HUD Overlay)

struct PlayerHUDExpandedActionCard: View {
    let tab: PlayerHUDActionTab
    @Binding var expandedTab: PlayerHUDActionTab?

    @Binding var isImportingSubtitle: Bool
    @Binding var isSelectingDanmaku: Bool
    @Binding var showInfoPanel: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onClose: () -> Void
    let onUserInteraction: () -> Void
    let morphAnimation: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：图标、标题、快速切换与关闭按钮
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlayerHUDPalette.primary)
                Text(tab.rawValue)
                    .font(.headline)
                    .foregroundStyle(PlayerHUDPalette.primary)

                Spacer(minLength: 8)

                // 快速切换其它 Tab
                HStack(spacing: 4) {
                    ForEach(PlayerHUDActionTab.allCases) { item in
                        Button {
                            withAnimation(.smooth(duration: 0.25)) {
                                expandedTab = item
                            }
                            onUserInteraction()
                        } label: {
                            Image(systemName: item.iconName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(item == tab ? PlayerHUDPalette.primary : PlayerHUDPalette.tertiary)
                                .frame(width: 26, height: 26)
                                .background(
                                    item == tab ? Color.white.opacity(0.18) : Color.clear,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .help(item.rawValue)
                    }
                }

                // 关闭形变卡片
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(PlayerHUDPalette.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("收起")
                .accessibilityLabel("收起控制面板")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()
                .overlay(PlayerHUDPalette.outline)

            // 各功能模块内容
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .danmaku:
                        PlayerHUDDanmakuPanelContent(
                            isSelectingDanmaku: $isSelectingDanmaku,
                            onUserInteraction: onUserInteraction
                        )
                    case .subtitle:
                        PlayerHUDSubtitlePanelContent(
                            isImportingSubtitle: $isImportingSubtitle,
                            onUserInteraction: onUserInteraction
                        )
                    case .audio:
                        PlayerHUDAudioPanelContent(
                            onUserInteraction: onUserInteraction
                        )
                    case .chapters:
                        PlayerHUDChaptersPanelContent(onUserInteraction: onUserInteraction)
                    case .more:
                        PlayerHUDMorePanelContent(
                            showInfoPanel: $showInfoPanel,
                            shareURL: shareURL,
                            isFullscreen: isFullscreen,
                            onToggleFullscreen: onToggleFullscreen,
                            onCapture: onCapture,
                            onShare: onShare,
                            onUserInteraction: onUserInteraction
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
        .playerHUDGlassCard(
            cornerRadius: 22,
            id: tab.id,
            namespace: morphAnimation
        )
    }
}

struct PlayerHUDInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Danmaku Panel

struct PlayerHUDDanmakuPanelContent: View {
    @Environment(DanmakuModel.self) private var danmakuModel
    @Environment(PlaybackController.self) private var controller

    @Binding var isSelectingDanmaku: Bool
    let onUserInteraction: () -> Void

    private let opacities = [0.25, 0.5, 0.75, 1.0]
    private let displayAreas = [0.25, 0.5, 0.75, 1.0]
    private let fontSizes: [(String, Double)] = [
        ("小", 18),
        ("标准", 22),
        ("大", 26),
        ("特大", 30),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 开关与状态
            HStack {
                Toggle("启用弹幕", isOn: Binding(
                    get: { controller.danmakuEnabled },
                    set: {
                        controller.setDanmakuEnabled($0)
                        onUserInteraction()
                    }
                ))
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .font(.subheadline.weight(.medium))

                Spacer()

                DanmakuStatusBadge()
            }

            // 快捷操作
            HStack(spacing: 8) {
                Button {
                    isSelectingDanmaku = true
                    onUserInteraction()
                } label: {
                    Label("选择弹幕…", systemImage: "magnifyingglass")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    danmakuModel.danmaku.retryAutomaticMatch()
                    onUserInteraction()
                } label: {
                    Label("重新匹配", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if controller.hasDanmakuLoaded {
                // 时间偏移
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("时间偏移")
                            .font(.caption)
                            .foregroundStyle(PlayerHUDPalette.secondary)
                        Spacer()
                        Text(offsetLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PlayerHUDPalette.primary)
                    }
                    HStack(spacing: 6) {
                        Button("提前 0.5s") {
                            controller.adjustDanmakuOffset(by: -0.5)
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDMiniButtonStyle())

                        Button("重置") {
                            controller.resetDanmakuOffset()
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDMiniButtonStyle())

                        Button("延后 0.5s") {
                            controller.adjustDanmakuOffset(by: 0.5)
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDMiniButtonStyle())
                    }
                }
            }

            // 不透明度
            VStack(alignment: .leading, spacing: 6) {
                Text("不透明度")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)
                HStack(spacing: 6) {
                    ForEach(opacities, id: \.self) { val in
                        let isSelected = abs(controller.danmakuOpacity - val) < 0.01
                        Button("\(Int(val * 100))%") {
                            controller.setDanmakuOpacity(val)
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDOptionButtonStyle(isSelected: isSelected))
                    }
                }
            }

            // 显示区域
            VStack(alignment: .leading, spacing: 6) {
                Text("显示区域")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)
                HStack(spacing: 6) {
                    ForEach(displayAreas, id: \.self) { val in
                        let isSelected = abs(controller.danmakuDisplayArea - val) < 0.01
                        Button("顶部 \(Int(val * 100))%") {
                            controller.setDanmakuDisplayArea(val)
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDOptionButtonStyle(isSelected: isSelected))
                    }
                }
            }

            // 字号大小
            VStack(alignment: .leading, spacing: 6) {
                Text("字号大小")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)
                HStack(spacing: 6) {
                    ForEach(fontSizes, id: \.1) { name, size in
                        let isSelected = abs(controller.danmakuFontSize - size) < 0.01
                        Button(name) {
                            controller.setDanmakuFontSize(size)
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDOptionButtonStyle(isSelected: isSelected))
                    }
                }
            }

            // 类型与高级过滤
            VStack(alignment: .leading, spacing: 8) {
                Text("过滤与显示规则")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)

                HStack(spacing: 6) {
                    PlayerHUDToggleChip(
                        title: "滚动",
                        isOn: Binding(
                            get: { !controller.danmakuBlockScroll },
                            set: { controller.setDanmakuBlocked(scroll: !$0); onUserInteraction() }
                        )
                    )
                    PlayerHUDToggleChip(
                        title: "顶部",
                        isOn: Binding(
                            get: { !controller.danmakuBlockTop },
                            set: { controller.setDanmakuBlocked(top: !$0); onUserInteraction() }
                        )
                    )
                    PlayerHUDToggleChip(
                        title: "底部",
                        isOn: Binding(
                            get: { !controller.danmakuBlockBottom },
                            set: { controller.setDanmakuBlocked(bottom: !$0); onUserInteraction() }
                        )
                    )
                }

                HStack(spacing: 6) {
                    PlayerHUDToggleChip(
                        title: "合并重复",
                        isOn: Binding(
                            get: { controller.danmakuMergeDuplicates },
                            set: { controller.setDanmakuMergeDuplicates($0); onUserInteraction() }
                        )
                    )
                    PlayerHUDToggleChip(
                        title: "允许堆叠",
                        isOn: Binding(
                            get: { controller.danmakuAllowStacking },
                            set: { controller.setDanmakuAllowStacking($0); onUserInteraction() }
                        )
                    )
                }
            }
        }
    }

    private var offsetLabel: String {
        let value = controller.danmakuGlobalOffsetSeconds
        if abs(value) < 0.001 { return "0 秒" }
        return String(format: "%+.1f 秒", value)
    }
}

// MARK: - Subtitle Panel

struct PlayerHUDSubtitlePanelContent: View {
    @Environment(PlaybackController.self) private var controller

    @Binding var isImportingSubtitle: Bool
    let onUserInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 字幕轨道选择
            VStack(alignment: .leading, spacing: 6) {
                Text("字幕轨道")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)

                VStack(spacing: 4) {
                    let isOffSelected = !controller.state.subtitleTracks.contains { $0.selected }
                    PlayerHUDTrackSelectionRow(
                        title: "关闭字幕",
                        isSelected: isOffSelected,
                        action: {
                            controller.setSubtitle(nil)
                            onUserInteraction()
                        }
                    )

                    ForEach(controller.state.subtitleTracks) { track in
                        let isSelected = track.selected
                        let label = track.source == .external
                            ? "\(controller.externalSubtitleDisplayName(for: track))（外挂）"
                            : track.displayTitle
                        PlayerHUDTrackSelectionRow(
                            title: label,
                            isSelected: isSelected,
                            action: {
                                controller.setSubtitle(track)
                                onUserInteraction()
                            }
                        )
                    }
                }
            }

            // 外挂字幕导入
            Button {
                isImportingSubtitle = true
                onUserInteraction()
            } label: {
                Label("打开外挂字幕…", systemImage: "doc.badge.plus")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            // 字号调节
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字体大小")
                        .font(.caption)
                        .foregroundStyle(PlayerHUDPalette.secondary)
                    Spacer()
                    Text("\(Int((controller.subtitleScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PlayerHUDPalette.primary)
                }

                HStack(spacing: 6) {
                    Button {
                        controller.adjustSubtitleScale(by: -0.1)
                        onUserInteraction()
                    } label: {
                        Label("减小", systemImage: "textformat.size.smaller")
                    }
                    .buttonStyle(PlayerHUDMiniButtonStyle())

                    if abs(controller.subtitleScale - 1.0) > 0.01 {
                        Button("重置") {
                            controller.resetSubtitleScale()
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDMiniButtonStyle())
                    }

                    Button {
                        controller.adjustSubtitleScale(by: 0.1)
                        onUserInteraction()
                    } label: {
                        Label("加大", systemImage: "textformat.size.larger")
                    }
                    .buttonStyle(PlayerHUDMiniButtonStyle())
                }
            }
        }
    }
}

// MARK: - Audio Panel

struct PlayerHUDAudioPanelContent: View {
    @Environment(PlaybackController.self) private var controller

    let onUserInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("音轨选择")
                .font(.caption)
                .foregroundStyle(PlayerHUDPalette.secondary)

            if controller.state.audioTracks.isEmpty {
                Text("当前媒体无独立多音轨")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.tertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(controller.state.audioTracks) { track in
                        PlayerHUDTrackSelectionRow(
                            title: track.displayTitle,
                            isSelected: track.selected,
                            leadingIcon: "speaker.wave.2.fill",
                            action: {
                                controller.selectAudio(track)
                                onUserInteraction()
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - More Panel

struct PlayerHUDMorePanelContent: View {
    @Environment(PlaybackController.self) private var controller

    @Binding var showInfoPanel: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onUserInteraction: () -> Void

    private let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 播放速度
            VStack(alignment: .leading, spacing: 6) {
                Text("播放速度")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)

                HStack(spacing: 6) {
                    ForEach(rates, id: \.self) { rate in
                        let isSelected = abs(controller.rate - rate) < 0.01
                        Button(playerHUDRateLabel(rate)) {
                            controller.applyRate(rate)
                            onUserInteraction()
                        }
                        .buttonStyle(PlayerHUDOptionButtonStyle(isSelected: isSelected))
                    }
                }
            }

            // HUD 面板开关（原「播放信息」+「播放统计」两块已合并成一个面板）
            VStack(alignment: .leading, spacing: 8) {
                Text("辅助面板")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)

                PlayerHUDToggleChip(
                    title: "播放信息",
                    icon: "info.circle",
                    isOn: $showInfoPanel
                )
            }

            // 快捷动作
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷操作")
                    .font(.caption)
                    .foregroundStyle(PlayerHUDPalette.secondary)

                VStack(spacing: 6) {
                    #if os(macOS)
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
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onCapture()
                        onUserInteraction()
                    } label: {
                        Label("画面截图", systemImage: "camera.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if shareURL != nil {
                        Button {
                            onShare()
                            onUserInteraction()
                        } label: {
                            Label("分享媒体", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    #else
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("分享媒体", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                }
            }
        }
    }
}

// MARK: - Reusable UI Components

struct PlayerHUDOptionButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.black : PlayerHUDPalette.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Color.white : Color.white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

struct PlayerHUDMiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.medium))
            .foregroundStyle(PlayerHUDPalette.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct PlayerHUDToggleChip: View {
    let title: String
    var icon: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.caption.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.black : PlayerHUDPalette.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                isOn ? Color.white : Color.white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

struct PlayerHUDTrackSelectionRow: View {
    let title: String
    let isSelected: Bool
    var leadingIcon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? PlayerHUDPalette.primary : PlayerHUDPalette.tertiary)
                }
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(PlayerHUDPalette.primary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PlayerHUDPalette.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DanmakuStatusBadge: View {
    @Environment(DanmakuModel.self) private var danmakuModel

    var body: some View {
        Text(danmakuModel.danmaku.status.label)
            .font(.caption2)
            .foregroundStyle(PlayerHUDPalette.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.12), in: Capsule())
    }
}

// MARK: - Chapters Panel

/// 章节面板:列出当前源的章节,点击跳转。
struct PlayerHUDChaptersPanelContent: View {
    @Environment(PlaybackController.self) private var controller

    let onUserInteraction: () -> Void

    var body: some View {
        let chapters = controller.chapters
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
            VStack(alignment: .leading, spacing: 2) {
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
                                .font(.callout.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(PlayerHUDPalette.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if isCurrent {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(PlayerHUDPalette.primary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            isCurrent ? Color.white.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(chapter.name)
                }
            }
        }
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

// MARK: - 浮动「跳过」按钮

/// 播放到片头 / 片尾(识别命中或末 90s 保底)时,浮在视频上、独立于 HUD 显隐的「跳过」按钮。
///
/// 自己观察 position 派生出的 observable(`progress` 每 100ms 发布一次),不参与 HUD 的
/// 自动隐藏手势,也不随每个播放帧重建。出现 / 消失都走动画。
struct PlayerSkipPromptView: View {
    @Environment(PlaybackController.self) private var controller

    @State private var prompt: SkipPrompt?
    @Namespace private var skipNamespace

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
                .playerHUDGlassButton(in: Capsule(), id: "skip-prompt", namespace: skipNamespace)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: prompt)
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
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass View Modifiers

extension View {
    @ViewBuilder
    func playerHUDGlassCard(
        cornerRadius: CGFloat = 22,
        id: (some Hashable & Sendable)? = nil,
        namespace: Namespace.ID? = nil
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            if let id, let namespace {
                self
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                    .glassEffectID(id, in: namespace)
                    .matchedGeometryEffect(id: id, in: namespace)
            } else {
                self
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            if let id, let namespace {
                self
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                    }
                    .matchedGeometryEffect(id: id, in: namespace)
            } else {
                self
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                    }
            }
        }
    }

    @ViewBuilder
    func playerHUDGlassButton(
        in shape: some Shape = Circle(),
        id: (some Hashable & Sendable)? = nil,
        namespace: Namespace.ID? = nil
    ) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            if let id, let namespace {
                self
                    .glassEffect(.regular.interactive(), in: shape)
                    .glassEffectID(id, in: namespace)
                    .matchedGeometryEffect(id: id, in: namespace)
            } else {
                self
                    .glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            if let id, let namespace {
                self
                    .background(.ultraThinMaterial, in: shape)
                    .overlay {
                        shape.stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                    }
                    .matchedGeometryEffect(id: id, in: namespace)
            } else {
                self
                    .background(.ultraThinMaterial, in: shape)
                    .overlay {
                        shape.stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                    }
            }
        }
    }
}



