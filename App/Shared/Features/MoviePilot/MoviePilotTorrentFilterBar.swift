import SwiftUI

/// 资源筛选排序条（交互复刻 MP 网页端 TorrentFilterBar，液态玻璃质感）：
/// 左起「排序 → 升降序」+ 每组一个下拉弹窗（站点 / 季 / 促销 / 编码 / 质量 /
/// 分辨率 / 制作组），点开是候选值 chips 流（头部 全选 / 清除，可多选）；
/// 激活的分组在按钮上记数、tint 玻璃高亮，并在下方以可逐个移除的 chip 汇总。
/// 所有筛选经 `filters` binding 落账——父级在 set 侧重算展示序列。
struct MoviePilotTorrentFilterBar: View {
    @Binding var filters: TorrentFilters
    /// 各分组候选值（父级随搜索结果聚合，记忆化传入）。
    let options: TorrentFilterEngine.Options

    @Binding var sortField: TorrentSortField
    @Binding var sortAscending: Bool

    /// 当前展开下拉的分组（同一时刻至多一个）。
    @State private var activeField: TorrentFilterField?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    sortMenu
                    sortDirectionButton

                    ForEach(TorrentFilterField.allCases) { field in
                        groupButton(field)
                    }
                }
                .padding(.vertical, 1)
            }

            activeChipsRow
        }
    }

    // MARK: - 排序

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sortField) {
                ForEach(TorrentSortField.allCases, id: \.self) { field in
                    Text(field.label).tag(field)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sortField.label)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .opacity(0.6)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlassCapsule()
        }
        .help("结果排序字段")
    }

    private var sortDirectionButton: some View {
        Button {
            sortAscending.toggle()
        } label: {
            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
        }
        .buttonStyle(.plain)
        .help(sortAscending ? "当前升序，点击切换降序" : "当前降序，点击切换升序")
    }

    // MARK: - 分组下拉

    private func groupButton(_ field: TorrentFilterField) -> some View {
        let selection = filters[keyPath: field.selectionKeyPath]
        return Button {
            activeField = field
        } label: {
            HStack(spacing: 5) {
                Image(systemName: field.icon)
                Text(field.label)
                if !selection.isEmpty {
                    Text("\(selection.count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.14), in: Capsule())
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // 激活分组 tint 玻璃高亮（MP 网页端是紫色实底，玻璃用 tint 同语义）。
            .liquidGlassCapsule(tint: selection.isEmpty ? nil : Color.accentColor)
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverPresented(field)) {
            groupPopover(field)
        }
    }

    private func popoverPresented(_ field: TorrentFilterField) -> Binding<Bool> {
        Binding(
            get: { activeField == field },
            set: { shown in
                if !shown, activeField == field { activeField = nil }
            }
        )
    }

    /// 分组下拉内容：头部 全选 / 清除，下面是候选值 chips 流。
    /// iPhone 紧凑宽度自动升级为 sheet（自适应全宽 + detents），
    /// 常规宽度是锚定按钮的定宽 popover。
    private func groupPopover(_ field: TorrentFilterField) -> some View {
        let candidates = options[keyPath: field.optionsKeyPath]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("全选") {
                    filters[keyPath: field.selectionKeyPath] = Set(candidates)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .disabled(candidates.isEmpty)

                Spacer()

                Button("清除") {
                    filters[keyPath: field.selectionKeyPath] = []
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .disabled(candidates.isEmpty)
            }

            if candidates.isEmpty {
                Text("当前结果里没有可选值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(candidates, id: \.self) { value in
                        candidateChip(value, field: field)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: sizeClass == .compact ? .infinity : nil)
        .frame(width: sizeClass == .compact ? nil : 380, alignment: .leading)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func candidateChip(_ value: String, field: TorrentFilterField) -> some View {
        let selected = filters[keyPath: field.selectionKeyPath].contains(value)
        return Button {
            toggle(field, value)
        } label: {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(value)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }

    // MARK: - 已选汇总

    private struct ActiveChip: Identifiable {
        let field: TorrentFilterField
        let value: String
        var id: String { "\(field.rawValue):\(value)" }
    }

    private var activeChips: [ActiveChip] {
        TorrentFilterField.allCases.flatMap { field in
            filters[keyPath: field.selectionKeyPath].sorted()
                .map { ActiveChip(field: field, value: $0) }
        }
    }

    /// 已选条件 chip 流（MP 网页端「站点:观众 ×」样式），单个可移除，
    /// 多于一项时附「清除全部」。
    @ViewBuilder
    private var activeChipsRow: some View {
        if filters.isActive {
            FlowLayout(spacing: 6) {
                ForEach(activeChips) { chip in
                    HStack(spacing: 5) {
                        Text("\(chip.field.label):\(chip.value)")
                            .font(.caption2.weight(.medium))

                        Button {
                            remove(chip.field, chip.value)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .opacity(0.7)
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.13), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
                }

                if filters.activeCount > 1 {
                    Button {
                        filters = TorrentFilters()
                    } label: {
                        Text("清除全部")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - 落账

    private func toggle(_ field: TorrentFilterField, _ value: String) {
        var selection = filters[keyPath: field.selectionKeyPath]
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
        filters[keyPath: field.selectionKeyPath] = selection
    }

    private func remove(_ field: TorrentFilterField, _ value: String) {
        filters[keyPath: field.selectionKeyPath].remove(value)
    }
}

// MARK: - Chips 流式布局

/// 逐个测量、按行折行的流式布局（Bangumi 详情页标签流同款实现）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
