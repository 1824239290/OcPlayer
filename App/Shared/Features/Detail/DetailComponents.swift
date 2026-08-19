import CoreModel
import JellyfinKit
import SwiftUI

/// Use Apple's Liquid Glass effect where available and keep the same capsule
/// geometry with a material fallback on iOS 17 / macOS 14.
struct DetailPlayButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            content
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            fallback(content)
        }
        #elseif os(macOS)
        if #available(macOS 26, *) {
            content
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            fallback(content)
        }
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
    }
}

struct EpisodeRow: View {
    let episode: MediaItem
    let server: JellyfinServer?
    var onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    let target = episode.episodeThumbTarget(server, width: 400)
                    RemoteImage(url: target.url, authHeader: target.authHeader)
                    LinearGradient(colors: [.black.opacity(0.5), .clear],
                                   startPoint: .bottom, endPoint: .center)
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .font(.caption)
                        .padding(7)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(8)
                }
                .frame(width: 200, height: 112)
                .clipShape(.rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if let label = episode.episodeLabel {
                            Text(label)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        Text(episode.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if episode.playState?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.footnote)
                        }
                    }
                    if let overview = episode.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let runtime = episode.runtimeSeconds {
                            Text(RuntimeText.format(runtime))
                        }
                        if let playState = episode.playState, playState.percentage > 0.02, !playState.played {
                            ProgressView(value: playState.percentage)
                                .frame(width: 90)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
