import AppDesignKit
import BangumiKit
import CoreModel
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 搜索、核对候选，再确认关联。搜索任务随关键词失效，旧结果不能覆盖新选择。
struct BangumiLinkPicker: View {
    let item: MediaItem
    var season: MediaItem? = nil
    var onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var searchFocused: Bool
    @State private var keyword: String
    @State private var results: [BangumiSlimSubjectDTO] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selectedSubjectID: Int?
    @State private var hasSearched = false
    @State private var didStartInitialSearch = false
    @State private var searchRequest: BangumiLinkSearchRequest?

    init(item: MediaItem, season: MediaItem? = nil, onSelect: @escaping (Int) -> Void) {
        self.item = item
        self.season = season
        self.onSelect = onSelect

        // 仅在打开选择器时以当前季标题初始化，之后由用户编辑。
        _keyword = State(initialValue: BangumiMatcher.searchTitle(for: item, season: season))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            resultHeading
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.primary.opacity(0.08))
                .opacity(0.3)
            footer
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 520, idealHeight: 620)
        #endif
        .background {
            // 系统材质保留背后的色彩与明暗；不降低整个视图的透明度，保证文字清晰。
            if reduceTransparency {
                panelShape.fill(opaqueSurface)
            } else {
                #if os(macOS)
                ZStack {
                    BangumiLinkWindowMaterial()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    panelShape.fill((colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.98)).opacity(0.62))
                }
                #else
                // glass-guard-exempt: 独立关联 sheet 的呈现背景，不是页内内容卡；保留磨砂半透与减少透明度回退。
                panelShape.fill(.thinMaterial)
                #endif
            }
        }
        .clipShape(panelShape)
        .overlay {
            panelShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        #if os(iOS)
        .padding(16)
        #endif
        .tint(AppAccent.tint)
        .presentationBackground(.clear)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        #endif
        .onAppear {
            guard !didStartInitialSearch else { return }
            didStartInitialSearch = true
            startSearch()
        }
        .task(id: searchRequest) {
            guard let searchRequest else { return }
            await search(searchRequest)
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.glassCardRadius, style: .continuous)
    }

    private var opaqueSurface: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private var selectedSubject: BangumiSlimSubjectDTO? {
        results.first { $0.id == selectedSubjectID }
    }

    private var seasonLabel: String? {
        if let number = season?.seasonNumber ?? item.seasonNumber {
            return number == 0 ? "特别篇" : "第 \(number) 季"
        }
        return season?.name ?? item.seasonName
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("关联 Bangumi")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        #if os(iOS)
                        .frame(width: 44, height: 44)
                        #else
                        .frame(width: 30, height: 30)
                        #endif
                        .background(Color.primary.opacity(0.04), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭关联弹窗")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { associationContext }
                VStack(alignment: .leading, spacing: 6) { associationContext }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                CapsuleSearchField(
                    "搜索中文名或原名",
                    text: $keyword,
                    focus: $searchFocused,
                    onSubmit: startSearch,
                    onChange: invalidateSearch
                )
                Button(action: startSearch) {
                    Text("搜索")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .background(Color.primary.opacity(0.04), in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
                }
                .buttonStyle(.plain)
                .disabled(isSearching || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var associationContext: some View {
        Text("正在关联").foregroundStyle(.secondary)
        Text(item.seriesName ?? item.name)
            .fontWeight(.medium)
            .lineLimit(2)
        if let seasonLabel, !seasonLabel.isEmpty {
            Text(seasonLabel)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var resultHeading: some View {
        HStack {
            Text("搜索结果").fontWeight(.medium)
            Spacer()
            Text(isSearching ? "正在搜索…" : "\(results.count) 个条目")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView("正在搜索 Bangumi…")
        } else if let searchError {
            EmptyState(failure: searchError, title: UIStrings.searchFailed, retry: startSearch)
        } else if results.isEmpty {
            EmptyState(
                empty: hasSearched ? "没有找到相关条目" : "搜索 Bangumi 条目",
                systemImage: "magnifyingglass",
                message: hasSearched ? "试试更短的名称，或使用日文原名。" : "输入名称搜索，选择对应作品后确认关联。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(results) { subject in
                        BangumiLinkResultRow(subject: subject, isSelected: selectedSubjectID == subject.id) {
                            selectedSubjectID = subject.id
                            searchFocused = false
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                selectionSummary
                Spacer(minLength: 8)
                confirmButton
            }
            VStack(alignment: .leading, spacing: 12) {
                selectionSummary
                HStack { Spacer(); confirmButton }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let selectedSubject {
                Text("已选择").foregroundStyle(.secondary)
                Text(selectedSubject.title(preferChinese: true))
                    .fontWeight(.medium)
                    .lineLimit(2)
            } else {
                Text("选择对应作品后确认关联")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(minHeight: 40, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var confirmButton: some View {
        Button {
            guard !isSearching, let selectedSubject else { return }
            onSelect(selectedSubject.id)
            dismiss()
        } label: {
            Label("确认关联", systemImage: "link")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .foregroundStyle(selectedSubject == nil ? Color.secondary : AppAccent.onSolid)
                .background(selectedSubject == nil ? Color.primary.opacity(0.04) : AppAccent.solid, in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(selectedSubject == nil || isSearching)
    }

    private func invalidateSearch() {
        searchRequest = nil
        isSearching = false
        hasSearched = false
        searchError = nil
        results = []
        selectedSubjectID = nil
    }

    private func startSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedSubjectID = nil
        results = []
        isSearching = true
        searchError = nil
        hasSearched = true
        searchFocused = false
        let initialKeyword = BangumiMatcher.searchTitle(for: item, season: season)
        let fallback = trimmed == initialKeyword ? (item.seriesName ?? item.name) : nil
        searchRequest = BangumiLinkSearchRequest(keyword: trimmed, fallbackKeyword: fallback)
    }

    private func search(_ request: BangumiLinkSearchRequest) async {
        defer {
            if searchRequest == request { isSearching = false }
        }
        do {
            // 保留季标题搜索及默认关键词回退；用户自行输入时不替换搜索词。
            let matches = try await BangumiMatcher.search(request.keyword, fallbackKeyword: request.fallbackKeyword)
            guard !Task.isCancelled, searchRequest == request else { return }
            results = matches
        } catch {
            guard !Task.isCancelled, searchRequest == request else { return }
            searchError = (error as? BangumiError)?.userMessage ?? error.localizedDescription
        }
    }
}

#if os(macOS)
/// SwiftUI 的窗口内材质只能采到 sheet 自己的底色；跨窗口采样才能透出详情页。
private struct BangumiLinkWindowMaterial: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BangumiLinkEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if nsView.appearance?.name != name {
            nsView.appearance = NSAppearance(named: name)
        }
    }
}

private final class BangumiLinkEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // sheetParent 在挂载视图之后才建立，下一次主队列检查实际的呈现关系。
        DispatchQueue.main.async { [weak self] in self?.clearSheetBackground() }
    }

    private func clearSheetBackground() {
        // 只改本弹窗的窗口，不能把详情页的宿主窗口一起变透明。
        guard let window, window.sheetParent != nil else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
#endif

private struct BangumiLinkSearchRequest: Hashable {
    let id = UUID()
    let keyword: String
    let fallbackKeyword: String?
}

private struct BangumiLinkResultRow: View {
    let subject: BangumiSlimSubjectDTO
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RemoteImage(url: coverURL, authHeader: nil, maxPixelSize: Int((64 * displayScale).rounded(.up)))
                    .frame(width: 44, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(subject.title(preferChinese: true))
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if !subject.nameCN.isEmpty, subject.name != subject.nameCN {
                        Text(subject.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(subject.type.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.2))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.08 : (isHovered ? 0.04 : 0)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.45 : 0), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}
