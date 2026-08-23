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
            .modifier(PointingHandCursor())
            #endif
    }
}

#if os(macOS)
/// 悬停时把光标换成小手。
///
/// `NSCursor.push()` / `pop()` 是一个栈，**必须配平**：视图在悬停中被移除时
/// （返回上一页、`canTogglePlayed` 翻转把「已看过」钮摘掉、切季重建列表）
/// `onHover(false)` 不会再来，`pop()` 就永远不执行——小手光标会一直留在屏幕上，
/// 直到别处的 push/pop 偶然把栈撞回来。所以 `onDisappear` 也要兜一次，
/// 并用 `pushed` 标志保证只 pop 自己压进去的那一层。
private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    guard !pushed else { return }
                    pushed = true
                    NSCursor.pointingHand.push()
                } else {
                    pop()
                }
            }
            .onDisappear(perform: pop)
    }

    private func pop() {
        guard pushed else { return }
        pushed = false
        NSCursor.pop()
    }
}
#endif

// MARK: - 横向选集卡（点选中，不直接播放）

/// 详情页剧集横向选集：剧照 + 集号/标题 + 进度；点击更新选中态，双击直接播放。
struct EpisodeSelectCard: View {
    let episode: MediaItem
    let server: JellyfinServer?
    let isSelected: Bool
    var onSelect: () -> Void
    var onPlay: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var cardWidth: CGFloat { Metrics.episodeCardWidth }
    private var thumbHeight: CGFloat { Metrics.episodeThumbHeight }

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
                        // 用 tint 而不是硬编码的绿：设计系统只用「中性 primary +
                        // tint 表示已生效」两色（同 BangumiEpisodeCell / 下面那条进度轨），
                        // 绿勾配蓝轨会让同一张卡上出现两个色相。
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.white, .tint)
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
                            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.22 : 0)),
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
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onPlay?()
            }
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("轻点以选中，双击直接播放")
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
            // 轨道宽度就是定死的 `cardWidth`，直接乘比例，不用 GeometryReader——
            // 横向 LazyHStack 里每张卡塞一个测量器会多出一轮布局往返，
            // 而它测出来的就是我们已经知道的那个常量（同 `StillCard.progressTrack`）。
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.22))
                Rectangle()
                    .fill(.tint)
                    .frame(width: cardWidth * progress)
            }
            .frame(width: cardWidth, height: 3)
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
