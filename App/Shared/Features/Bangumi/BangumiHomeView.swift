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
    @Environment(\.contentLeading) private var contentLeading

    @State private var subjects: [BangumiProgressSubject] = []
    /// 服务端/本地库里「在看」的总条数。分页要靠它判断还有没有下一页——
    /// 原来只取第一页 100 条、`total` 拿到手就丢了，攒到 100 条以上就是静默截断。
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var isRefreshing = false
    @State private var loadError: String?
    /// 标记章节等写操作的失败文案（以前这些错误是全静默的）。
    @State private var actionError: String?
    @State private var loadGeneration: UInt64 = 0
    /// 已经自动触发过首次同步，避免反复重试。
    @State private var didAutoSync = false

    /// 一页的条数。首屏不再一次拉 100 条：每条要额外查一遍章节窗口，
    /// 100 条就是几千行章节 + 上千次 JSON 解码，全在一次 await 里做完。
    private static let pageSize = 30
    /// 章节窗口大小。进度卡要把整季的格子铺出来，所以给得比「窗口」这个词大。
    private static let episodeWindowSize = 50

    private var hasMore: Bool { subjects.count < totalCount }

    /// 排序偏好跨启动保留。
    @AppStorage("dev.jumusu.ocplayer.bangumi.progressSort") private var sortRaw = SortOption.collected.rawValue

    // 搜索：远程搜 Bangumi，支持分类筛选与分页
    @State private var searchKeyword = ""
    @State private var submittedSearchKeyword = ""
    @State private var searchTypeFilter: BangumiSubjectType = .none
    @State private var searchResults: [BangumiSlimSubjectDTO] = []
    @State private var searchTotalCount = 0
    @State private var isSearching = false
    @State private var isSearchingMore = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration: UInt64 = 0

    private var hasMoreSearchResults: Bool { searchResults.count < searchTotalCount }

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
        Group {
            if !submittedSearchKeyword.isEmpty {
                searchView
            } else {
                progressView
            }
        }
        .searchable(text: $searchKeyword, prompt: "搜索 Bangumi 条目")
        .onSubmit(of: .search) {
            let trimmed = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                submittedSearchKeyword = ""
                searchResults = []
                isSearching = false
                searchError = nil
                return
            }
            submittedSearchKeyword = trimmed
            searchTask?.cancel()
            searchTask = Task { await performSearch(trimmed) }
        }
        .onChange(of: searchKeyword) { _, newValue in
            if newValue.isEmpty {
                submittedSearchKeyword = ""
                searchResults = []
                isSearching = false
                searchError = nil
                searchTask?.cancel()
            }
        }
        .onChange(of: searchTypeFilter) { _, _ in
            let trimmed = submittedSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            searchTask?.cancel()
            searchTask = Task { await performSearch(trimmed) }
        }
        .navigationTitle("Bangumi")
        #if os(macOS)
        .navigationSubtitle(progressSubtitle)
        #endif
        .toolbar { toolbar }
    }

    private var progressView: some View {
        Group {
            if isLoading && subjects.isEmpty {
                skeletonView
            } else if let loadError, subjects.isEmpty {
                ContentUnavailableView {
                    Label(UIStrings.loadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(UIStrings.retry) { Task { await load() } }
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
                        if hasMore || isLoadingMore {
                            loadMoreFooter
                        }
                    }
                    .padding(.horizontal, contentLeading)
                    .padding(.top, 16)
                    .padding(.bottom, 48)
                }
                .refreshable { await refresh(force: false) }
            }
        }
    }

    /// macOS 副标题：在看数或搜索结果数。
    private var progressSubtitle: String {
        if !submittedSearchKeyword.isEmpty {
            if isSearching {
                return "正在搜索…"
            } else if searchTotalCount > 0 {
                return "找到 \(searchTotalCount) 个条目"
            }
            return ""
        }
        guard totalCount > 0 else { return "" }
        if subjects.count < totalCount {
            return "在看 \(subjects.count) / \(totalCount)"
        }
        return "在看 \(totalCount)"
    }

    /// 分页尾部：进入可视区自动预取下一页（同 LibraryView）。
    private var loadMoreFooter: some View {
        VStack(spacing: 10) {
            if isLoadingMore {
                ProgressView().controlSize(.regular)
            } else {
                Button(UIStrings.loadMore) { Task { await loadMore() } }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onAppear {
            guard hasMore, !isLoading, !isLoadingMore else { return }
            Task { await loadMore() }
        }
    }

    private var searchView: some View {
        VStack(spacing: 0) {
            searchHeader

            Group {
                if isSearching && searchResults.isEmpty {
                    searchSkeletonView
                } else if let searchError, searchResults.isEmpty {
                    ContentUnavailableView {
                        Label(UIStrings.searchFailed, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(searchError)
                    } actions: {
                        HStack(spacing: 12) {
                            Button(UIStrings.retry) {
                                Task { await performSearch(submittedSearchKeyword.trimmingCharacters(in: .whitespaces)) }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("返回在看") {
                                exitSearchMode()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    ContentUnavailableView {
                        Label("未找到相关条目", systemImage: "magnifyingglass")
                    } description: {
                        Text("未找到与「\(submittedSearchKeyword)」相关的 \(searchTypeFilter.description) 条目。\n可以尝试缩短关键词或切换分类。")
                    } actions: {
                        Button("返回在看") {
                            exitSearchMode()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(searchResults) { subject in
                                NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id, initialSubject: subject)) {
                                    SearchResultRow(subject: subject)
                                }
                                .buttonStyle(.plain)
                            }
                            if hasMoreSearchResults || isSearchingMore {
                                searchLoadMoreFooter
                            }
                        }
                        .padding(.horizontal, contentLeading)
                        .padding(.top, 4)
                        .padding(.bottom, 48)
                    }
                }
            }
        }
    }

    /// 退出搜索模式的统一清理（原先三处各抄一份，字段清单已经漂移）。
    private func exitSearchMode() {
        searchTask?.cancel()
        searchKeyword = ""
        submittedSearchKeyword = ""
        searchResults = []
        isSearching = false
        searchError = nil
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button {
                exitSearchMode()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("返回在看")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.tertiary, in: Capsule())
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("退出搜索并返回在看条目列表")

            Divider()
                .frame(height: 16)

            searchTypePicker
        }
        .padding(.horizontal, contentLeading)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var searchTypePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let types: [BangumiSubjectType] = [.none, .anime, .book, .game, .music, .real]
                ForEach(types) { type in
                    searchFilterChip(type: type)
                }
            }
        }
    }

    private func searchFilterChip(type: BangumiSubjectType) -> some View {
        let isSelected = searchTypeFilter == type
        return Button {
            guard searchTypeFilter != type else { return }
            // 搜索请求统一走 onChange(of: searchTypeFilter)；这里再起 Task 会
            // 和它各搜一份（且用的是未提交的 searchKeyword），双份请求互竞代次。
            searchTypeFilter = type
        } label: {
            HStack(spacing: 5) {
                if type != .none {
                    Image(systemName: type.icon)
                        .font(.system(size: 10))
                }
                Text(type.description)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var searchSkeletonView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 14) {
                        SkeletonBlock(cornerRadius: 8)
                            .frame(width: 58, height: 84)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(cornerRadius: 4).frame(width: 180, height: 16)
                            SkeletonBlock(cornerRadius: 4).frame(width: 120, height: 12)
                            SkeletonBlock(cornerRadius: 4).frame(width: 90, height: 12)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, 4)
        }
        .skeletonShimmer()
    }

    private var searchLoadMoreFooter: some View {
        VStack(spacing: 10) {
            if isSearchingMore {
                ProgressView().controlSize(.regular)
            } else {
                Button(UIStrings.loadMore) { Task { await searchMore() } }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onAppear {
            guard hasMoreSearchResults, !isSearching, !isSearchingMore else { return }
            Task { await searchMore() }
        }
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
            .padding(.horizontal, contentLeading)
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
            Button {
                app.path.append(.bangumiCalendar)
            } label: {
                Image(systemName: "calendar")
            }
            .help("每日放送：查看本季度番剧时间表")
            .accessibilityLabel("每日放送")

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
                episodeWindowSize: Self.episodeWindowSize,
                limit: Self.pageSize, offset: 0)
            guard loadGeneration == gen else { return }
            subjects = page.data
            totalCount = page.total
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

    /// 追加下一页。`loadGeneration` 不动——它是「整份重取」的代次，
    /// 翻页只往后接，用它做守卫就够了（中途发生重取会让代次变化，这一页被丢掉）。
    private func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let gen = loadGeneration
        let offset = subjects.count
        isLoadingMore = true
        defer { if loadGeneration == gen { isLoadingMore = false } }
        do {
            let page = try await bangumi.context.fetchProgressSubjects(
                tab: .anime, sortMode: sortOption.mode, search: "",
                episodeWindowSize: Self.episodeWindowSize,
                limit: Self.pageSize, offset: offset)
            guard loadGeneration == gen else { return }
            // 去重追加：本地库在两次分页之间可能被同步改过，同一条目可能重复出现。
            let existing = Set(subjects.map(\.subject.id))
            subjects.append(contentsOf: page.data.filter { !existing.contains($0.subject.id) })
            totalCount = page.total
        } catch let e as BangumiError {
            guard loadGeneration == gen else { return }
            actionError = e.userMessage
            BangumiDiagnostics.log("进度页翻页失败 offset=\(offset) error=\(e)")
        } catch {
            guard loadGeneration == gen else { return }
            actionError = "\(error)"
            BangumiDiagnostics.log("进度页翻页失败 offset=\(offset) error=\(error)")
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
        if let updated = try? await bangumi.context.fetchProgressSubject(
            subjectId: subjectID, episodeWindowSize: Self.episodeWindowSize) {
            if let idx = subjects.firstIndex(where: { $0.subject.id == subjectID }) {
                subjects[idx] = updated
            }
        } else {
            // 条目已离开「在看」状态，直接从列表移除
            subjects.removeAll { $0.subject.id == subjectID }
        }
    }

    private func performSearch(_ keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchGeneration &+= 1
        let gen = searchGeneration
        isSearching = true
        searchError = nil
        defer { if searchGeneration == gen { isSearching = false } }
        do {
            let filter = searchTypeFilter == .none ? nil : searchTypeFilter
            let page = try await BangumiSubjectService.search(
                keyword: trimmed,
                filter: filter,
                limit: 30,
                offset: 0
            )
            guard searchGeneration == gen else { return }
            searchResults = page.data
            searchTotalCount = page.total
        } catch let e as BangumiError {
            guard searchGeneration == gen else { return }
            if case .ignore = e { return }   // 请求被新输入取消，不是错误
            searchError = e.userMessage
            BangumiDiagnostics.log("搜索条目失败 error=\(e)")
        } catch is CancellationError {
            // Task 取消时忽略
        } catch {
            guard searchGeneration == gen else { return }
            if (error as NSError).code == NSURLErrorCancelled { return }
            searchError = "搜索失败：\(error.localizedDescription)"
            BangumiDiagnostics.log("搜索条目失败 error=\(error)")
        }
    }

    private func searchMore() async {
        guard hasMoreSearchResults, !isSearching, !isSearchingMore else { return }
        let gen = searchGeneration
        let offset = searchResults.count
        isSearchingMore = true
        defer { if searchGeneration == gen { isSearchingMore = false } }
        let trimmed = submittedSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let page = try await BangumiSubjectService.search(
                keyword: trimmed,
                filter: searchTypeFilter == .none ? nil : searchTypeFilter,
                limit: 30,
                offset: offset
            )
            guard searchGeneration == gen else { return }
            let existing = Set(searchResults.map(\.id))
            searchResults.append(contentsOf: page.data.filter { !existing.contains($0.id) })
            searchTotalCount = page.total
        } catch {
            BangumiDiagnostics.log("搜索翻页失败 offset=\(offset) error=\(error)")
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
    @State private var updatingStatus = false

    private var subject: BangumiSubjectDTO { item.subject }

    /// 本篇 / SP 分组只算一次。`body` 会因为 `updatingEpisodeID` 变化重算，
    /// 而窗口最多 50 集——原来 `mainEpisodes` / `spEpisodes` 是 computed property，
    /// 一次 body 里各被读两遍（判空 + 传给网格），等于每次重算扫四遍数组。
    private var partitioned: (main: [BangumiEpisodeDTO], sp: [BangumiEpisodeDTO]) {
        var main: [BangumiEpisodeDTO] = []
        var sp: [BangumiEpisodeDTO] = []
        for episode in item.episodes {
            switch episode.type {
            case .main: main.append(episode)
            case .sp: sp.append(episode)
            default: break
            }
        }
        return (main, sp)
    }

    var body: some View {
        let episodes = partitioned
        return VStack(alignment: .leading, spacing: 10) {
            header
            if !episodes.main.isEmpty {
                episodeGrid(episodes.main)
            }
            if !episodes.sp.isEmpty {
                Text("SP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                episodeGrid(episodes.sp)
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
            NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                RemoteImage(url: coverURL, authHeader: nil, maxPixelSize: 300)
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(width: 56, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if !subject.nameCN.isEmpty, subject.nameCN != subject.name {
                            Text(subject.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
                progressRow
            }
            // 条目（整季）状态放标题区右上角——放集级进度旁边会被误读成集操作。
            statusMenu
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

    /// 条目（整季）收藏状态手动改：卡片右上角徽章式菜单，
    /// 想看/在看/看过/搁置/抛弃，当前状态打勾。切走「在看」后条目
    /// 离开进度列表（membership 失效）。
    private var statusMenu: some View {
        let current = subject.interest?.type ?? .none
        return Menu {
            ForEach(BangumiCollectionType.allTypes()) { type in
                Button {
                    Task { await setSubjectStatus(type) }
                } label: {
                    if type == current {
                        Label(Self.statusLabel(type), systemImage: "checkmark")
                    } else {
                        Text(Self.statusLabel(type))
                    }
                }
            }
        } label: {
            Text(Self.statusLabel(current))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .disabled(updatingStatus)
        .help("更改这部作品的收藏状态")
    }

    private static func statusLabel(_ type: BangumiCollectionType) -> String {
        // 复用 CollectionType.description 的文案源，不再两处各自维护。
        // description(nil) 对 .none 返回「全部」，这里要的是「未收藏」，单独兜。
        type == .none ? "未收藏" : type.description(nil)
    }

    private func setSubjectStatus(_ type: BangumiCollectionType) async {
        updatingStatus = true
        defer { updatingStatus = false }
        do {
            try await bangumi.context.updateSubjectCollection(
                subjectId: subject.id, type: type)
        } catch let e as BangumiError {
            reportError(e.userMessage)
            BangumiDiagnostics.log("手动改条目状态失败 subject=\(subject.id) error=\(e)")
        } catch {
            reportError("状态更新失败：\(error)")
            BangumiDiagnostics.log("手动改条目状态失败 subject=\(subject.id) error=\(error)")
        }
    }

    /// 中性细轨，与 StillCard 的进度条同一套（`primary` 透明度，不用色相）。
    ///
    /// 这里的 GeometryReader 是**留着的**：宽度是真动态的（卡片剩余宽度取决于
    /// 封面宽 + 两处 spacing + 卡片 padding + 窗口宽），从那堆常量倒推比测一下更脆。
    /// 相比之下 `EpisodeSelectCard` / 详情页播放钮的宽度是写死的常量，那两处已改成直接乘。
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
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: coverURL, authHeader: nil, maxPixelSize: 300)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 58, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if !subject.nameCN.isEmpty, subject.name != subject.nameCN {
                        Text(subject.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    typeBadge(subject.type)

                    if let rating = subject.rating, rating.score > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(BangumiStatusColor.rating)
                            Text(String(format: "%.1f", rating.score))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(BangumiStatusColor.rating)
                        }
                        if let rank = subject.rating?.rank, rank > 0 {
                            Text("#\(rank)")
                                .font(.system(size: 10).weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(BangumiStatusColor.rating.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(BangumiStatusColor.rating)
                        }
                    }

                    if let interest = subject.interest, interest.type != .none {
                        Text(interest.type.description(subject.type))
                            .font(.system(size: 10).weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }

                if let info = subject.info, !info.isEmpty {
                    Text(info)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(12)
        .hoverRowHighlight(active: isHovered)
        .onHover { isHovered = $0 }
    }

    private func typeBadge(_ type: BangumiSubjectType) -> some View {
        let color = BangumiStatusColor.subject(type)
        return Text(type.description)
            .font(.system(size: 10).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
}
