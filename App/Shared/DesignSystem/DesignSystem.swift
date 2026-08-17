import CoreModel
import JellyfinKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 尺寸 token（design/apple-native.html）

enum Metrics {
    static let posterWidth: CGFloat = 178      // 海报 2:3
    static let stillWidth: CGFloat = 328       // 剧照 16:9
    static let cardRadius: CGFloat = 10
    static let railSpacing: CGFloat = 22
    static let contentInset: CGFloat = 52

    /// iPhone 把横向留白压小；Mac / iPad 用设计稿的 52。
    @MainActor static var contentLeading: CGFloat {
        #if os(macOS)
        contentInset
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? contentInset : 22
        #endif
    }
}

// MARK: - 通用小组件

/// 时长格式：87 分钟 →「1 小时 27 分」；剧集分钟数 →「44 分钟」。
struct RuntimeText: View {
    let seconds: Double?

    var body: some View {
        if let seconds, seconds > 0 {
            Text(Self.format(seconds))
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        if total >= 60 {
            return "\(total / 60) 小时 \(total % 60) 分"
        }
        return "\(max(total, 1)) 分钟"
    }
}

// MARK: - MediaItem → 图片 URL（要服务器会话，所以放 App 层）

extension MediaItem {
    enum CardImage {
        case primary
        case thumb
        case backdrop
    }

    /// 带 `tag` 的图片地址（tag 让磁盘缓存自动失效）；`authHeader` 给 `RemoteImage` 用。
    func imageTarget(_ server: JellyfinServer?, kind: CardImage, width: Int)
        -> (url: URL?, authHeader: String?) {
        guard let server else { return (nil, nil) }
        let tag: String?
        let type: ItemImageType
        switch kind {
        case .primary: (tag, type) = (primaryImageTag, .primary)
        case .thumb: (tag, type) = (thumbImageTag, .thumb)
        case .backdrop: (tag, type) = (backdropImageTag, .backdrop)
        }
        let url = try? server.imageURL(itemID: id, type: type, maxWidth: width, tag: tag)
        return (url, server.authorizationHeader)
    }

    /// 分集缩略图：优先使用集自己的 Thumb / Primary 图。
    /// 没有分集图时保留中性占位，避免把剧集海报误认成某一集的剧照。
    func episodeThumbTarget(_ server: JellyfinServer?, width: Int)
        -> (url: URL?, authHeader: String?) {
        // Prefer the episode's own still. The parent series poster is deliberately
        // not used here: showing it beside an episode title looks like a wrong match.
        if thumbImageTag != nil {
            return imageTarget(server, kind: .thumb, width: width)
        }
        if primaryImageTag != nil {
            return imageTarget(server, kind: .primary, width: width)
        }
        // Keep a neutral placeholder when the episode has no image. A parent
        // series poster would imply that it belongs to this particular episode.
        return (nil, server?.authorizationHeader)
    }
}

// MARK: - 卡片

/// 海报卡（最近添加 / 媒体库网格）：2:3 + 标题行 + 年份。
struct PosterCard: View {
    let item: MediaItem
    let server: JellyfinServer?
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 9) {
                let target = item.imageTarget(server, kind: .primary, width: 400)
                RemoteImage(url: target.url, authHeader: target.authHeader)
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(width: Metrics.posterWidth)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                HStack {
                    Text(item.name)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if let year = item.year {
                        Text(String(year))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.footnote)
            }
            .frame(width: Metrics.posterWidth)
        }
        .buttonStyle(.plain)
        .hoverLift(active: hovering, reduceMotion: reduceMotion)
        .onHover { hovering = $0 }
    }
}

/// 继续观看卡：16:9 剧照 + 进度点 + 进度条 + 「还剩 xx」副标题。
struct StillCard: View {
    let item: MediaItem
    let server: JellyfinServer?
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var subtitle: String {
        if let label = item.episodeLabel {
            if let remaining = remaining, remaining > 0 {
                return "\(label) · 还剩 \(RuntimeText.format(remaining))"
            }
            return label
        }
        if let remaining, remaining > 0 {
            return "还剩 \(RuntimeText.format(remaining))"
        }
        return item.seriesName ?? item.genres.prefix(2).joined(separator: " / ")
    }

    private var remaining: Double? {
        item.runtimeSeconds.map { max($0 - (item.playState?.positionSeconds ?? 0), 0) }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    let target = item.episodeThumbTarget(server, width: 720)
                    RemoteImage(url: target.url, authHeader: target.authHeader)
                        .aspectRatio(16 / 9, contentMode: .fill)
                    LinearGradient(colors: [.black.opacity(0.62), .clear],
                                   startPoint: .bottom, endPoint: .center)
                    Image(systemName: "play.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        .padding(12)
                }
                .frame(width: Metrics.stillWidth)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))

                // 进度条是海报框的一部分：紧贴框底、与框同宽，作为一条收边，不叠在图片上。
                // 中性半透明色，深浅色模式下都自然融入卡片，不抢海报的调子。
                progressTrack
                    .frame(width: Metrics.stillWidth, height: 3)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 10)
            }
            .frame(width: Metrics.stillWidth)
        }
        .buttonStyle(.plain)
        .hoverLift(active: hovering, reduceMotion: reduceMotion)
        .onHover { hovering = $0 }
    }

    private var progressTrack: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12))
                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .clipShape(Capsule())
    }

    private var progress: Double {
        min(max(item.playState?.percentage ?? 0, 0), 1)
    }
}

// MARK: - 走马灯行

/// Apple TV 式横向滚动行。
struct Rail<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, Metrics.contentLeading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Metrics.railSpacing) {
                    content
                }
                .padding(.horizontal, Metrics.contentLeading)
                // 悬停放大（scale 1.055）+ 投影会溢出卡片原尺寸；给上下留呼吸空间，
                // 否则横向 ScrollView 会按内容高度裁掉放大/阴影的超出部分。
                .padding(.vertical, 28)
            }
        }
        .padding(.top, 24)
    }
}

// MARK: - 悬停抬升（设计稿 focus 态的桌面版：放大 + 投影，不画焦点环）

private struct HoverLift: ViewModifier {
    let active: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.1)) {
            content
                .scaleEffect(active && !reduceMotion ? 1.055 : 1)
                .shadow(color: .black.opacity(active ? 0.35 : 0), radius: active ? 10 : 0, y: 6)
        }
    }
}

extension View {
    func hoverLift(active: Bool, reduceMotion: Bool) -> some View {
        modifier(HoverLift(active: active, reduceMotion: reduceMotion))
    }
}
