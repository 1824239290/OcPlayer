import SwiftUI

// MARK: - 走马灯行

/// Apple TV 式横向滚动行（首页 / 详情推荐等）。
public struct Rail<Item: Identifiable, ItemContent: View>: View {
    public enum Kind {
        /// 海报卡（媒体库 / 最近添加 / 类似推荐）
        case poster
        /// 剧照卡（继续观看 / 接下来看）
        case still
        /// 不锁高度（演员头像等矮行）
        case flexible

        public func scrollHeight(compact: Bool = false) -> CGFloat? {
            switch self {
            case .poster: Metrics.posterRailHeight(compact: compact)
            case .still: Metrics.stillRailHeight(compact: compact)
            case .flexible: nil
            }
        }

        /// 箭头对准卡片图区中部：海报/剧照标题在下方，略上移。
        public var arrowYOffset: CGFloat {
            switch self {
            case .poster: -18
            case .still: -22
            case .flexible: 0
            }
        }

        public var scrollStep: Int {
            switch self {
            case .poster: 4
            case .still: 3
            case .flexible: 4
            }
        }
    }

    public let title: String
    public var kind: Kind = .flexible
    public var showsScrollArrows: Bool = true
    public let items: [Item]
    private let itemContent: (Item) -> ItemContent

    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }

    public init(
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

    public var body: some View {
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
