import ErikaKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct PlayerHUDBottomDock: View {
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

struct PlayerHUDTitleBlock: View {
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
struct PlayerHUDTimeline: View {
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
            return controller.state.displayPosition
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

