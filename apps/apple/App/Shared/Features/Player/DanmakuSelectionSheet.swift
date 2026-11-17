import AppDesignKit
import DanmakuKit
import SwiftUI

struct DanmakuSelectionSheet: View {
    @Environment(DanmakuModel.self) private var danmakuModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var animeFocused: Bool
    @FocusState private var episodeFocused: Bool

    @State private var animeQuery: String
    @State private var episodeQuery: String
    @State private var results: [AnimeWithEpisodes] = []
    @State private var selectedAnime: AnimeWithEpisodes?
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var searchRequest: SearchRequest?
    @State private var didStartInitialSearch = false
    let requestID: PlaybackRequest.ID?

    init(requestID: PlaybackRequest.ID?, initialAnime: String, initialEpisode: String) {
        self.requestID = requestID
        _animeQuery = State(initialValue: initialAnime)
        _episodeQuery = State(initialValue: initialEpisode)
    }

    private var validAnimeResults: [AnimeWithEpisodes] {
        results.filter { !$0.episodes.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if selectedAnime == nil {
                searchHeader
            }

            ZStack {
                if let anime = selectedAnime {
                    episodeSubmenuView(for: anime)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    contentView
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AppSheetDivider()
            AppSheetFooter {
                Text(selectedAnime == nil ? "选择作品后查看集数" : "点击对应集数即可加载弹幕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } actions: {
                Button("完成") { dismiss() }
                    .buttonStyle(AppSheetButtonStyle())
            }
        }
        .appSheetSurface()
        .onAppear {
            if !didStartInitialSearch,
               !animeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didStartInitialSearch = true
                startSearch()
            }
        }
        .task(id: searchRequest) {
            guard let searchRequest else { return }
            await search(searchRequest)
        }
    }

    // MARK: - 顶栏（支持多层子菜单返回）

    private var headerBar: some View {
        AppSheetHeader(
            title: selectedAnime?.animeTitle ?? "选择弹幕",
            symbol: "text.bubble",
            onBack: selectedAnime == nil ? nil : {
                withAnimation(reduceMotion ? nil : Motion.lift) { selectedAnime = nil }
            }
        )
    }

    // MARK: - 搜索栏与状态条

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    animeSearchField.frame(minWidth: 220)
                    episodeSearchField.frame(width: 110)
                    searchButton
                }
                VStack(spacing: 10) {
                    animeSearchField
                    HStack(spacing: 8) {
                        episodeSearchField
                        searchButton
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("弹幕状态：" + danmakuModel.danmaku.status.displayLabel(
                        elapsedSeconds: danmakuModel.danmaku.statusElapsedSeconds))
                } icon: {
                    Circle().fill(statusIndicatorColor).frame(width: 7, height: 7)
                }
                if let match = danmakuModel.danmaku.currentMatch {
                    Label("当前匹配：Episode \(match.episodeID)", systemImage: "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text("搜索结果").fontWeight(.medium)
                Spacer()
                Text(isSearching ? "正在搜索…" : "\(validAnimeResults.count) 部作品")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var animeSearchField: some View {
        CapsuleSearchField("搜索作品名或原名", text: $animeQuery, focus: $animeFocused,
                           onSubmit: startSearch, onChange: invalidateChangedSearch)
    }

    private var episodeSearchField: some View {
        CapsuleSearchField("集数", text: $episodeQuery, focus: $episodeFocused,
                           onSubmit: startSearch, onChange: invalidateChangedSearch)
    }

    private var searchButton: some View {
        Button("搜索", action: startSearch)
            .buttonStyle(AppSheetButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isSearching || animeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var statusIndicatorColor: Color {
        switch danmakuModel.danmaku.status {
        case .loaded:
            .green
        case .matching, .loadingComments:
            .orange
        case .noMatch, .empty, .failed:
            .red
        case .idle, .disabled, .unconfigured:
            .secondary
        }
    }

    // MARK: - 结果内容区（第一层：作品列表）

    @ViewBuilder
    private var contentView: some View {
        if isSearching && results.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在搜索弹幕库…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            EmptyState(failure: errorMessage, title: UIStrings.searchFailed) {
                startSearch()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasSearched && validAnimeResults.isEmpty {
            noResultsView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSearched && results.isEmpty {
            initialGuideView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            animeSubmenuListView
        }
    }

    private var noResultsView: some View {
        let hasEpisode = !episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let anime = animeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmptyState(
            empty: "未找到相关弹幕",
            systemImage: "magnifyingglass",
            message: hasEpisode
                ? "未找到与「\(anime)」第「\(episodeQuery)」集匹配的弹幕。\n请尝试清空集数搜索全部剧集，或调整作品名称。"
                : "未找到与「\(anime)」相关的弹幕。\n请检查作品名称拼写，或尝试使用更通用的关键词。",
            actionTitle: hasEpisode ? "清空集数重新搜索" : nil
        ) {
            episodeQuery = ""
            startSearch()
        }
    }

    private var initialGuideView: some View {
        EmptyState(
            empty: "搜索弹幕",
            systemImage: "text.magnifyingglass",
            message: "输入作品名与集数，检索弹弹play网络弹幕库。"
        )
    }

    /// 第一层子菜单：匹配到的动画作品列表（点击下钻进入选集）
    private var animeSubmenuListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(validAnimeResults, id: \.animeId) { anime in
                    let containsMatch = anime.episodes.contains {
                        $0.episodeId == danmakuModel.danmaku.currentMatch?.episodeID
                    }
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.lift) {
                            selectedAnime = anime
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(containsMatch ? AppAccent.tint : Color.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(anime.animeTitle ?? "未命名作品")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)

                                HStack(spacing: 6) {
                                    if let typeDesc = anime.typeDescription ?? anime.type, !typeDesc.isEmpty {
                                        Text(typeDesc)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.primary.opacity(0.06), in: Capsule())
                                    }

                                    if containsMatch {
                                        Text("包含当前匹配")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Color.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.12), in: Capsule())
                                    }
                                }
                            }

                            Spacer(minLength: 8)

                            Text("共 \(anime.episodes.count) 集")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(containsMatch ? 0.06 : 0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    containsMatch ? AppAccent.tint.opacity(0.3) : Color.primary.opacity(0.06),
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    /// 第二层子菜单：选定作品下的集数列表
    private func episodeSubmenuView(for anime: AnimeWithEpisodes) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(anime.episodes) { episode in
                    let isCurrent = danmakuModel.danmaku.currentMatch?.episodeID == episode.episodeId
                    DanmakuEpisodeRow(
                        episode: episode,
                        isCurrentMatch: isCurrent
                    ) {
                        if let requestID {
                            danmakuModel.danmaku.selectEpisode(
                                episode,
                                animeTitle: anime.animeTitle,
                                for: requestID
                            )
                        }
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    // MARK: - 搜索逻辑

    private func startSearch() {
        let anime = animeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anime.isEmpty else { return }
        let episode = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSearching,
           searchRequest?.anime == anime,
           searchRequest?.episode == episode {
            return
        }
        isSearching = true
        hasSearched = false
        searchRequest = SearchRequest(anime: anime, episode: episode)
    }

    private func search(_ request: SearchRequest) async {
        isSearching = true
        errorMessage = nil
        results = []
        defer {
            if searchRequest?.id == request.id {
                isSearching = false
                hasSearched = true
            }
        }
        do {
            let found = try await danmakuModel.danmaku.searchEpisodes(
                anime: request.anime,
                episode: request.episode
            )
            try Task.checkCancellation()
            guard searchRequest?.id == request.id else { return }
            results = found
            // 如果只有 1 个作品，或者正好匹配，可以保持在作品列表供下钻，也可以让用户看清各季
            if let current = selectedAnime, !found.contains(where: { $0.animeId == current.animeId }) {
                selectedAnime = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, searchRequest?.id == request.id else { return }
            switch error {
            case DandanplayError.notConfigured:
                errorMessage = "请先在设置中配置弹幕网关"
            case let danmakuError as DandanplayError:
                errorMessage = danmakuError.userMessage
            default:
                errorMessage = "无法完成搜索"
            }
        }
    }

    private func invalidateChangedSearch() {
        guard let searchRequest else { return }
        let anime = animeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let episode = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard anime != searchRequest.anime || episode != searchRequest.episode else { return }
        self.searchRequest = nil
        self.selectedAnime = nil
        isSearching = false
        hasSearched = false
        errorMessage = nil
        results = []
    }
}

// MARK: - 剧集项单行组件

private struct DanmakuEpisodeRow: View {
    let episode: Episode
    let isCurrentMatch: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isCurrentMatch ? "checkmark.circle.fill" : "play.rectangle")
                    .font(.system(size: 15))
                    .foregroundStyle(isCurrentMatch ? AppAccent.tint : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.episodeTitle ?? "Episode \(episode.episodeId)")
                        .font(.callout.weight(isCurrentMatch ? .semibold : .regular))
                        .foregroundStyle(isCurrentMatch ? AppAccent.tint : Color.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(verbatim: "ID \(episode.episodeId)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.05))
                    )

                if isCurrentMatch {
                    Text("当前匹配")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppAccent.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppAccent.tint.opacity(0.15), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isCurrentMatch {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppAccent.tint.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AppAccent.tint.opacity(0.25), lineWidth: 0.5)
                        }
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .accessibilityLabel(episode.episodeTitle ?? "Episode \(episode.episodeId)")
        .accessibilityValue(isCurrentMatch ? "当前匹配" : "")
    }
}

private struct SearchRequest: Hashable {
    let id = UUID()
    let anime: String
    let episode: String
}
