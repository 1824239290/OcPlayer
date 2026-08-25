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
        NavigationStack {
            VStack(spacing: 0) {
                searchHeader

                Divider()

                contentView
            }
            .navigationTitle("选择弹幕")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 480, idealHeight: 560)
        #endif
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

    // MARK: - 搜索栏与状态条

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 输入行：作品名 + 集数 + 搜索按钮
            HStack(spacing: 10) {
                // 作品名输入框
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(focusedField == .anime ? Color.accentColor : Color.secondary)
                    TextField("作品名（如：葬送的芙莉莲）", text: $animeQuery)
                        .textFieldStyle(.plain)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            focusedField == .anime ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                )

                // 集数输入框
                HStack(spacing: 4) {
                    TextField("集数（可选）", text: $episodeQuery)
                        .textFieldStyle(.plain)
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
                .padding(.vertical, 7)
                #if os(macOS)
                .frame(width: 120)
                #else
                .frame(maxWidth: 110)
                #endif
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            focusedField == .episode ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                )

                // 搜索按钮
                Button(action: startSearch) {
                    Label("搜索", systemImage: "magnifyingglass")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSearching || animeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 当前状态与匹配指示
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 6, height: 6)
                    Text("弹幕状态：\(danmakuModel.danmaku.status.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let match = danmakuModel.danmaku.currentMatch {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text(verbatim: "已关联 Episode \(match.episodeID)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
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
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    // MARK: - 结果内容区

    @ViewBuilder
    private var contentView: some View {
        if isSearching && results.isEmpty {
            VStack(spacing: 12) {
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
            resultsList
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

    private var resultsList: some View {
        List {
            ForEach(validAnimeResults, id: \.animeId) { anime in
                Section {
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
                } header: {
                    HStack(spacing: 8) {
                        Text(anime.animeTitle ?? "未命名作品")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let typeDesc = anime.typeDescription ?? anime.type, !typeDesc.isEmpty {
                            Text(typeDesc)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }

                        Spacer()

                        Text("共 \(anime.episodes.count) 集")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
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
                        .font(.body.weight(isCurrentMatch ? .semibold : .regular))
                        .foregroundStyle(isCurrentMatch ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(verbatim: "ID \(episode.episodeId)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                if isCurrentMatch {
                    Text("当前匹配")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .hoverRowHighlight(active: isHovered)
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
