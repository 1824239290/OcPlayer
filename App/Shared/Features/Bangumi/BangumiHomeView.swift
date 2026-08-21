import BangumiKit
import SwiftUI

/// Bangumi 功能区首页 = 动画进度管理（在看条目 + 展开的章节网格）。
///
/// 与 OcPlayer 设计系统对齐：
/// - 卡片用 `.background.secondary` + `cardRadius` 圆角（同 PosterCard/StillCard）
/// - 间距用 `railSpacing` / `contentInset`（同 HomeView）
/// - 章节格子展开显示（不再折叠成 30pt 小方块），长按弹菜单切状态
/// - 搜索走 Bangumi 远程（不再本地筛选闪烁）
struct BangumiHomeView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var subjects: [BangumiProgressSubject] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var loadGeneration: UInt64 = 0

    // 搜索：远程搜 Bangumi，不在本地筛选。
    @State private var searchKeyword = ""
    @State private var searchResults: [BangumiSlimSubjectDTO] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration: UInt64 = 0

    var body: some View {
        Group {
            if bangumi.isAuthenticated {
                content
            } else {
                BangumiLoginView()
                    .navigationTitle("Bangumi")
            }
        }
        .onAppear {
            if bangumi.isAuthenticated, subjects.isEmpty {
                Task { await load() }
            }
        }
        .onChange(of: bangumi.isAuthenticated) { _, loggedIn in
            if loggedIn {
                Task { await load() }
            } else {
                subjects = []
                searchResults = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BangumiAPIClient.authenticationRequiredNotification)) { note in
            guard let generation = (note.object as? NSNumber)?.uint64Value else { return }
            Task { @MainActor in
                await BangumiAuthService.invalidateSession(expectedCredentialGeneration: generation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)) { note in
            guard bangumi.isAuthenticated else { return }
            let mayChangeMembership = (note.userInfo?["mayChangeProgressMembership"] as? Bool) ?? false
            let subjectID = (note.object as? NSNumber)?.intValue
            if mayChangeMembership || subjectID == nil {
                Task { await load() }
            } else if let subjectID {
                Task { await reloadSubject(subjectID) }
            }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if !searchKeyword.isEmpty {
            searchView
        } else {
            progressView
        }
    }

    private var progressView: some View {
        Group {
            if isLoading && subjects.isEmpty {
                skeletonView
            } else if let loadError, subjects.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else if subjects.isEmpty {
                ContentUnavailableView {
                    Label("暂无在看条目", systemImage: "play.rectangle")
                } description: {
                    Text("在 Bangumi 上标记「在看」的动画会出现在这里。\n点右上角刷新同步你的收藏。")
                } actions: {
                    Button("刷新") { Task { await refresh(force: true) } }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.railSpacing) {
                        ForEach(subjects) { item in
                            ProgressCard(item: item, reload: { await reloadSubject(item.subject.id) })
                        }
                    }
                    .padding(.horizontal, Metrics.contentLeading)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                }
                .refreshable { await refresh(force: false) }
            }
        }
        .searchable(text: $searchKeyword, prompt: "搜索 Bangumi 条目")
        .navigationTitle("Bangumi")
        .toolbar { toolbar }
        .onChange(of: searchKeyword) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await performSearch(trimmed)
            }
        }
    }

    private var searchView: some View {
        Group {
            if isSearching && searchResults.isEmpty {
                ProgressView("正在搜索…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                ContentUnavailableView.search(text: searchKeyword)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(searchResults) { subject in
                            SearchResultRow(subject: subject)
                        }
                    }
                    .padding(.horizontal, Metrics.contentLeading)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                }
            }
        }
        .searchable(text: $searchKeyword, prompt: "搜索 Bangumi 条目")
        .navigationTitle("搜索")
        .toolbar { toolbar }
    }

    @ViewBuilder
    private var skeletonView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.railSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            SkeletonBlock().frame(width: 56, height: 84)
                            VStack(alignment: .leading, spacing: 6) {
                                SkeletonBlock(cornerRadius: 4).frame(width: 180, height: 16)
                                SkeletonBlock(cornerRadius: 4).frame(width: 120, height: 12)
                            }
                            Spacer()
                        }
                        LazyVGrid(columns: Self.episodeColumns, alignment: .leading, spacing: 6) {
                            ForEach(0..<8, id: \.self) { _ in
                                SkeletonBlock(cornerRadius: 6).frame(height: 28)
                            }
                        }
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                }
            }
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.top, 16)
        }
        .skeletonShimmer()
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !bangumi.isDatabaseReady {
                ProgressView().controlSize(.small)
            }
            if bangumi.isAuthenticated {
                Button {
                    app.path.append(.bangumiProfile)
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .help("个人主页")
            }
            Button {
                Task { await refresh(force: true) }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("刷新所有收藏")
            .disabled(isRefreshing || !bangumi.isDatabaseReady)
        }
    }

    // MARK: - 数据

    static let episodeColumns: [GridItem] = [GridItem(.adaptive(minimum: 40), spacing: 6)]

    private func load() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        defer { if loadGeneration == gen { isLoading = false } }
        do {
            let page = try await bangumi.context.fetchProgressSubjects(
                tab: .anime, sortMode: .collectedAt, search: "",
                episodeWindowSize: 50, limit: 100, offset: 0)
            guard loadGeneration == gen else { return }
            subjects = page.data
        } catch let e as BangumiError {
            guard loadGeneration == gen else { return }
            loadError = e.userMessage
        } catch {
            guard loadGeneration == gen else { return }
            loadError = "\(error)"
        }
    }

    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await bangumi.context.refreshAllCollections(force: force)
            await load()
        } catch let e as BangumiError {
            loadError = e.userMessage
        } catch {
            loadError = "\(error)"
        }
    }

    private func reloadSubject(_ subjectID: Int) async {
        if let updated = try? await bangumi.context.fetchProgressSubject(subjectId: subjectID, episodeWindowSize: 50),
           let idx = subjects.firstIndex(where: { $0.subject.id == subjectID }) {
            subjects[idx] = updated
        }
    }

    private func performSearch(_ keyword: String) async {
        searchGeneration &+= 1
        let gen = searchGeneration
        isSearching = true
        defer { if searchGeneration == gen { isSearching = false } }
        do {
            let page = try await BangumiSubjectService.search(
                keyword: keyword, filter: .anime, limit: 30, offset: 0)
            guard searchGeneration == gen else { return }
            searchResults = page.data
        } catch {
            // 搜索失败静默，用户改词会重试。
        }
    }
}

// MARK: - 进度卡片

/// 单条「在看」动画：封面 + 标题 + 展开的章节网格 + 进度条。
private struct ProgressCard: View {
    let item: BangumiProgressSubject
    var reload: () async -> Void

    @Environment(BangumiCoordinator.self) private var bangumi
    @State private var updatingEpisodeID: Int?

    private var subject: BangumiSubjectDTO { item.subject }
    private var episodes: [BangumiEpisodeDTO] { item.episodes }
    private var mainEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type == .main } }
    private var spEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type == .sp } }
    private var nextEpisode: BangumiEpisodeDTO? { mainEpisodes.first { $0.collectionTypeEnum == .none } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：封面 + 标题 + 进度条
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: coverURL, authHeader: nil)
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(width: 56, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                        .font(.headline)
                        .lineLimit(1)
                    if subject.nameCN != subject.name, !subject.nameCN.isEmpty {
                        Text(subject.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    progressBar
                }
            }

            // 展开的章节网格
            if !mainEpisodes.isEmpty {
                episodeGrid(mainEpisodes)
            }
            if !spEpisodes.isEmpty {
                HStack(spacing: 6) {
                    Text("SP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    episodeGrid(spEpisodes)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            Text(item.progressText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            if let next = nextEpisode {
                Button {
                    Task { await updateEpisode(next, type: .collect) }
                } label: {
                    Label("EP.\(next.sortDisplay)", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(!next.aired || updatingEpisodeID != nil)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private func episodeGrid(_ list: [BangumiEpisodeDTO]) -> some View {
        LazyVGrid(columns: BangumiHomeView.episodeColumns, alignment: .leading, spacing: 6) {
            ForEach(list) { episode in
                EpisodeCell(episode: episode) { type in
                    await updateEpisode(episode, type: type)
                }
            }
        }
    }

    private func updateEpisode(_ episode: BangumiEpisodeDTO, type: BangumiEpisodeCollectionType) async {
        guard updatingEpisodeID == nil else { return }
        updatingEpisodeID = episode.id
        defer { updatingEpisodeID = nil }
        do {
            try await bangumi.context.updateEpisodeCollection(episodeId: episode.id, type: type)
            await reload()
        } catch {}
    }
}

// MARK: - 章节格子

/// 展开的章节格子：集号 + 状态色，长按弹菜单切状态。
private struct EpisodeCell: View {
    let episode: BangumiEpisodeDTO
    var onStatusChange: (BangumiEpisodeCollectionType) async -> Void

    var body: some View {
        Menu {
            ForEach(episode.collectionTypeEnum.otherTypes()) { type in
                Button {
                    Task { await onStatusChange(type) }
                } label: {
                    Label(type.action, systemImage: type.icon)
                }
            }
            if episode.type == .main {
                Divider()
                Button {
                    Task { await onStatusChange(.collect) }
                } label: {
                    Label("看到此集", systemImage: "text.insert")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(episode.sortDisplay)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(foreground)
                Text(episode.collectionTypeEnum == .none ? "未看" : episode.collectionTypeEnum.description)
                    .font(.system(size: 8))
                    .foregroundStyle(foreground.opacity(0.7))
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 1))
        }
        .disabled(!episode.aired)
        .help(helpText)
    }

    private var foreground: Color {
        if !episode.aired { return Color.secondary.opacity(0.4) }
        switch episode.collectionTypeEnum {
        case .collect: return .green
        case .dropped: return .secondary
        case .wish: return .pink
        case .none: return .primary
        }
    }

    private var background: Color {
        if !episode.aired { return Color.secondary.opacity(0.08) }
        switch episode.collectionTypeEnum {
        case .collect: return Color.green.opacity(0.12)
        case .dropped: return Color.secondary.opacity(0.12)
        case .wish: return Color.pink.opacity(0.10)
        case .none: return Color.clear
        }
    }

    private var border: Color {
        switch episode.collectionTypeEnum {
        case .collect: return Color.green.opacity(0.4)
        case .dropped: return Color.secondary.opacity(0.2)
        case .wish: return Color.pink.opacity(0.3)
        case .none: return Color.secondary.opacity(0.15)
        }
    }

    private var helpText: String {
        let name = episode.nameCN.isEmpty ? episode.name : episode.nameCN
        if !episode.aired { return "EP.\(episode.sortDisplay) 未开播" }
        return "EP.\(episode.sortDisplay) \(name)（\(episode.collectionTypeEnum.description)）"
    }
}

// MARK: - 搜索结果行

private struct SearchResultRow: View {
    let subject: BangumiSlimSubjectDTO

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: coverURL, authHeader: nil)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 44, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !subject.nameCN.isEmpty, subject.name != subject.nameCN {
                    Text(subject.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let rating = subject.rating, rating.score > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange)
                        Text(String(format: "%.1f", rating.score))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(subject.type.description)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
}
