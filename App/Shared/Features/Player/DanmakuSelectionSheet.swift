import DanmakuKit
import SwiftUI

struct DanmakuSelectionSheet: View {
    @Environment(DanmakuModel.self) private var danmakuModel
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case anime
        case episode
    }

    @FocusState private var focusedField: Field?

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

            Divider()
                .opacity(0.15)

            if selectedAnime == nil {
                searchHeader

                Divider()
                    .opacity(0.12)
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
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 460, idealHeight: 520)
        #endif
        .liquidGlassCard(cornerRadius: 24)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .padding(16)
        .presentationBackground(.clear)
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
        HStack(spacing: 10) {
            if let anime = selectedAnime {
                // 子菜单第二层：返回作品列表按钮
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        selectedAnime = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("作品列表")
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(isInteractive: true)

                Text(anime.animeTitle ?? "选集")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                // 根层：标题与图标
                Image(systemName: "text.bubble.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                Text("选择弹幕")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .liquidGlassCapsule(isInteractive: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 搜索栏与状态条

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 输入行：作品名 + 集数 + 搜索按钮
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // 作品名输入框
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(focusedField == .anime ? Color.accentColor : Color.secondary)
                        TextField("作品名（如：葬送的芙莉莲）", text: $animeQuery)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .focused($focusedField, equals: .anime)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit(startSearch)
                            .onChange(of: animeQuery) { invalidateChangedSearch() }

                        if !animeQuery.isEmpty {
                            Button {
                                animeQuery = ""
                                invalidateChangedSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                focusedField == .anime ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                                lineWidth: 0.5
                            )
                    )

                    // 集数输入框
                    HStack(spacing: 4) {
                        TextField("集数", text: $episodeQuery)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .focused($focusedField, equals: .episode)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit(startSearch)
                            .onChange(of: episodeQuery) { invalidateChangedSearch() }

                        if !episodeQuery.isEmpty {
                            Button {
                                episodeQuery = ""
                                invalidateChangedSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    #if os(macOS)
                    .frame(width: 80)
                    #else
                    .frame(maxWidth: 80)
                    #endif
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                focusedField == .episode ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                                lineWidth: 0.5
                            )
                    )

                    // 搜索按钮
                    Button(action: startSearch) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text("搜索")
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCapsule(tint: Color.accentColor.opacity(0.25), isInteractive: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSearching || animeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // 当前状态与匹配指示
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 7, height: 7)
                    Text("弹幕状态：\(danmakuModel.danmaku.status.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let match = danmakuModel.danmaku.currentMatch {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(verbatim: "已关联 Episode \(match.episodeID)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.08), in: Capsule())
                }

                Spacer()

                if isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在搜索…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !validAnimeResults.isEmpty {
                    Text("检索到 \(validAnimeResults.count) 部相关作品")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
            ContentUnavailableView {
                Label(UIStrings.searchFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(UIStrings.retry) {
                    startSearch()
                }
                .buttonStyle(.borderedProminent)
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
        ContentUnavailableView {
            Label("未找到相关弹幕", systemImage: "magnifyingglass")
        } description: {
            let hasEpisode = !episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let anime = animeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if hasEpisode {
                Text("未找到与「\(anime)」第「\(episodeQuery)」集匹配的弹幕。\n请尝试清空集数搜索全部剧集，或调整作品名称。")
            } else {
                Text("未找到与「\(anime)」相关的弹幕。\n请检查作品名称拼写，或尝试使用更通用的关键词。")
            }
        } actions: {
            if !episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("清空集数重新搜索") {
                    episodeQuery = ""
                    startSearch()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var initialGuideView: some View {
        ContentUnavailableView {
            Label("搜索弹幕", systemImage: "text.magnifyingglass")
        } description: {
            Text("输入作品名与集数，检索弹弹play网络弹幕库。")
        }
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
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            selectedAnime = anime
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(containsMatch ? Color.accentColor : Color.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(anime.animeTitle ?? "未命名作品")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

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
                                    containsMatch ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.06),
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
                    .foregroundStyle(isCurrentMatch ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.episodeTitle ?? "Episode \(episode.episodeId)")
                        .font(.callout.weight(isCurrentMatch ? .semibold : .regular))
                        .foregroundStyle(isCurrentMatch ? Color.accentColor : Color.primary)
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
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
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
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
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
