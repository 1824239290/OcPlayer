import ErikaKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

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
struct PlayerHUDReadabilityScrim: View {
    var body: some View {
        Color.black
            .opacity(0.32)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PlayerHUDTopBar: View {
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

struct PlayerHUDVolumeControl: View {
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
struct PlayerHUDTransportControls: View {
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

struct PlayerHUDTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

