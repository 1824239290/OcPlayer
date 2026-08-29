import BangumiKit
import CoreModel
import JellyfinKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 动画帮手

/// 本文件定义内容页的设计系统：间距 token、横向留白、卡片组件、骨架屏、文案常量。
///
/// 播放器 HUD 是一套**独立的视觉语言**（`PlayerHUDPalette` + 玻璃面板组件），
/// 刻意不使用这里的 `Metrics` / `contentLeading` / `cardRadius`：HUD 是浮在视频
/// 上的半透明层，有自己的圆角体系（7/8/14/18/22）和调色板。两套系统各管各的，
/// 不要在播放器 HUD 里套 `Metrics.cardRadius`。
extension View {
    /// 与 `.animation(_:value:)` 同义，但把 `accessibilityReduceMotion` 收进来：
    /// 减弱动态效果时传 nil（SwiftUI 视作无动画、立即切换）。
    /// 用法：`.motionAnimation(.easeInOut(duration: 0.2), value: foo, reduceMotion: reduceMotion)`
    func motionAnimation<V: Equatable>(
        _ animation: Animation,
        value: V,
        reduceMotion: Bool
    ) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - 尺寸 token（design/apple-native.html）

enum Metrics {
    static let posterWidth: CGFloat = 178      // 海报 2:3
    static let stillWidth: CGFloat = 328       // 剧照 16:9
    /// 紧凑布局（iPhone 竖屏 / iPad 分屏窄窗）的卡片宽度。
    static let compactPosterWidth: CGFloat = 120
    static let compactStillWidth: CGFloat = 240
    static let cardRadius: CGFloat = 10
    /// 选集卡圆角。比 `cardRadius` 略小，选集卡在详情页里尺寸更小、更密集，
    /// 和海报/剧照卡用同一个圆角会显得偏圆。`EpisodeSelectCard` 与 `SkeletonEpisodeStrip` 共用。
    static let episodeCardRadius: CGFloat = 8
    static let railSpacing: CGFloat = 22
    static let contentInset: CGFloat = 52
    /// 紧凑宽度（iPhone、iPad 分屏窄窗）的横向留白。
    static let compactContentInset: CGFloat = 22
    /// Rail 横向 ScrollView 上下为悬停放大预留的内边距（上下各一档）。
    static let railHoverPadding: CGFloat = 28

    /// 详情页横幅高度与横幅内主操作行高。真实内容和骨架共用同一组常量，
    /// 免得改了一边忘了另一边、骨架撤掉时横幅高度跳一下。
    static let bannerHeight: CGFloat = 320
    static let bannerActionHeight: CGFloat = 40

    /// 详情页横向选集卡尺寸（`EpisodeSelectCard` 与它的骨架共用）。
    static let episodeCardWidth: CGFloat = 200
    static let episodeThumbHeight: CGFloat = 112

    /// 海报卡（图 2:3 + 标题行）在 Rail 里的可视高度，含 hover 留白。
    static func posterRailHeight(compact: Bool = false) -> CGFloat {
        let w = compact ? compactPosterWidth : posterWidth
        return w * 1.5 + 9 + 22 + railHoverPadding * 2
    }

    /// 剧照卡（16:9 + 进度条 + 两行文案）在 Rail 里的可视高度，含 hover 留白。
    static func stillRailHeight(compact: Bool = false) -> CGFloat {
        let w = compact ? compactStillWidth : stillWidth
        return w * 9 / 16 + 6 + 3 + 10 + 40 + railHoverPadding * 2
    }

    /// 加载占位的统一灰。骨架块和 `RemoteImage` 的图片占位都用它——
    /// 两边取值不同的话，骨架撤掉换成真实卡片、而图还在下载的那一瞬间，
    /// 整墙灰块会明显「变深一档」。
    static let placeholderTint: Double = 0.08
    static var placeholderFill: Color { Color.primary.opacity(placeholderTint) }
}

// MARK: - 横向留白（跟窗口宽度走，不跟设备型号走）

private struct ContentLeadingKey: EnvironmentKey {
    static let defaultValue: CGFloat = Metrics.contentInset
}

extension EnvironmentValues {
    /// 页面横向留白，由 `AppShellView` 按 `horizontalSizeClass` 注入。
    ///
    /// **不能用 `UIDevice.current.userInterfaceIdiom` 判断**：那是设备属性而不是窗口属性。
    /// iPad 拖到 1/3 宽时 `horizontalSizeClass` 已经是 `.compact`，但 idiom 仍然是 `.pad`，
    /// 于是窄窗里左右各留 52pt——内容区只剩 216pt，一张 178pt 的海报都排不出第二列。
    var contentLeading: CGFloat {
        get { self[ContentLeadingKey.self] }
        set { self[ContentLeadingKey.self] = newValue }
    }
}

// MARK: - 通用小组件

/// 骨架屏的单一灰色圆角块。数据加载中用它占位，和真实内容同尺寸，
/// 加载完原位替换 → 不闪、不跳。微光相位从环境读（`skeletonShimmer()` 注入），
/// 整页骨架共享同一条扫过亮带。
///
/// 亮带的实现有两处刻意的选择：
/// - **裁剪走外层 `clipShape`**：`.overlay` 贴的是 view 的 *frame*，不是圆角路径，
///   不裁的话亮带会从圆角外那块透明区域漏出来。
/// - **位移走 `visualEffect` 而不是 `GeometryReader`**：一墙骨架有几十个块
///   （macOS 媒体库首屏 24 张卡 × 2 块），每块塞一个测量器就是几十轮布局往返；
///   `visualEffect` 在渲染期拿几何，不进布局。
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Metrics.cardRadius

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.skeletonPhase) private var phase

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(Metrics.placeholderFill)
            .overlay {
                if let phase, !reduceMotion {
                    shimmerBand(phase: phase)
                }
            }
            .clipShape(shape)
    }

    /// 一条横向渐隐的亮带，从块的左外侧扫到右外侧。
    ///
    /// 渐变必须沿 `.leading → .trailing`：原来写的是 `.top → .bottom`，
    /// 亮带就变成竖向渐隐 + 横向两条硬切边，扫过时看到的是硬边矩形在滑。
    private func shimmerBand(phase: CGFloat) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, highlight, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .visualEffect { content, proxy in
                content.offset(x: proxy.size.width * (2 * phase - 1))
            }
            .allowsHitTesting(false)
    }

    /// 亮带强度按主题分开给，不能两边共用一个值。
    ///
    /// 底色是 `primary.opacity(0.08)`：浅色下它是「白底上的浅灰」（≈#EBEBEB），
    /// 离白只有 20 级，亮带给多了也提不上去；深色下它是「黑底上的深灰」（≈#141414），
    /// 同样一档白透明度在这里的色差要大得多。
    /// 原来两边共用 `white.opacity(0.18)`，浅色下只有 5 级色差、深色下有 40 级——
    /// 同一段代码在两个主题下一个「看不出在动」、一个「明显在动」。
    private var highlight: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.55)
    }
}

/// 骨架屏动画驱动器：包住骨架布局，让子块共享一个循环扫过的 phase。
/// 减弱动态效果时不播。
///
/// 顺带把整块骨架对读屏收成一句「正在加载」——骨架里全是 `Shape`，
/// 而 Shape 不是无障碍元素，不加这一层的话 VoiceOver 在加载态下**什么都读不到**
/// （改成骨架之前这里是 `ProgressView` + 文案，是能读出来的）。
struct SkeletonShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.skeletonPhase, reduceMotion ? nil : phase)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在加载…")
            .accessibilityAddTraits(.updatesFrequently)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private struct SkeletonPhaseKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var skeletonPhase: CGFloat? {
        get { self[SkeletonPhaseKey.self] }
        set { self[SkeletonPhaseKey.self] = newValue }
    }
}

extension View {
    /// 骨架屏外层容器：子 `SkeletonBlock` 自动共享同一 shimmer 相位。
    func skeletonShimmer() -> some View {
        modifier(SkeletonShimmer())
    }
}

/// 骨架海报卡：2:3 图块 + 标题条，和 `PosterCard` 同尺寸。
struct SkeletonPosterCard: View {
    var width: CGFloat? = Metrics.posterWidth

    var body: some View {
        let cardWidth = width ?? Metrics.posterWidth
        VStack(alignment: .leading, spacing: 9) {
            SkeletonBlock()
                .frame(width: cardWidth, height: cardWidth * 1.5)
            SkeletonBlock(cornerRadius: 4)
                .frame(width: cardWidth * 0.7, height: 12)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 骨架剧照卡：16:9 图块 + 两行文案条，和 `StillCard` 同尺寸。
struct SkeletonStillCard: View {
    var width: CGFloat = Metrics.stillWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock()
                .frame(width: width, height: width * 9 / 16)
            SkeletonBlock(cornerRadius: 4)
                .frame(width: width * 0.55, height: 12)
            SkeletonBlock(cornerRadius: 4)
                .frame(width: width * 0.35, height: 10)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 骨架横向 Rail：标题 + 一排同尺寸骨架卡，和真实 `Rail` 布局一致。
///
/// 间距 / 上边距必须跟 `Rail` 完全对齐（`spacing: 14`、`.padding(.top, 24)`），
/// 否则骨架撤掉的瞬间每条 Rail 都会错开几 pt——那正好是骨架屏要消掉的东西。
struct SkeletonRail: View {
    let title: String
    let kind: RailKind

    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }

    enum RailKind {
        case poster   // 2:3 海报卡
        case still    // 16:9 剧照卡
    }

    private var cardCount: Int {
        #if os(iOS)
        return 3
        #else
        return 5
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题位用真实文案垫宽（`.hidden()` 只占位不绘制），灰条盖在它上面：
            // 比写死一个宽度更贴合真实标题的行宽与基线。
            Text(title)
                .font(.title3.weight(.bold))
                .hidden()
                .overlay {
                    SkeletonBlock(cornerRadius: 4)
                        .padding(.vertical, 3)
                }
                .padding(.horizontal, contentLeading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.railSpacing) {
                    ForEach(0..<cardCount, id: \.self) { _ in
                        switch kind {
                        case .poster: SkeletonPosterCard(width: isCompact ? Metrics.compactPosterWidth : nil)
                        case .still: SkeletonStillCard(width: isCompact ? Metrics.compactStillWidth : Metrics.stillWidth)
                        }
                    }
                }
                .padding(.horizontal, contentLeading)
                .padding(.vertical, Metrics.railHoverPadding)
            }
            .frame(height: skeletonHeight)
            // 骨架不该比真实内容更能滚：真实 Rail 卡片铺不满时也是不滚的。
            .scrollDisabled(true)
        }
        .padding(.top, 24)
    }

    /// 卡片区可视高度：和真实 Rail 的 scrollHeight 对齐，避免骨架与内容间跳动。
    private var skeletonHeight: CGFloat {
        switch kind {
        case .poster: Metrics.posterRailHeight(compact: isCompact)
        case .still: Metrics.stillRailHeight(compact: isCompact)
        }
    }
}

/// 选集横向条的骨架：一排和 `EpisodeSelectCard` 同尺寸的占位卡。
/// 详情页首屏骨架和「切季重新拉集」共用这一份（原来是复制粘贴的两份，
/// 各自还带着同一个凑出来的高度魔法数）。
///
/// 不锁总高度：真实选集条（`HoverArrowHScroll`，`fixedHeight` 为 nil）也是自适应的，
/// 这里按同样的结构堆出来让它自己算，就不会有「骨架 164、内容 187」这种对不上的常数。
struct SkeletonEpisodeStrip: View {
    var cardCount: Int = 6

    @Environment(\.contentLeading) private var contentLeading

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<cardCount, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(cornerRadius: Metrics.episodeCardRadius)
                            .frame(
                                width: Metrics.episodeCardWidth,
                                height: Metrics.episodeThumbHeight
                            )
                        // 与 EpisodeSelectCard 的「集号 + 标题」两行同结构（spacing 2）
                        VStack(alignment: .leading, spacing: 2) {
                            SkeletonBlock(cornerRadius: 3)
                                .frame(width: 54, height: 11)
                            SkeletonBlock(cornerRadius: 3)
                                .frame(width: 150, height: 13)
                        }
                    }
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.vertical, 10)
        }
        .scrollDisabled(true)
    }
}

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

/// 跨页面高频复用的中文文案集中定义。
///
/// 不建 .xcstrings：自用单语、字面量隐式走 LocalizedStringKey，catalog 只分离
/// 语言文件与代码、无实际收益还带几十文件级联 diff（见 REVIEW_TODO）。这里只收
/// 真正跨文件重复的文案（加载失败 / 重试 / 空态），一次性按钮文字留在原地。
enum UIStrings {
    /// 通用「加载失败」标题（各页 ContentUnavailableView 统一）。
    static let loadFailed = "加载失败"
    /// 通用「重试」按钮。
    static let retry = "重试"
    /// 通用「搜索失败」标题（搜索结果为空但出错时）。
    static let searchFailed = "搜索失败"
    /// 通用「加载更多」按钮（分页列表底部）。
    static let loadMore = "加载更多"
}

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
    func imageTarget(_ server: JellyfinServer?, kind: CardImage, width: Int)
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

/// 条目标题 Logo / 文本标题视图：优先展示透明艺术字 ClearLogo，未配置或加载失败时优雅回退为文字标题。
struct ItemTitleLogoView: View {
    let item: MediaItem
    let server: JellyfinServer?
    var maxHeight: CGFloat = 80
    var maxWidth: CGFloat = 420
    var fontSize: CGFloat = 28
    /// 紧凑布局（iPhone 详情页）把 logo/标题居中，常规布局左对齐。
    var centered: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoImage: PlatformImage?
    @State private var loadFailed = false
    @State private var loadedKey: String?

    init(
        item: MediaItem,
        server: JellyfinServer?,
        maxHeight: CGFloat = 80,
        maxWidth: CGFloat = 420,
        fontSize: CGFloat = 28,
        centered: Bool = false
    ) {
        self.item = item
        self.server = server
        self.maxHeight = maxHeight
        self.maxWidth = maxWidth
        self.fontSize = fontSize
        self.centered = centered

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
        reduceMotion ? nil : .easeInOut(duration: 0.2)
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
                    .transition(.opacity)
            } else if item.logoImageTag != nil && !loadFailed {
                // 已知有 Logo 且正在加载中（来自磁盘或网络）：展示骨架占位，避免先闪出文字标题
                SkeletonBlock(cornerRadius: 4)
                    .frame(width: min(maxWidth * 0.55, 180), height: min(maxHeight * 0.55, 28))
                    .skeletonShimmer()
                    .transition(.opacity)
            } else {
                // 未配置 Logo 或加载失败：展示标准文本标题
                Text(item.name)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .transition(.opacity)
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
    let server: JellyfinServer?
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
                RemoteImage(url: target.url, authHeader: target.authHeader, maxPixelSize: 400)
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(width: cardWidth, height: cardWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
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
    let server: JellyfinServer?
    let actionIcon: String
    let actionAccessibilityLabel: String?
    var width: CGFloat = Metrics.stillWidth
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(
        item: MediaItem,
        server: JellyfinServer?,
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
                ZStack(alignment: .bottomLeading) {
                    let target = item.episodeThumbTarget(server, width: 720)
                    RemoteImage(url: target.url, authHeader: target.authHeader, maxPixelSize: 720)
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
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
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))

                // 进度条是海报框的一部分：紧贴框底、与框同宽，作为一条收边，不叠在图片上。
                // 中性半透明色，深浅色模式下都自然融入卡片，不抢海报的调子。
                progressTrack
                    .frame(width: width, height: 3)
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
        reduceMotion ? nil : .easeOut(duration: 0.16)
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

    /// 轨道宽度是定死的 `Metrics.stillWidth`，所以直接乘比例，不用 `GeometryReader`——
    /// 每张卡塞一个 GeometryReader 会在横向 LazyHStack 里多出一轮布局往返，
    /// 而它测出来的就是我们已经知道的那个常量。
    private var progressTrack: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.12))
            Rectangle()
                .fill(Color.primary.opacity(0.6))
                .frame(width: width * progress)
        }
        .clipShape(Capsule())
    }

    private var progress: Double {
        min(max(item.playState?.percentage ?? 0, 0), 1)
    }
}

// MARK: - 横向滚动（悬停箭头）

/// 横向懒加载列表 + 两侧悬浮箭头。
/// 箭头仅在鼠标进入轨道时淡入（VoiceOver 开启时始终可操作），
/// 状态只有一个 `Bool`，不跟滚动 offset，几乎不吃性能。
struct HoverArrowHScroll<Item: Identifiable, ItemContent: View>: View {
    let items: [Item]
    var scrollStep: Int = 3
    /// 页面横向留白。调用方从 `\.contentLeading` 环境值取，随窗口宽度变化。
    var contentLeading: CGFloat = Metrics.contentInset
    /// 列表左右额外内边距，给悬浮箭头留点击空隙。
    var edgeReserve: CGFloat = 28
    var verticalPadding: CGFloat = Metrics.railHoverPadding
    /// 箭头相对垂直居中的偏移（负值上移，正值下移）。
    var arrowYOffset: CGFloat = 0
    var fixedHeight: CGFloat? = nil
    /// 选中/外部驱动时滚到该 id（如详情选集）。
    var scrollToID: Item.ID? = nil
    var onScrollFocusChange: ((Item.ID) -> Void)? = nil
    @ViewBuilder var itemContent: (Item) -> ItemContent

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var focusID: Item.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.railSpacing) {
                        ForEach(items) { item in
                            itemContent(item)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, contentLeading)
                    .padding(.vertical, verticalPadding)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                if showsArrowChrome {
                    HStack {
                        railArrow(
                            systemImage: "chevron.left",
                            enabled: canScroll(by: -scrollStep),
                            label: "向前滚动"
                        ) {
                            scroll(by: -scrollStep, proxy: proxy)
                        }
                        Spacer(minLength: 0)
                        railArrow(
                            systemImage: "chevron.right",
                            enabled: canScroll(by: scrollStep),
                            label: "向后滚动"
                        ) {
                            scroll(by: scrollStep, proxy: proxy)
                        }
                    }
                    .padding(.horizontal, max(contentLeading - 8, 12))
                    .offset(y: arrowYOffset)
                    .opacity(arrowsVisible ? 1 : 0)
                    .allowsHitTesting(arrowsVisible)
                    .animation(arrowAnimation, value: arrowsVisible)
                    // 不跟 enabled 做隐式动画，避免点到尽头时整组闪一下。
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(OptionalHeight(fixedHeight))
            .onHover { isHovering = $0 }
            .onAppear {
                reconcileFocus()
                if let target = focusID {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: itemsIdentity) { _, _ in
                reconcileFocus()
            }
            .onChange(of: scrollToID) { _, newID in
                guard let newID, items.contains(where: { $0.id == newID }) else { return }
                focusID = newID
                withAnimation(scrollAnimation) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var showsArrowChrome: Bool { items.count > 1 }

    /// 集合身份摘要，给 `onChange` 当比较值用。
    /// 原来写的是 `items.map(\.id)`：每次 body 重算（悬停进出就会重算）都新分配一个
    /// id 数组。摘要只遍历不分配，灵敏度一样——换季时哪怕集数相同，id 也不同。
    /// 万一撞哈希最坏结果只是少一次滚动锚点校准，不影响正确性。
    private var itemsIdentity: Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items { hasher.combine(item.id) }
        return hasher.finalize()
    }

    /// 鼠标在轨道上，或 VoiceOver 需要始终可点到箭头。
    private var arrowsVisible: Bool {
        showsArrowChrome && (isHovering || voiceOverEnabled)
    }

    private var arrowAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    private var scrollAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private func railArrow(
        systemImage: String,
        enabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .help(label)
    }

    private var anchorID: Item.ID? {
        if let focusID, items.contains(where: { $0.id == focusID }) {
            return focusID
        }
        if let scrollToID, items.contains(where: { $0.id == scrollToID }) {
            return scrollToID
        }
        return items.first?.id
    }

    private func reconcileFocus() {
        if let focusID, items.contains(where: { $0.id == focusID }) { return }
        if let scrollToID, items.contains(where: { $0.id == scrollToID }) {
            focusID = scrollToID
            return
        }
        focusID = items.first?.id
    }

    private func canScroll(by delta: Int) -> Bool {
        guard !items.isEmpty,
              let anchor = anchorID,
              let index = items.firstIndex(where: { $0.id == anchor })
        else { return false }
        if delta < 0 { return index > 0 }
        if delta > 0 { return index < items.count - 1 }
        return false
    }

    private func scroll(by delta: Int, proxy: ScrollViewProxy) {
        guard !items.isEmpty,
              let anchor = anchorID,
              let index = items.firstIndex(where: { $0.id == anchor })
        else { return }
        let target = min(max(index + delta, 0), items.count - 1)
        guard target != index else { return }
        let id = items[target].id
        focusID = id
        onScrollFocusChange?(id)
        withAnimation(scrollAnimation) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

// MARK: - 走马灯行

/// Apple TV 式横向滚动行（首页 / 详情推荐等）。
struct Rail<Item: Identifiable, ItemContent: View>: View {
    enum Kind {
        /// 海报卡（媒体库 / 最近添加 / 类似推荐）
        case poster
        /// 剧照卡（继续观看 / 接下来看）
        case still
        /// 不锁高度（演员头像等矮行）
        case flexible

        func scrollHeight(compact: Bool = false) -> CGFloat? {
            switch self {
            case .poster: Metrics.posterRailHeight(compact: compact)
            case .still: Metrics.stillRailHeight(compact: compact)
            case .flexible: nil
            }
        }

        /// 箭头对准卡片图区中部：海报/剧照标题在下方，略上移。
        var arrowYOffset: CGFloat {
            switch self {
            case .poster: -18
            case .still: -22
            case .flexible: 0
            }
        }

        var scrollStep: Int {
            switch self {
            case .poster: 4
            case .still: 3
            case .flexible: 4
            }
        }
    }

    let title: String
    var kind: Kind = .flexible
    var showsScrollArrows: Bool = true
    let items: [Item]
    private let itemContent: (Item) -> ItemContent

    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }

    init(
        _ title: String,
        kind: Kind = .flexible,
        showsScrollArrows: Bool = true,
        items: [Item],
        @ViewBuilder itemContent: @escaping (Item) -> ItemContent
    ) {
        self.title = title
        self.kind = kind
        self.showsScrollArrows = showsScrollArrows
        self.items = items
        self.itemContent = itemContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, contentLeading)

            if showsScrollArrows, items.count > 1 {
                HoverArrowHScroll(
                    items: items,
                    scrollStep: kind.scrollStep,
                    contentLeading: contentLeading,
                    edgeReserve: 28,
                    verticalPadding: Metrics.railHoverPadding,
                    arrowYOffset: kind.arrowYOffset,
                    fixedHeight: kind.scrollHeight(compact: isCompact),
                    itemContent: itemContent
                )
            } else {
                plainHorizontalRail
            }
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private var plainHorizontalRail: some View {
        let rail = ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Metrics.railSpacing) {
                ForEach(items) { item in
                    itemContent(item)
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.vertical, Metrics.railHoverPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

        if let height = kind.scrollHeight(compact: isCompact) {
            rail.frame(height: height, alignment: .top)
        } else {
            rail
        }
    }
}

private struct OptionalHeight: ViewModifier {
    let height: CGFloat?

    init(_ height: CGFloat?) {
        self.height = height
    }

    func body(content: Content) -> some View {
        if let height {
            content.frame(height: height, alignment: .top)
        } else {
            content
        }
    }
}

// MARK: - 悬停抬升（设计稿 focus 态的桌面版：放大 + 投影，不画焦点环）

private struct HoverLift: ViewModifier {
    let active: Bool
    let reduceMotion: Bool

    /// 比短 bounce spring 更顺：稍长 response + 高阻尼，进出都像被托起来而不是弹一下。
    /// 不用 body 里的 `withAnimation { content… }`——每次 body 重算都会重开事务，悬停进出容易发硬。
    private var motion: Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.12)
    }

    private var lifted: Bool { active && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted ? 1.055 : 1)
            .shadow(
                color: .black.opacity(lifted ? 0.28 : 0),
                radius: lifted ? 14 : 0,
                y: lifted ? 8 : 0
            )
            .animation(motion, value: active)
    }
}

extension View {
    func hoverLift(active: Bool, reduceMotion: Bool) -> some View {
        modifier(HoverLift(active: active, reduceMotion: reduceMotion))
    }
}

// MARK: - 悬停行高亮（列表式卡片用）

/// 列表式卡片（横向排列：小封面 + 信息列）的悬停反馈。
///
/// 和 `hoverLift`（放大 + 投影，给海报/剧照网格卡用）区分开：
/// 行式卡片放大 1.055 会撑出列表边界、和邻居重叠，不适合。
/// 这里只做背景填充提亮 + accentColor 描边，轻量但明确。
private struct HoverRowHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .background(
                active ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.background.secondary),
                in: RoundedRectangle(cornerRadius: Metrics.cardRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(
                        active ? Color.accentColor.opacity(0.3) : Color.clear,
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    /// 列表式卡片的悬停高亮：背景提亮 + accent 描边。给行式卡片用，
    /// 不放大（放大会让行撑出列表边界）。海报/剧照网格卡用 `hoverLift`。
    func hoverRowHighlight(active: Bool) -> some View {
        modifier(HoverRowHighlight(active: active))
    }
}

// MARK: - 键值行

/// 简单的 `Label : Value` 键值行——设置页等 Form 内重复使用的布局。
/// 之前 `SettingsView` 和 `PlaybackKernelSection` 各写了一份私有副本。
struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
