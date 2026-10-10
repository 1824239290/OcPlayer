import AppDesignKit
import CoreModel
import JellyfinKit
import MetadataKit
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
    let server: (any MediaServer)?
    /// 展示用标题（TMDb 优先；占位名会被真标题顶掉）。调用方已解析好。
    let displayTitle: String
    /// 展示用简介（tooltip 用）。nil = 没有。
    let displayOverview: String?
    /// 已解析好的剧照取图目标（服务端 / TMDb 的 still_path，由调用方按策略定）。
    let thumbTarget: (url: URL?, authHeader: String?)
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
                    RemoteImage(url: thumbTarget.url, authHeader: thumbTarget.authHeader, maxPixelSize: 400)
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
                .clipShape(.rect(cornerRadius: Metrics.episodeCardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.episodeCardRadius)
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
                    Text(displayTitle)
                        .font(.footnote.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        // `reservesSpace`：标题恒占两行的高度。轨道里每张卡的高度因此**恒定**，
                        // 占位卡（同结构）才能与之严格对齐——横向 ScrollView 里 LazyHStack 的
                        // 高度是按已实现的子视图算的，高度不齐的卡片会让矮的那张定下整条轨道的高度，
                        // 高出的部分被裁掉（实测：占位卡的日期行被裁成半行）。
                        .lineLimit(2, reservesSpace: true)
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
        // 分集简介做 tooltip：卡片本身放不下（宽度固定、标题已占两行），
        // 而简介是用户点开某一集前最想看的信息。macOS 上是悬停提示。
        .help(displayOverview ?? "")
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

// MARK: - 占位（库里没有的集）

/// 选集轨道里的占位卡：库里还没有这一集，但来源（TMDb 季数据 / Bangumi 章节）说它有。
///
/// **刻意不是 Button**：占位没有可播的条目，做成按钮就会出现「点了没反应」或者更糟的
/// 「点了进播放器然后失败」。所以它只是一个带 `.help` 的静态卡片，无障碍上也不带
/// `.isButton` trait——VoiceOver 不该给用户一个按不动的「按钮」。
///
/// 与 `EpisodeSelectCard` **同宽同高同结构**（图 + 集标 + 两行标题），这不是审美要求而是
/// 布局要求：横向 ScrollView 里 `LazyHStack` 的高度按已实现的子视图算，两种卡高度不一时，
/// 矮的那张会定下整条轨道的高度、高出的部分被直接裁掉（实测：日期行被裁成半行）。
/// 所以日期**画在图里**（左下角），文字块与本地卡严格同构。
struct EpisodePlaceholderCard: View {
    let placeholder: EpisodePlaceholder
    /// 已解析好的剧照取图目标：TMDb 的 `still_path` 优先，没有时是**剧集自己的横版图**
    /// （与首页「继续观看」同一条取图链，由 `DetailViewModel.placeholderThumbTarget` 决定）。
    let thumbTarget: (url: URL?, authHeader: String?)

    private var cardWidth: CGFloat { Metrics.episodeCardWidth }
    private var thumbHeight: CGFloat { Metrics.episodeThumbHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RemoteImage(url: thumbTarget.url, authHeader: thumbTarget.authHeader, maxPixelSize: 400)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: cardWidth, height: thumbHeight)
                    .clipped()

                // 底部渐隐：日期压在图上也要读得清（与本地卡那条进度轨的渐隐同款）。
                LinearGradient(
                    colors: [.black.opacity(0.62), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )

                Text(reasonText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(8)

                if let schedule = scheduleText {
                    Text(schedule)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: cardWidth, height: thumbHeight)
            .clipShape(.rect(cornerRadius: Metrics.episodeCardRadius))

            VStack(alignment: .leading, spacing: 2) {
                Text(placeholder.episodeLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(placeholder.displayTitle)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    // 与本地卡同一句：标题恒占两行，两种卡的高度因此严格相等。
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: cardWidth, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: cardWidth, alignment: .topLeading)
        // 与本地分集卡一致：简介做悬停提示（占位没有简介时说明为什么点不动）。
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var reasonText: String {
        switch placeholder.reason {
        case .notAired: "未播出"
        case .notInLibrary: "未入库"
        }
    }

    /// 日期：未播出 → 播出日期；未入库且日期已知 → 已播出日期；日期未知 → 不显示。
    private var scheduleText: String? {
        guard let airDate = placeholder.airDate else { return nil }
        let day = Self.dayText(airDate)
        return placeholder.reason == .notAired ? "\(day) 播出" : "\(day) 已播出"
    }

    /// 「MM-dd」。**不用 `DateFormatter` 静态实例**（Swift 6 下非 Sendable 的静态属性
    /// 过不了严格并发），也不用 `.formatted`：后者按地区把分隔符改成 `10/11` 或 `11.10`，
    /// 而这一行是固定格式的信息行，不该随语言环境变形。
    private static func dayText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }

    private var helpText: String {
        let overview = placeholder.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let overview, !overview.isEmpty { return overview }
        return placeholder.reason == .notAired ? "尚未播出" : "尚未入库，暂时无法播放"
    }

    private var accessibilityLabelText: String {
        var parts = [placeholder.episodeLabel, placeholder.displayTitle, reasonText]
        if let schedule = scheduleText { parts.append(schedule) }
        return parts.joined(separator: "，")
    }
}
