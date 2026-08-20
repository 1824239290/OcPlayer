import CoreModel
import JellyfinKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 动画帮手

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
    static let cardRadius: CGFloat = 10
    static let railSpacing: CGFloat = 22
    static let contentInset: CGFloat = 52
    /// Rail 横向 ScrollView 上下为悬停放大预留的内边距（上下各一档）。
    static let railHoverPadding: CGFloat = 28

    /// 海报卡（图 2:3 + 标题行）在 Rail 里的可视高度，含 hover 留白。
    static var posterRailHeight: CGFloat {
        posterWidth * 1.5 + 9 + 22 + railHoverPadding * 2
    }

    /// 剧照卡（16:9 + 进度条 + 两行文案）在 Rail 里的可视高度，含 hover 留白。
    static var stillRailHeight: CGFloat {
        stillWidth * 9 / 16 + 6 + 3 + 10 + 40 + railHoverPadding * 2
    }

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
    let actionIcon: String
    let actionAccessibilityLabel: String?
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(
        item: MediaItem,
        server: JellyfinServer?,
        actionIcon: String = "play.fill",
        actionAccessibilityLabel: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.item = item
        self.server = server
        self.actionIcon = actionIcon
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.onTap = onTap
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
                    RemoteImage(url: target.url, authHeader: target.authHeader)
                        .aspectRatio(16 / 9, contentMode: .fill)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(actionAccessibilityLabel ?? "播放 \(item.name)")
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
                .frame(width: Metrics.stillWidth * progress)
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
    var contentLeading: CGFloat = Metrics.contentLeading
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
                    .padding(.horizontal, contentLeading + (showsArrowChrome ? edgeReserve : 0))
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

        var scrollHeight: CGFloat? {
            switch self {
            case .poster: Metrics.posterRailHeight
            case .still: Metrics.stillRailHeight
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
                .padding(.horizontal, Metrics.contentLeading)

            if showsScrollArrows, items.count > 1 {
                HoverArrowHScroll(
                    items: items,
                    scrollStep: kind.scrollStep,
                    contentLeading: Metrics.contentLeading,
                    edgeReserve: 28,
                    verticalPadding: Metrics.railHoverPadding,
                    arrowYOffset: kind.arrowYOffset,
                    fixedHeight: kind.scrollHeight,
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
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.vertical, Metrics.railHoverPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

        if let height = kind.scrollHeight {
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
