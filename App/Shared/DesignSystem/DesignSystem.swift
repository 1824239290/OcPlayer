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
    ///
    /// **没有 tag 就不发请求**（返回 nil url）。服务端返回的 `ImageTags` 就是「这个条目
    /// 有没有这张图」的事实来源：Jellyfin/Emby 的列表与详情响应都会带上它，缺键 =
    /// 本来就没图。以前这里照样拼 URL，于是每个无图条目（手工建的**合集**、没头像的
    /// 演员、缺海报的老片）都白打一次 404 —— 实测日志里已累计十几条，而 `RemoteImage`
    /// 拿到 404 后显示的仍是同一块占位，**除了浪费一次请求没有任何差别**。
    /// 合集是这条规则的最大受益者：Jellyfin 新建的合集默认不带任何图，页面上每渲染
    /// 一次就 404 一次（同一会话里反复出现，见 `图片请求返回非 200` 日志）。
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
        guard tag != nil else { return (nil, server.authorizationHeader) }
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

    /// 首页「继续播放 / 接下来看」剧照卡：Jellyfin Web 同款取图链
    /// （`MediaItem.homeStillImageChoice`，横版 Thumb/Backdrop 优先）。
    /// 详情页分集列表仍走 `episodeThumbTarget` —— 那里展示父级图会像串了集。
    func homeStillImageTarget(_ server: (any MediaServer)?, width: Int)
        -> (url: URL?, authHeader: String?) {
        guard let server, let choice = homeStillImageChoice else {
            return (nil, server?.authorizationHeader)
        }
        let type: ItemImageType
        switch choice.kind {
        case .primary: type = .primary
        case .thumb: type = .thumb
        case .backdrop: type = .backdrop
        }
        let url = try? server.imageURL(itemID: choice.itemID, type: type, maxWidth: width, tag: choice.tag)
        return (url, server.authorizationHeader)
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

/// 海报卡（最近添加 / 媒体库网格）：图区（**比例跟随图片**）+ 标题区 + 年份。
///
/// **卡宽两档语义**（`width`，与 `MediaArtwork.width` 同口径）：
/// - **给定值**＝定宽卡（Rail、常规宽度网格），宽度写死、超长标题撑不宽它；
///   标题与年份同一行、左对齐。
/// - **nil**＝跟随所在网格的**列宽**（紧凑端海报墙，见 `PosterGrid`）；此时标题区
///   换成**两行居中**（标题一行、年份一行）。手机上单卡只有 110pt 出头，标题和
///   年份挤一行会双双被截断——Rex 的媒体库也是这个版式（截图像素实测：标题
///   与所在卡左右居中对齐、年份在其下一行更小更淡）。
///
/// 注意这个 `nil` 以前是「回落 178pt 定宽」：紧凑网格传 nil 本意是跟随列宽，
/// 实际却按 178 画，比列宽还宽 6pt，卡片两侧各溢出 3pt（卡缝从 14pt 缩成 8pt）。
/// 语义改成跟随列宽后，Rail 那几处必须显式给宽度（那正是「定宽卡」的意思）。
struct PosterCard: View {
    let item: MediaItem
    let server: (any MediaServer)?
    var width: CGFloat? = Metrics.posterWidth
    /// 封面覆盖：条目自身没有服务端图时外部补一张（当前唯一来源是**合集的 TMDb 海报**）。
    /// nil = 用条目自己的图（`imageTarget` 那条既有链）。
    ///
    /// 为什么要开这个口子：合集在服务端**本来就没有图**（实测 `ImageTags: {}`），
    /// 卡片只剩占位图标；而 TMDb 合集的海报要经一次解析才有（见
    /// `AppModel.collectionPosterURL`）。把「取哪张图」留给调用方，卡片本身不必知道
    /// TMDb 的存在。
    var posterOverride: URL? = nil

    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// 跟随列宽＝紧凑海报墙版式（两行居中标题区），见类型注释。
    private var fillsColumn: Bool { width == nil }

    var body: some View {
        return Button(action: onTap) {
            VStack(alignment: fillsColumn ? .center : .leading, spacing: fillsColumn ? 6 : 9) {
                let serverTarget = item.imageTarget(server, kind: .primary, width: 400)
                // 覆盖图优先，但它**免鉴权**（TMDb CDN 不校验）：带上服务端凭证
                // 既无意义、也把凭证多送一处。
                let url = posterOverride ?? serverTarget.url
                MediaArtwork(
                    url: url,
                    authHeader: posterOverride == nil ? serverTarget.authHeader : nil,
                    shape: .poster,
                    width: width,
                    // 解码预算不写死：按卡片实际显示尺寸 × 屏幕缩放算（见 MediaArtwork）。
                    // 合集在服务端不带图是常态（新建的合集默认没有封面），
                    // 给它一个「一叠海报」的图标，别显示成一张破图。
                    emptyIcon: item.kind == .boxSet ? "rectangle.stack.fill" : "photo",
                    // 边框跟着**这张图自己的比例**走（服务端 `PrimaryImageAspectRatio`）：
                    // 不同剧集的海报 0.667 / 0.70 / 0.75 都有，写死 2:3 就会裁或留边。
                    aspectRatio: item.primaryImageAspectRatio.map { CGFloat($0) }
                )
                if fillsColumn {
                    columnMeta
                } else {
                    inlineMeta
                }
            }
            // 定宽卡锁住宽度（超长标题不许把卡撑得比海报还宽）；跟随列宽时不锁，
            // 卡自己吃满网格列（图区把列宽接过来，标题区再按它居中）。
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .hoverLift(active: hovering, reduceMotion: reduceMotion)
        .onHover { hovering = $0 }
    }

    /// 紧凑海报墙（跟随列宽）的标题区：标题一行、年份一行，整体居中。
    /// 标题独占一行才装得下 Rex 那种 7–8 字的剧名（`lineLimit(1)` 超出截尾）。
    private var columnMeta: some View {
        VStack(spacing: 2) {
            Text(item.name)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let year = item.year {
                Text(String(year))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Rail / 常规宽度网格的标题区：标题左、年份右，同一行（原样）。
    private var inlineMeta: some View {
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
}

/// 媒体库类型的中文名。
extension MediaLibrary.CollectionType {
    var displayName: String {
        switch self {
        case .movies: "电影"
        case .tvshows: "剧集"
        case .music: "音乐"
        case .musicvideos: "MV"
        case .homevideos: "家庭视频"
        case .boxsets: "合集"
        case .books: "书籍"
        case .photos: "照片"
        case .playlists: "播放列表"
        case .livetv: "直播电视"
        case .folders, .unknown: "混合内容"
        }
    }
}

/// 媒体库卡（首页媒体库栏）：16:9 库封面 + 标题行 + 类型副标题。
/// 布局对齐 `StillCard`（封面取 Jellyfin/Emby UserView 自己的 Primary 图，
/// 带 tag 供缓存失效），Rail 走 `.still` 档高度。
///
/// 服务端**没给库封面**时（合集库是必然：实测 7 种图片类型全部 404）用 `collageURLs`
/// 里的内容海报拼一张 2×2；拼不出来才落回占位图标。
struct LibraryCard: View {
    let library: MediaLibrary
    let server: (any MediaServer)?
    /// 内容海报（最多 4 张）：服务端没给库封面时用它拼图，见
    /// `AppModel.libraryCoverURLs(for:)`。
    var collageURLs: [URL] = []
    var width: CGFloat = Metrics.stillWidth
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var coverTarget: (url: URL?, authHeader: String?) {
        guard let server, library.primaryImageTag != nil else { return (nil, nil) }
        let url = try? server.imageURL(
            itemID: library.id, type: .primary, maxWidth: 720, tag: library.primaryImageTag)
        return (url, server.authorizationHeader)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                let target = coverTarget
                if target.url == nil, !collageURLs.isEmpty {
                    LibraryCoverCollage(
                        urls: Array(collageURLs.prefix(4)),
                        authHeader: server?.authorizationHeader,
                        width: width)
                } else {
                    MediaArtwork(
                        url: target.url,
                        authHeader: target.authHeader,
                        shape: .still,
                        width: width,
                        // 合集库（UserView 的 CollectionType = boxsets）在服务端没有封面图
                        // ——实测 `/UserViews` 里它是 `ImageTags: {}`，以前照样拼 URL、每渲染
                        // 一次就 404 一次（跨会话在日志里反复出现），显示的却是同一张灰底。
                        emptyIcon: library.collectionType == .boxsets ? "rectangle.stack.fill" : "photo"
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(library.collectionType.displayName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 10)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开媒体库 \(library.name)")
        .hoverLift(active: hovering, reduceMotion: reduceMotion)
        .onHover { hovering = $0 }
    }
}

/// 库卡封面拼图：把库里的内容海报拼成一张 16:9 的图。
///
/// 存在的理由：服务端对某些库**一张图都没有**（合集库实测 7 种图片类型全 404），
/// 而库卡空着会让人以为这个库是坏的。1 张铺满、2 张并排、3 张上二下一、4 张 2×2——
/// 每格都 `scaledToFill` + 裁切，所以任何张数都恰好填满、不留缝也不变形。
private struct LibraryCoverCollage: View {
    let urls: [URL]
    let authHeader: String?
    let width: CGFloat

    private var height: CGFloat { width * 9.0 / 16.0 }

    var body: some View {
        Group {
            switch urls.count {
            case 0:
                Rectangle().fill(Metrics.placeholderFill)
            case 1:
                cell(urls[0]).frame(width: width, height: height)
            case 2:
                HStack(spacing: 0) {
                    cell(urls[0])
                    cell(urls[1])
                }
                .frame(width: width, height: height)
            case 3:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        cell(urls[0])
                        cell(urls[1])
                    }
                    cell(urls[2]).frame(height: height / 2)
                }
                .frame(width: width, height: height)
            default:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        cell(urls[0])
                        cell(urls[1])
                    }
                    HStack(spacing: 0) {
                        cell(urls[2])
                        cell(urls[3])
                    }
                }
                .frame(width: width, height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    /// 一格。宽高都由外层 HStack / VStack 定，图**铺满裁切**（`.fill`——拼图必须
    /// 不留缝，这里刻意不用卡片默认的 `.fit`）。解码预算按格子实际尺寸算：格宽固定，
    /// 但长边是「撑满后的宽」，按 `width` 的两倍给足以覆盖 2×2 的每一格。
    private func cell(_ url: URL) -> some View {
        RemoteImage(
            url: url,
            authHeader: authHeader,
            maxPixelSize: Int(width * 2),
            scaling: .fill
        )
        .clipped()
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
                let target = item.homeStillImageTarget(server, width: 720)
                MediaArtwork(
                    url: target.url,
                    authHeader: target.authHeader,
                    shape: .still,
                    width: width
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
