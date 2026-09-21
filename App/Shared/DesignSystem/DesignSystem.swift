import AppDesignKit
import BangumiKit
import CoreModel
import JellyfinKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - App 层设计系统（域模型相关部分）
//
// 纯 UI 的 token / 骨架 / 控件 / 布局 / 远程图管道已下沉到 `AppDesignKit` 包
// （只吃纯值，不碰域模型）。本文件只留**绑 Jellyfin/Bangumi 域模型**的薄适配：
// PosterCard / StillCard（MediaItem + MediaServer）、ItemTitleLogoView、
// BangumiStatusColor。新 Feature 的卡片请用 AppDesignKit 的原语拼，不要抄这里的
// 域绑定实现另起炉灶。
//
// 播放器 HUD 是一套**独立的视觉语言**（`PlayerHUDPalette` + 玻璃面板组件），
// 刻意不使用这里的 `Metrics` / `contentLeading` / `cardRadius`：HUD 是浮在视频
// 上的半透明层，有自己的圆角体系（7/8/14/18/22）和调色板。两套系统各管各的，
// 不要在播放器 HUD 里套 `Metrics.cardRadius`。

// MARK: - Bangumi 状态色（跨页面共享）

/// Bangumi 收藏状态 / 条目类型的颜色映射。
///
/// 之前散落在三个文件里各写一份 switch，改一处忘另外两处是迟早的事。
/// 集中到设计系统里，所有 Bangumi 页面共用同一组色值。
enum BangumiStatusColor {
    /// 收藏状态色：想看 / 在看 / 看过 / 搁置 / 抛弃。
    static func collection(_ type: BangumiCollectionType) -> Color {
        switch type {
        case .none: return .secondary
        case .wish: return .purple
        case .collect: return .green
        case .doing: return .blue
        case .onHold: return .orange
        case .dropped: return .gray
        }
    }

    /// 条目类型色：动画 / 书籍 / 音乐 / 游戏 / 三次元。
    static func subject(_ type: BangumiSubjectType) -> Color {
        switch type {
        case .none: return .gray
        case .anime: return .blue
        case .book: return .green
        case .music: return .pink
        case .game: return .purple
        case .real: return .orange
        }
    }

    /// 评分色。全站统一用橙色——之前详情页用 `.yellow`、Bangumi 用 `.orange`，
    /// 现在统一成橙色，和 Bangumi 官方评分色一致。
    static let rating: Color = .orange
}

// MARK: - MediaItem → 图片 URL（要服务器会话，所以放 App 层）

extension MediaItem {
    enum CardImage {
        case primary
        case thumb
        case backdrop
        case logo
    }

    /// 带 `tag` 的图片地址（tag 让磁盘缓存自动失效）；`authHeader` 给 `RemoteImage` 用。
    func imageTarget(_ server: (any MediaServer)?, kind: CardImage, width: Int)
        -> (url: URL?, authHeader: String?) {
        guard let server else { return (nil, nil) }
        let tag: String?
        let type: ItemImageType
        let targetItemID: String
        switch kind {
        case .primary:
            (tag, type, targetItemID) = (primaryImageTag, .primary, id)
        case .thumb:
            (tag, type, targetItemID) = (thumbImageTag, .thumb, id)
        case .backdrop:
            (tag, type, targetItemID) = (backdropImageTag, .backdrop, id)
        case .logo:
            (tag, type, targetItemID) = (logoImageTag, .logo, logoItemID)
        }
        let url = try? server.imageURL(itemID: targetItemID, type: type, maxWidth: width, tag: tag)
        return (url, server.authorizationHeader)
    }

    /// 分集缩略图：优先使用集自己的 Thumb / Primary 图。
    /// 没有分集图时保留中性占位，避免把剧集海报误认成某一集的剧照。
    func episodeThumbTarget(_ server: (any MediaServer)?, width: Int)
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

/// 条目标题 Logo / 文本标题视图：优先展示透明艺术字 ClearLogo，未配置或加载失败时优雅回退为文字标题。
struct ItemTitleLogoView: View {
    let item: MediaItem
    let server: (any MediaServer)?
    var maxHeight: CGFloat = 80
    var maxWidth: CGFloat = 420
    var fontSize: CGFloat = 28
    /// 紧凑布局（iPhone 详情页）把 logo/标题居中，常规布局左对齐。
    var centered: Bool = false
    /// 文本兜底色跟随外观（日间深字 / 夜间白字）。氛围布局没有压暗带兜底时开；
    /// 老横幅恒在暗色图上，保持白字默认。
    var adaptiveText: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var logoImage: PlatformImage?
    @State private var loadFailed = false
    @State private var loadedKey: String?

    init(
        item: MediaItem,
        server: (any MediaServer)?,
        maxHeight: CGFloat = 80,
        maxWidth: CGFloat = 420,
        fontSize: CGFloat = 28,
        centered: Bool = false,
        adaptiveText: Bool = false
    ) {
        self.item = item
        self.server = server
        self.maxHeight = maxHeight
        self.maxWidth = maxWidth
        self.fontSize = fontSize
        self.centered = centered
        self.adaptiveText = adaptiveText

        // 同步从内存缓存中探测：若已有位图缓存，首帧直接上图，0 毫秒闪烁
        if item.logoImageTag != nil, let server {
            let maxPixel = Int(max(maxWidth, maxHeight) * 2)
            let target = item.imageTarget(server, kind: .logo, width: maxPixel)
            if let url = target.url,
               let cached = ImagePipeline.shared.memoryCachedImage(
                   url: url,
                   authHeader: target.authHeader,
                   maxPixelSize: maxPixel
               ) {
                _logoImage = State(initialValue: cached)
                _loadedKey = State(initialValue: "\(item.id)#\(item.logoImageTag ?? "")")
            }
        }
    }

    private var imageFade: Animation? {
        reduceMotion ? nil : Motion.standard
    }

    var body: some View {
        Group {
            if let logoImage {
                Image(platform: logoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: centered ? .center : .leading)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                    .accessibilityLabel(item.name)
                    .transition(.section)
            } else if item.logoImageTag != nil && !loadFailed {
                // 已知有 Logo 且正在加载中（来自磁盘或网络）：展示骨架占位，避免先闪出文字标题
                SkeletonBlock(cornerRadius: 4)
                    .frame(width: min(maxWidth * 0.55, 180), height: min(maxHeight * 0.55, 28))
                    .skeletonShimmer()
                    .transition(.section)
            } else {
                // 未配置 Logo 或加载失败：展示标准文本标题
                Text(item.name)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(adaptiveText && colorScheme == .light ? Color.primary : .white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .transition(.section)
            }
        }
        .animation(imageFade, value: logoImage != nil)
        .task(id: "\(item.id)#\(item.logoImageTag ?? "")") {
            let key = "\(item.id)#\(item.logoImageTag ?? "")"
            guard item.logoImageTag != nil else {
                logoImage = nil
                loadFailed = false
                loadedKey = key
                return
            }
            if loadedKey == key, logoImage != nil {
                return
            }
            let maxPixel = Int(max(maxWidth, maxHeight) * 2)
            let target = item.imageTarget(server, kind: .logo, width: maxPixel)
            guard let url = target.url else {
                logoImage = nil
                loadFailed = true
                loadedKey = key
                return
            }
            if let cached = ImagePipeline.shared.memoryCachedImage(url: url, authHeader: target.authHeader, maxPixelSize: maxPixel) {
                logoImage = cached
                loadFailed = false
                loadedKey = key
                return
            }
            do {
                if let loaded = try await ImagePipeline.shared.load(url, authHeader: target.authHeader, maxPixelSize: maxPixel) {
                    guard !Task.isCancelled else { return }
                    logoImage = loaded
                    loadFailed = false
                    loadedKey = key
                } else {
                    loadFailed = true
                    loadedKey = key
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
                loadedKey = key
            }
        }
    }
}

// MARK: - 卡片

/// 海报卡（最近添加 / 媒体库网格）：2:3 + 标题行 + 年份。
struct PosterCard: View {
    let item: MediaItem
    let server: (any MediaServer)?
    var width: CGFloat? = Metrics.posterWidth
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        // 卡宽必须是确定值：width 传 nil（紧凑网格的自适应列）时也回落到默认海报宽，
        // 否则超长标题会把标题行撑得比海报还宽，挤乱横向 Rail 和网格。
        let cardWidth = width ?? Metrics.posterWidth
        return Button(action: onTap) {
            VStack(alignment: .leading, spacing: 9) {
                let target = item.imageTarget(server, kind: .primary, width: 400)
                MediaArtwork(
                    url: target.url,
                    authHeader: target.authHeader,
                    shape: .poster,
                    width: cardWidth,
                    maxPixelSize: 400
                )
                HStack {
                    Text(item.name)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if let year = item.year {
                        Text(String(year))
                            .monospacedDigit()
                            .layoutPriority(1)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.footnote)
            }
            .frame(width: cardWidth)
        }
        .buttonStyle(.plain)
        .hoverLift(active: hovering, reduceMotion: reduceMotion)
        .onHover { hovering = $0 }
    }
}

/// 继续观看卡：16:9 剧照 + 进度点 + 进度条 + 「还剩 xx」副标题。
struct StillCard: View {
    let item: MediaItem
    let server: (any MediaServer)?
    let actionIcon: String
    let actionAccessibilityLabel: String?
    var width: CGFloat = Metrics.stillWidth
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(
        item: MediaItem,
        server: (any MediaServer)?,
        actionIcon: String = "play.fill",
        actionAccessibilityLabel: String? = nil,
        width: CGFloat = Metrics.stillWidth,
        onTap: @escaping () -> Void
    ) {
        self.item = item
        self.server = server
        self.actionIcon = actionIcon
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.width = width
        self.onTap = onTap
    }

    private var title: String {
        if let seriesName = item.seriesName, !seriesName.isEmpty {
            if item.name.isEmpty || item.name == seriesName || item.name.contains(seriesName) {
                return item.name.isEmpty ? seriesName : item.name
            }
            return "\(seriesName) · \(item.name)"
        }
        return item.name
    }

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

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                let target = item.episodeThumbTarget(server, width: 720)
                MediaArtwork(
                    url: target.url,
                    authHeader: target.authHeader,
                    shape: .still,
                    width: width,
                    maxPixelSize: 720
                ) {
                    ZStack(alignment: .bottomLeading) {
                        // 底部只做很轻的可读性压暗；不再为常驻按钮铺厚渐变。
                        LinearGradient(
                            colors: [.black.opacity(hovering || voiceOverEnabled ? 0.45 : 0.22), .clear],
                            startPoint: .bottom,
                            endPoint: .center
                        )
                        // 整卡可点时，角标只是 affordance：悬停/VoiceOver 才出现，避免压住剧照。
                        actionBadge
                            // 略离开海报圆角与底边，避免贴边。
                            .padding(18)
                            .opacity(actionBadgeVisible ? 1 : 0)
                            .scaleEffect(actionBadgeVisible ? 1 : 0.92)
                            .animation(badgeMotion, value: actionBadgeVisible)
                            .accessibilityHidden(true)
                    }
                }

                // 进度条是海报框的一部分：紧贴框底、与框同宽，作为一条收边，不叠在图片上。
                // 中性半透明色，深浅色模式下都自然融入卡片，不抢海报的调子。
                CardProgressTrack(fraction: progress, width: width)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 10)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(actionAccessibilityLabel ?? "播放 \(title)")
        .accessibilityValue("\(subtitle)，已播放 \(Int(progress * 100))%")
        .hoverLift(active: hovering, reduceMotion: reduceMotion)
        .onHover { hovering = $0 }
    }

    /// 悬停或读屏时显示；减弱动态效果时仍显示，避免只靠动画提示可点。
    private var actionBadgeVisible: Bool {
        hovering || voiceOverEnabled || reduceMotion
    }

    private var badgeMotion: Animation? {
        reduceMotion ? nil : Motion.fast
    }

    private var actionBadge: some View {
        Image(systemName: actionIcon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial.opacity(0.92), in: Circle())
            .background(Circle().fill(.black.opacity(0.28)))
            .overlay {
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private var progress: Double {
        min(max(item.playState?.percentage ?? 0, 0), 1)
    }
}
