import PlaybackKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct PlayerHUDActionsCapsule: View {
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
                    onUserInteraction: onUserInteraction
                )
                PlayerHUDSubtitleMenu(
                    isImportingSubtitle: $isImportingSubtitle,
                    controlSide: controlSide,
                    onUserInteraction: onUserInteraction
                )
                PlayerHUDAudioMenu(
                    controlSide: controlSide,
                    onUserInteraction: onUserInteraction
                )
                PlayerHUDMoreMenu(
                    showStats: $showStats,
                    showInfoCard: $showInfoCard,
                    shareURL: shareURL,
                    isFullscreen: isFullscreen,
                    controlSide: controlSide,
                    onToggleFullscreen: onToggleFullscreen,
                    onCapture: onCapture,
                    onShare: onShare,
                    onUserInteraction: onUserInteraction
                )
            }
            .padding(4)
            .fixedSize(horizontal: true, vertical: true)
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放选项")
    }
}

struct PlayerHUDAudioMenu: View {
    @Environment(PlaybackController.self) private var controller

    let controlSide: CGFloat
    let onUserInteraction: () -> Void

    var body: some View {
        Menu {
            Picker("音轨", selection: Binding(
                get: { controller.state.audioTracks.first(where: { $0.selected })?.id ?? -1 },
                set: { id in
                    if let track = controller.state.audioTracks.first(where: { $0.id == id }) {
                        controller.selectAudio(track)
                        onUserInteraction()
                    }
                }
            )) {
                ForEach(controller.state.audioTracks) { track in
                    Text(track.displayTitle).tag(track.id)
                }
            }
            .pickerStyle(.inline)
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
    }

    private var selectedAudioTitle: String {
        controller.state.audioTracks.first(where: { $0.selected })?.displayTitle ?? "未选择"
    }
}

struct PlayerHUDSubtitleMenu: View {
    @Environment(PlaybackController.self) private var controller

    @Binding var isImportingSubtitle: Bool
    let controlSide: CGFloat
    let onUserInteraction: () -> Void

    var body: some View {
        Menu {
            Picker("字幕", selection: Binding(
                get: { controller.state.subtitleTracks.first(where: { $0.selected })?.id ?? -1 },
                set: { id in
                    if id == -1 {
                        controller.setSubtitle(nil)
                    } else if let track = controller.state.subtitleTracks.first(where: { $0.id == id }) {
                        controller.setSubtitle(track)
                    }
                    onUserInteraction()
                }
            )) {
                Text("关闭").tag(Int64(-1))
                ForEach(controller.state.subtitleTracks) { track in
                    let label = track.source == .external
                        ? "\(controller.externalSubtitleDisplayName(for: track))（外挂）"
                        : track.displayTitle
                    Text(label).tag(track.id)
                }
            }
            .pickerStyle(.inline)

            Divider()
            Button {
                isImportingSubtitle = true
                onUserInteraction()
            } label: {
                Label("打开外挂字幕…", systemImage: "doc.badge.plus")
            }

            Divider()
            Section {
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
                if abs(controller.subtitleScale - 1.0) > 0.01 {
                    Button {
                        controller.resetSubtitleScale()
                        onUserInteraction()
                    } label: {
                        Label("重置为默认大小", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("字体大小（当前 \(Int((controller.subtitleScale * 100).rounded()))%）")
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
    }

    private var isSubtitleOn: Bool {
        controller.state.subtitleTracks.contains { $0.selected }
    }

    private var selectedSubtitleTitle: String {
        guard let track = controller.state.subtitleTracks.first(where: { $0.selected }) else {
            return "已关闭"
        }
        return track.source == .external
            ? controller.externalSubtitleDisplayName(for: track)
            : track.displayTitle
    }
}

struct PlayerHUDMoreMenu: View {
    @Environment(PlaybackController.self) private var controller

    @Binding var showStats: Bool
    @Binding var showInfoCard: Bool

    let shareURL: URL?
    let isFullscreen: Bool
    let controlSide: CGFloat
    let onToggleFullscreen: () -> Void
    let onCapture: () -> Void
    let onShare: () -> Void
    let onUserInteraction: () -> Void

    private let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
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
    }

    private var playbackRateMenu: some View {
        Picker("播放速度", selection: Binding(
            get: { controller.rate },
            set: {
                controller.applyRate($0)
                onUserInteraction()
            }
        )) {
            ForEach(rates, id: \.self) { value in
                Text(playerHUDRateLabel(value)).tag(value)
            }
        }
    }
}

struct PlayerHUDActionIcon: View {
    let systemImage: String
    let side: CGFloat
    /// 关闭时图标变暗，用于无 fill 变体的符号（如弹幕 text.alignleft）。
    var isActive: Bool = true

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(PlayerHUDPalette.primary)
            .opacity(isActive ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
    }
}

struct PlayerHUDMenuStyle: ViewModifier {
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

