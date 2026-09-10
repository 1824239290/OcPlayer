import SwiftUI

// MARK: - 骨架屏

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
public struct SkeletonBlock: View {
    public var cornerRadius: CGFloat = Metrics.cardRadius

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.skeletonPhase) private var phase

    public init(cornerRadius: CGFloat = Metrics.cardRadius) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
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
public struct SkeletonShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    public init() {}

    public func body(content: Content) -> some View {
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

public extension View {
    /// 骨架屏外层容器：子 `SkeletonBlock` 自动共享同一 shimmer 相位。
    func skeletonShimmer() -> some View {
        modifier(SkeletonShimmer())
    }
}

/// 骨架海报卡：2:3 图块 + 标题条，和 `PosterCard` 同尺寸。
public struct SkeletonPosterCard: View {
    public var width: CGFloat? = Metrics.posterWidth

    public init(width: CGFloat? = Metrics.posterWidth) {
        self.width = width
    }

    public var body: some View {
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
public struct SkeletonStillCard: View {
    public var width: CGFloat = Metrics.stillWidth

    public init(width: CGFloat = Metrics.stillWidth) {
        self.width = width
    }

    public var body: some View {
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
public struct SkeletonRail: View {
    public let title: String
    public let kind: RailKind

    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }

    public enum RailKind {
        case poster   // 2:3 海报卡
        case still    // 16:9 剧照卡
    }

    public init(title: String, kind: RailKind) {
        self.title = title
        self.kind = kind
    }

    private var cardCount: Int {
        #if os(iOS)
        return 3
        #else
        return 5
        #endif
    }

    public var body: some View {
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
public struct SkeletonEpisodeStrip: View {
    public var cardCount: Int = 6

    @Environment(\.contentLeading) private var contentLeading

    public init(cardCount: Int = 6) {
        self.cardCount = cardCount
    }

    public var body: some View {
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
