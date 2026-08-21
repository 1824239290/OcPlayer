import BangumiKit
import SwiftUI

/// Bangumi 功能区首页 = 动画进度管理（在看条目 + 展开的章节网格）。
///
/// 与 OcPlayer 设计系统对齐：
/// - 卡片用 `.background.secondary` + `cardRadius` 圆角（同 PosterCard/StillCard）
/// - 间距用 `railSpacing` / `contentLeading`（同 HomeView）
/// - 进度条沿用 StillCard 那条中性细轨，不引入新色相
/// - 章节格子是共用组件 `BangumiEpisodeCell`（单击标记，右键切其它状态）
/// - 搜索走 Bangumi 远程（不再本地筛选闪烁）
struct BangumiHomeView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app

    @State private var subjects: [BangumiProgressSubject] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var loadError: String?
    /// 标记章节等写操作的失败文案（以前这些错误是全静默的）。
    @State private var actionError: String?
    @State private var loadGeneration: UInt64 = 0
    /// 已经自动触发过首次同步，避免反复重试。
    @State private var didAutoSync = false

    /// 排序偏好跨启动保留。
    @AppStorage("dev.jumusu.ocplayer.bangumi.progressSort") private var sortRaw = SortOption.collected.rawValue

    // 搜索：远程搜 Bangumi，不在本地筛选。
    @State private var searchKeyword = ""
    @State private var searchResults: [BangumiSlimSubjectDTO] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration: UInt64 = 0

    private enum SortOption: String, CaseIterable, Identifiable {
        case collected
        case air

        var id: String { rawValue }

        var title: String {
            switch self {
            case .collected: "按收藏时间"
            case .air: "按放送时间"
            }
        }

        var mode: BangumiProgressSortMode {
            switch self {
            case .collected: .collectedAt
            case .air: .airTime
            }
        }
    }

    private var sortOption: SortOption { SortOption(rawValue: sortRaw) ?? .collected }

    /// 数据加载的触发键：登录态、建库完成、排序变化都要重新取。
    private var loadKey: String {
        "\(bangumi.isAuthenticated)-\(bangumi.isDatabaseReady)-\(sortRaw)"
    }

    var body: some View {
        Group {
            if bangumi.isAuthenticated {
                content
            } else {
                BangumiLoginView()
                    .navigationTitle("Bangumi")
            }
        }
        .task(id: loadKey) { await loadIfReady() }
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
                        .disabled(isRefreshing)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.railSpacing) {
                        if let actionError {
                            BangumiNotice(message: actionError)
                                .padding(.bottom, 2)
                        }
                        ForEach(subjects) { item in
                            ProgressCard(
                                item: item,
                                reload: { await reloadSubject(item.subject.id) },
                                reportError: { actionError = $0 }
                            )
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
                searchError = nil
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
            } else if let searchError, searchResults.isEmpty {
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(searchError)
                } actions: {
                    Button("重试") {
                        Task { await performSearch(searchKeyword.trimmingCharacters(in: .whitespaces)) }
                    }
                }
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
                        LazyVGrid(columns: BangumiEpisodeCell.columns, alignment: .leading, spacing: 6) {
                            ForEach(0..<8, id: \.self) { _ in
                                SkeletonBlock(cornerRadius: 6).frame(height: 32)
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
            Menu {
                Picker("排序", selection: $sortRaw) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("排序方式：\(sortOption.title)")
            .accessibilityLabel("排序方式")
            .accessibilityValue(sortOption.title)

            Button {
                app.path.append(.bangumiProfile)
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .help("个人主页")
            .accessibilityLabel("个人主页")

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
            .accessibilityLabel("刷新所有收藏")
            .disabled(isRefreshing || !bangumi.isDatabaseReady)
        }
    }

    // MARK: - 数据

    /// 登录 + 建库都就绪才读；首次（从未同步过）自动拉一次，省得让用户先点刷新。
    private func loadIfReady() async {
        guard bangumi.isAuthenticated, bangumi.isDatabaseReady else {
            subjects = []
            searchResults = []
            return
        }
        // 打开这一页才校验登录态（App 启动时不发请求）。
        bangumi.revalidateSessionIfNeeded()
        await load()
        guard !didAutoSync, subjects.isEmpty,
              bangumi.context.store.collectionsUpdatedAt == 0
        else { return }
        didAutoSync = true
        await refresh(force: false)
    }

    private func load() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        defer { if loadGeneration == gen { isLoading = false } }
        do {
            let page = try await bangumi.context.fetchProgressSubjects(
                tab: .anime, sortMode: sortOption.mode, search: "",
                episodeWindowSize: 50, limit: 100, offset: 0)
            guard loadGeneration == gen else { return }
            subjects = page.data
        } catch let e as BangumiError {
            guard loadGeneration == gen else { return }
            loadError = e.userMessage
            BangumiDiagnostics.log("进度页加载失败 error=\(e)")
        } catch {
            guard loadGeneration == gen else { return }
            loadError = "\(error)"
            BangumiDiagnostics.log("进度页加载失败 error=\(error)")
        }
    }

    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await bangumi.refreshCollections(force: force)
            actionError = nil
            await load()
        } catch let e as BangumiError {
            loadError = e.userMessage
            actionError = e.userMessage
            BangumiDiagnostics.log("同步收藏失败 error=\(e)")
        } catch {
            loadError = "\(error)"
            actionError = "\(error)"
            BangumiDiagnostics.log("同步收藏失败 error=\(error)")
        }
    }

    private func reloadSubject(_ subjectID: Int) async {
        guard let updated = try? await bangumi.context.fetchProgressSubject(
            subjectId: subjectID, episodeWindowSize: 50)
        else { return }
        guard let idx = subjects.firstIndex(where: { $0.subject.id == subjectID }) else { return }
        subjects[idx] = updated
    }

    private func performSearch(_ keyword: String) async {
        guard !keyword.isEmpty else { return }
        searchGeneration &+= 1
        let gen = searchGeneration
        isSearching = true
        searchError = nil
        defer { if searchGeneration == gen { isSearching = false } }
        do {
            let page = try await BangumiSubjectService.search(
                keyword: keyword, filter: .anime, limit: 30, offset: 0)
            guard searchGeneration == gen else { return }
            searchResults = page.data
        } catch let e as BangumiError {
            guard searchGeneration == gen else { return }
            if case .ignore = e { return }   // 请求被新输入取消，不是错误
            searchError = e.userMessage
            BangumiDiagnostics.log("搜索条目失败 error=\(e)")
        } catch {
            guard searchGeneration == gen else { return }
            searchError = "\(error)"
            BangumiDiagnostics.log("搜索条目失败 error=\(error)")
        }
    }
}

// MARK: - 进度卡片

/// 单条「在看」动画：封面 + 标题 + 进度条 + 展开的章节网格。
private struct ProgressCard: View {
    let item: BangumiProgressSubject
    var reload: () async -> Void
    var reportError: (String?) -> Void

    @Environment(BangumiCoordinator.self) private var bangumi
    @State private var updatingEpisodeID: Int?

    private var subject: BangumiSubjectDTO { item.subject }
    private var mainEpisodes: [BangumiEpisodeDTO] { item.episodes.filter { $0.type == .main } }
    private var spEpisodes: [BangumiEpisodeDTO] { item.episodes.filter { $0.type == .sp } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !mainEpisodes.isEmpty {
                episodeGrid(mainEpisodes)
            }
            if !spEpisodes.isEmpty {
                Text("SP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                episodeGrid(spEpisodes)
            }
            if !item.hasEpisodeData {
                // 章节还没同步下来：明确说出来，别让空网格看着像「没有剧集」。
                Text("章节尚未同步，下拉或点右上角刷新")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: coverURL, authHeader: nil)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                    .font(.headline)
                    .lineLimit(1)
                if !subject.nameCN.isEmpty, subject.nameCN != subject.name {
                    Text(subject.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                progressRow
            }
        }
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.progressText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                nextAction
            }
            if let fraction = item.progressFraction {
                progressTrack(fraction)
            }
        }
    }

    /// 中性细轨，与 StillCard 的进度条同一套（`primary` 透明度，不用色相）。
    private func progressTrack(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
    }

    @ViewBuilder
    private var nextAction: some View {
        if let next = item.nextEpisode {
            Button {
                Task { await perform(.set(.collect), on: next) }
            } label: {
                Label("看完 \(next.sortDisplay)", systemImage: "checkmark.circle")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(!next.aired || updatingEpisodeID != nil)
            .help(next.aired ? "把 EP.\(next.sortDisplay) 标记为看过" : "EP.\(next.sortDisplay) 还没开播")
        } else if item.isFinished {
            Label("已看完", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if item.hasEpisodeData {
            // 有章节但没有「下一集」：剩下的都还没开播。
            Text("等待更新")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private func episodeGrid(_ list: [BangumiEpisodeDTO]) -> some View {
        LazyVGrid(columns: BangumiEpisodeCell.columns, alignment: .leading, spacing: 6) {
            ForEach(list) { episode in
                BangumiEpisodeCell(
                    episode: episode,
                    isBusy: updatingEpisodeID == episode.id
                ) { action in
                    await perform(action, on: episode)
                }
            }
        }
    }

    private func perform(_ action: BangumiEpisodeAction, on episode: BangumiEpisodeDTO) async {
        guard updatingEpisodeID == nil else { return }
        updatingEpisodeID = episode.id
        defer { updatingEpisodeID = nil }
        do {
            switch action {
            case .set(let type):
                try await bangumi.context.updateEpisodeCollection(
                    episodeId: episode.id, type: type)
            case .markUpTo:
                try await bangumi.context.updateEpisodeCollection(
                    episodeId: episode.id, type: .collect, batch: true)
            }
            reportError(nil)
            await reload()
        } catch let e as BangumiError {
            reportError(e.userMessage)
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(e)")
        } catch {
            reportError("\(error)")
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(error)")
        }
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
                        Image(systemName: "star.fill").font(.caption2)
                        Text(String(format: "%.1f", rating.score)).font(.caption)
                    }
                    .foregroundStyle(.secondary)
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
