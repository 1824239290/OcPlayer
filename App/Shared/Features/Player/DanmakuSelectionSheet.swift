import DanmakuKit
import SwiftUI

struct DanmakuSelectionSheet: View {
    @Environment(DanmakuModel.self) private var danmakuModel
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        NavigationStack {
            List {
                Section("搜索") {
                    TextField("作品名", text: $animeQuery)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { startSearch() }
                        .onChange(of: animeQuery) { invalidateChangedSearch() }
                    HStack {
                        TextField("集数（可选）", text: $episodeQuery)
                            .onSubmit { startSearch() }
                            .onChange(of: episodeQuery) { invalidateChangedSearch() }
                        Button("搜索", systemImage: "magnifyingglass") {
                            startSearch()
                        }
                        .disabled(isSearching || animeQuery.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                    }
                }

                Section("当前状态") {
                    LabeledContent("弹幕", value: danmakuModel.danmaku.status.label)
                    if let match = danmakuModel.danmaku.currentMatch {
                        LabeledContent("Episode ID", value: String(match.episodeID))
                    }
                }

                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在搜索")
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "搜索失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if hasSearched && results.isEmpty {
                    ContentUnavailableView.search(text: animeQuery)
                } else {
                    ForEach(results, id: \.animeId) { anime in
                        Section(anime.animeTitle ?? "未命名作品") {
                            ForEach(anime.episodes) { episode in
                                Button {
                                    if let requestID {
                                        danmakuModel.danmaku.selectEpisode(
                                            episode,
                                            animeTitle: anime.animeTitle,
                                            for: requestID
                                        )
                                    }
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(episode.episodeTitle ?? "Episode \(episode.episodeId)")
                                                .foregroundStyle(.primary)
                                            Text(verbatim: "ID \(episode.episodeId)")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 12)
                                        if danmakuModel.danmaku.currentMatch?.episodeID == episode.episodeId {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(episode.episodeTitle ?? "Episode \(episode.episodeId)")
                                .accessibilityValue(
                                    danmakuModel.danmaku.currentMatch?.episodeID == episode.episodeId
                                        ? "当前选择" : ""
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择弹幕")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
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

private struct SearchRequest: Hashable {
    let id = UUID()
    let anime: String
    let episode: String
}
