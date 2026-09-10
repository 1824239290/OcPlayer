import SwiftUI

// MARK: - 横向滚动（悬停箭头）

/// 横向懒加载列表 + 两侧悬浮箭头。
/// 箭头仅在鼠标进入轨道时淡入（VoiceOver 开启时始终可操作），
/// 状态只有一个 `Bool`，不跟滚动 offset，几乎不吃性能。
public struct HoverArrowHScroll<Item: Identifiable, ItemContent: View>: View {
    public let items: [Item]
    public var scrollStep: Int = 3
    /// 页面横向留白。调用方从 `\.contentLeading` 环境值取，随窗口宽度变化。
    public var contentLeading: CGFloat = Metrics.contentInset
    /// 列表左右额外内边距，给悬浮箭头留点击空隙。
    public var edgeReserve: CGFloat = 28
    public var verticalPadding: CGFloat = Metrics.railHoverPadding
    /// 箭头相对垂直居中的偏移（负值上移，正值下移）。
    public var arrowYOffset: CGFloat = 0
    public var fixedHeight: CGFloat? = nil
    /// 选中/外部驱动时滚到该 id（如详情选集）。
    public var scrollToID: Item.ID? = nil
    public var onScrollFocusChange: ((Item.ID) -> Void)? = nil
    @ViewBuilder public var itemContent: (Item) -> ItemContent

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var focusID: Item.ID?

    public init(
        items: [Item],
        scrollStep: Int = 3,
        contentLeading: CGFloat = Metrics.contentInset,
        edgeReserve: CGFloat = 28,
        verticalPadding: CGFloat = Metrics.railHoverPadding,
        arrowYOffset: CGFloat = 0,
        fixedHeight: CGFloat? = nil,
        scrollToID: Item.ID? = nil,
        onScrollFocusChange: ((Item.ID) -> Void)? = nil,
        @ViewBuilder itemContent: @escaping (Item) -> ItemContent
    ) {
        self.items = items
        self.scrollStep = scrollStep
        self.contentLeading = contentLeading
        self.edgeReserve = edgeReserve
        self.verticalPadding = verticalPadding
        self.arrowYOffset = arrowYOffset
        self.fixedHeight = fixedHeight
        self.scrollToID = scrollToID
        self.onScrollFocusChange = onScrollFocusChange
        self.itemContent = itemContent
    }

    public var body: some View {
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
        reduceMotion ? nil : Motion.fast
    }

    private var scrollAnimation: Animation? {
        reduceMotion ? nil : Motion.standard
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

struct OptionalHeight: ViewModifier {
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
