import ErikaKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct PlayerHUDActionsCapsule: View {
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
                let label = track.source == .external
                    ? "\(controller.externalSubtitleDisplayName(for: track))（外挂）"
                    : track.displayTitle
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
        guard let track = controller.state.subtitleTracks.first(where: { $0.selected }) else {
            return "已关闭"
        }
        return track.source == .external
            ? controller.externalSubtitleDisplayName(for: track)
            : track.displayTitle
    }

    private var selectedAudioTitle: String {
        controller.state.audioTracks.first(where: { $0.selected })?.displayTitle ?? "未选择"
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

