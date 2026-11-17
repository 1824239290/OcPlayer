import AppDesignKit
import CoreModel
import MetadataKit
import SwiftUI

/// 搜索并核对候选后确认关联；旧搜索不能覆盖新关键词的结果。
struct TMDbMatchSheet: View {
    let item: MediaItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query: String
    @State private var results: [TMDbSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorText: String?
    @State private var bindingError: String?
    @State private var currentLink: TMDbLink?
    @State private var selectedKey: TMDbEntityKey?
    @State private var isBinding = false
    @State private var didStartInitialSearch = false
    @State private var searchRequest: TMDbMatchSearchRequest?

    init(item: MediaItem) {
        self.item = item
        _query = State(initialValue: item.name)
    }

    private var mediaType: TMDbMediaType { item.kind == .movie ? .movie : .tv }
    private var canMatch: Bool { item.kind == .movie || item.kind == .series }
    private var selectedResult: TMDbSearchResult? {
        results.first { entityKey(for: $0) == selectedKey }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(title: "关联 TMDB", symbol: "link", subtitle: item.name, canDismiss: !isBinding)
            searchBar
            HStack {
                Text("搜索结果").fontWeight(.medium)
                Spacer()
                Text(isSearching ? "正在搜索…" : "\(results.count) 个条目")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            AppSheetDivider()
            AppSheetFooter {
                VStack(alignment: .leading, spacing: 6) {
                    if let result = selectedResult {
                        Text("已选择").foregroundStyle(.secondary)
                        Text(result.title ?? "（无标题）").fontWeight(.medium).lineLimit(2)
                    } else {
                        Text("选择对应作品后确认关联").foregroundStyle(.secondary)
                    }
                    if let bindingError {
                        Text(bindingError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    if currentLink != nil {
                        Button("解除当前匹配", role: .destructive) { Task { await unbind() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .frame(minHeight: 44)
                            .disabled(isBinding)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .contain)
            } actions: {
                Button { Task { await bindSelection() } } label: {
                    HStack(spacing: 8) {
                        if isBinding { ProgressView().controlSize(.small) }
                        Label("确认关联", systemImage: "link")
                    }
                }
                .buttonStyle(AppSheetButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(selectedResult == nil || isSearching || isBinding)
            }
        }
        .appSheetSurface()
        .interactiveDismissDisabled(isBinding)
        .onAppear {
            guard !didStartInitialSearch else { return }
            didStartInitialSearch = true
            startSearch()
        }
        .task { await reloadLink() }
        .task(id: searchRequest) {
            guard let searchRequest else { return }
            await search(searchRequest)
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link = currentLink {
                Label("已匹配：\(link.entityKey.storageKey) · \(link.source.displayName)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                CapsuleSearchField("搜索片名或原名", text: $query, focus: $searchFocused,
                                   onSubmit: startSearch, onChange: invalidateSearch)
                Button("搜索", action: startSearch)
                    .buttonStyle(AppSheetButtonStyle())
                    .disabled(isSearching || !canMatch || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(isBinding)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if !canMatch {
            EmptyState(empty: "此条目无需单独匹配", systemImage: "link",
                       message: "只有电影与剧集可以手动匹配。季与分集的数据由所属剧集推导。")
        } else if isSearching {
            ProgressView("正在搜索 TMDB…")
        } else if let errorText {
            EmptyState(failure: errorText, title: UIStrings.searchFailed, retry: startSearch)
        } else if results.isEmpty {
            EmptyState(empty: hasSearched ? "没有找到相关条目" : "搜索 TMDB 条目",
                       systemImage: "magnifyingglass",
                       message: "试试更短的名称，或使用日文、英文原名。")
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(results, id: \.id) { result in
                        TMDbMatchResultRow(result: result,
                                           isSelected: entityKey(for: result) == selectedKey,
                                           isCurrent: entityKey(for: result) == currentLink?.entityKey) {
                            selectedKey = entityKey(for: result)
                            bindingError = nil
                            searchFocused = false
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            .disabled(isBinding)
        }
    }

    private func entityKey(for result: TMDbSearchResult) -> TMDbEntityKey {
        result.mediaType == .movie ? .movie(result.id) : .tv(result.id)
    }

    private func reloadLink() async { currentLink = await app.tmdbLink(for: item) }

    private func invalidateSearch() {
        searchRequest = nil
        isSearching = false
        hasSearched = false
        results = []
        selectedKey = nil
        errorText = nil
        bindingError = nil
    }

    private func startSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canMatch, !trimmed.isEmpty, !isBinding else { return }
        guard !isSearching || searchRequest?.query != trimmed else { return }
        results = []
        selectedKey = nil
        errorText = nil
        bindingError = nil
        isSearching = true
        searchFocused = false
        searchRequest = TMDbMatchSearchRequest(query: trimmed)
    }

    private func search(_ request: TMDbMatchSearchRequest) async {
        defer {
            if searchRequest == request {
                isSearching = false
                hasSearched = true
            }
        }
        do {
            let matches = try await app.tmdbSearchCandidates(query: request.query, mediaType: mediaType, year: item.year)
            guard !Task.isCancelled, searchRequest == request else { return }
            results = matches
        } catch {
            guard !Task.isCancelled, searchRequest == request else { return }
            errorText = "搜索失败：\(TMDbCoordinator.message(for: error as? TMDbError) ?? error.localizedDescription)"
        }
    }

    private func bindSelection() async {
        guard !isBinding, !isSearching, let result = selectedResult else { return }
        isBinding = true
        defer { isBinding = false }
        bindingError = nil
        let succeeded = await app.tmdbBind(itemID: item.id, entityKey: entityKey(for: result))
        await reloadLink()
        if succeeded {
            dismiss()
        } else {
            // 保存失败时保留候选与选择，让用户能直接重试。
            bindingError = "关联未完成，请检查 TMDB 配置与网络后重试。"
        }
    }

    private func unbind() async {
        guard !isBinding else { return }
        isBinding = true
        defer { isBinding = false }
        await app.tmdbUnbind(itemID: item.id)
        await reloadLink()
    }
}

private struct TMDbMatchSearchRequest: Hashable {
    let id = UUID()
    let query: String
}

private struct TMDbMatchResultRow: View {
    let result: TMDbSearchResult
    let isSelected: Bool
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                let pixels = Int((44 * displayScale).rounded(.up))
                RemoteImage(url: TMDbImageSize.url(path: result.posterPath, requestedWidth: pixels),
                            authHeader: nil, maxPixelSize: pixels)
                    .frame(width: 44, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title ?? "（无标题）").font(.callout.weight(.medium)).lineLimit(2)
                    if let original = result.originalTitle, original != result.title, !original.isEmpty {
                        Text(original).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let year = result.year { Text(String(year)) }
                        Text(result.mediaType == .movie ? "电影" : "剧集")
                        if isCurrent { Text("当前匹配") }
                    }
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
            .background(Color.primary.opacity(isSelected ? 0.08 : (isHovered ? 0.04 : 0)), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
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

extension TMDbLinkSource {
    /// 设置页/面板展示用（说明这条对应是怎么来的）。
    var displayName: String {
        switch self {
        case .providerID: "来自媒体库"
        case .search: "自动匹配"
        case .manual: "手动选择"
        }
    }
}
