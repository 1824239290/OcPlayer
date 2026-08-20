import CoreModel
import JellyfinKit
import SwiftUI

// MARK: - 播放主按钮样式（横幅深色底上的白底胶囊）

/// macOS 上 plain Button 的默认悬停会叠一层白，白底按钮会「看起来没了」；
/// 这里自己画悬停/按下，并关掉系统 hover 效果。
struct DetailPlayButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(DetailPlayChromeButtonStyle())
            #if os(macOS)
            .buttonBorderShape(.capsule)
            #endif
    }
}

private struct DetailPlayChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(configuration.isPressed ? 0.92 : 1)
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
    }
}

// MARK: - 横向选集卡（点选中，不直接播放）

/// 详情页剧集横向选集：剧照 + 集号/标题 + 进度；点击只更新选中态。
struct EpisodeSelectCard: View {
    let episode: MediaItem
    let server: JellyfinServer?
    let isSelected: Bool
    var onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private let cardWidth: CGFloat = 200
    private let thumbHeight: CGFloat = 112

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    let target = episode.episodeThumbTarget(server, width: 400)
                    RemoteImage(url: target.url, authHeader: target.authHeader)
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: cardWidth, height: thumbHeight)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )

                    if episode.playState?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.white, .green)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }

                    progressTrack
                        .frame(height: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(width: cardWidth, height: thumbHeight)
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(hovering ? 0.22 : 0),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
                .shadow(
                    color: .black.opacity(isSelected ? 0.28 : (hovering ? 0.18 : 0)),
                    radius: isSelected || hovering ? 10 : 0,
                    y: isSelected || hovering ? 4 : 0
                )

                VStack(alignment: .leading, spacing: 2) {
                    if let label = episode.episodeLabel {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    Text(episode.name)
                        .font(.footnote.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(width: cardWidth, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: cardWidth, alignment: .topLeading)
            .scaleEffect(lifted ? 1.03 : 1)
            .animation(motion, value: isSelected)
            .animation(motion, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("轻点以选中，使用页面上的播放按钮开始播放")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var lifted: Bool {
        !reduceMotion && (isSelected || hovering)
    }

    private var motion: Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.12)
    }

    @ViewBuilder
    private var progressTrack: some View {
        let progress = episodeProgress
        if progress > 0.02, episode.playState?.played != true {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.22))
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 3)
        }
    }

    private var episodeProgress: Double {
        guard let state = episode.playState else { return 0 }
        if state.percentage > 0 {
            return min(max(state.percentage, 0), 1)
        }
        guard let runtime = episode.runtimeSeconds, runtime > 0 else { return 0 }
        return min(max(state.positionSeconds / runtime, 0), 1)
    }

    private var accessibilityLabelText: String {
        var parts: [String] = []
        if let label = episode.episodeLabel { parts.append(label) }
        parts.append(episode.name)
        if episode.playState?.played == true {
            parts.append("已看完")
        } else if episodeProgress > 0.02 {
            parts.append("已播放 \(Int(episodeProgress * 100))%")
        }
        if isSelected { parts.append("已选中") }
        return parts.joined(separator: "，")
    }
}
