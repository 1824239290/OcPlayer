import MoviePilotKit
import SwiftUI

/// MoviePilot 分区首页：
/// - 统一且规范的海报网格布局（每个卡片严格锁定 2:3 标准比例，告别海报大小不一）
/// - 自适应响应式网格列宽（最小 180pt，列间距 20pt，行间距 28pt，留白充裕不拥挤）
/// - 默认展示当前订阅列表（全部 / 电影 / 剧集分类切换、追更进度条、状态徽章、上下文操作）
/// - 完整支持「新建订阅」与「编辑修改订阅」弹窗（遵循 MoviePilot 规范）
/// - 搜索栏输入关键词后聚合搜索多源媒体，支持一键/高级订阅与站点资源下载
/// - 右上角常驻下载管理、添加订阅与全站刷新追更菜单
struct MoviePilotHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - 订阅状态
    @State private var subscribes: [MPSubscribe] = []
    @State private var isLoadingSubscribes = false
    @State private var subscribesError: String?
    @State private var selectedCategory: SubscribeCategory = .all
    @State private var pendingDeleteSubscribe: MPSubscribe?
    @State private var editingSubscribe: MPSubscribe?
    @State private var isPresentingAddSheet = false
    @State private var sheetMedia: MPMediaInfo?

    // MARK: - 搜索状态
    @State private var keyword = ""
    @State private var submittedKeyword = ""
    @State private var isSearching = false
    @State private var results: [MPMediaInfo] = []
    @State private var searchError: String?
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var subscribingMediaIDs: Set<String> = []
    @State private var localSubscribedMediaIDs: Set<String> = []
    /// 当前订阅/搜索缓存属于哪台服务器（coordinator.boundServerID），用于换服时作废。
    @State private var loadedForServerID: String?

    // MARK: - 提示信息
    @State private var notice: String?
    @State private var isNoticeError = false

    private enum SubscribeCategory: String, CaseIterable, Identifiable {
        case all = "全部"
        case movie = "电影"
        case tv = "剧集"

        var id: String { rawValue }
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    /// 规范化的自适应网格列：
    /// - 窄屏/手机：2 列等宽自适应
    /// - 宽屏/Mac：自适应列宽（最小 180pt，最大 240pt），确保大图呼吸感，避免卡片挤成一团
    private var gridColumns: [GridItem] {
        if isCompact {
            return [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ]
        }
        return [
            GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20)
        ]
    }

    private var gridRowSpacing: CGFloat {
        isCompact ? 18 : 28
    }

    var body: some View {
        Group {
            if !moviepilot.store.isConfigured {
                gate(
                    "未配置 MoviePilot",
                    icon: "arrow.down.circle",
                    hint: "在 设置 → MoviePilot 填写服务器地址与账号"
                )
            } else if !moviepilot.isAuthenticated {
                gate(
                    "未登录",
                    icon: "person.crop.circle.badge.exclamationmark",
                    hint: "在 设置 → MoviePilot 登录后即可管理订阅与下载"
                )
            } else {
                mainContent
            }
        }
        .navigationTitle("MoviePilot")
        #if os(macOS)
        .navigationSubtitle(navigationSubtitleText)
        #endif
    }

    private var navigationSubtitleText: String {
        if isSearchingMode {
            return results.isEmpty ? "" : "搜索结果 \(results.count) 条"
        }
        return subscribes.isEmpty ? "" : "已订阅 \(subscribes.count) 部 · \(watchingCount) 部追更中"
    }

    // MARK: - 门控

    private func gate(_ title: String, icon: String, hint: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(hint)
        } actions: {
            Button("去设置") { app.selectedSection = .settings }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 主体内容

    private var isSearchingMode: Bool {
        !submittedKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var mainContent: some View {
        Group {
            if isSearchingMode {
                searchResultsView
            } else {
                subscriptionsView
            }
        }
        .searchable(text: $keyword, prompt: Text("搜索电影、电视剧、番剧…"))
        .onSubmit(of: .search) {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                submittedKeyword = ""
                results = []
                isSearching = false
                searchError = nil
                return
            }
            submittedKeyword = trimmed
            search()
        }
        .onChange(of: keyword) { _, newValue in
            if newValue.isEmpty {
                submittedKeyword = ""
                results = []
                isSearching = false
                searchError = nil
                searchTask?.cancel()
                searchGeneration += 1
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    sheetMedia = nil
                    isPresentingAddSheet = true
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }

                NavigationLink {
                    MoviePilotDownloadsView()
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }

                Menu {
                    Button {
                        Task { await loadSubscribes() }
                    } label: {
                        Label("刷新订阅列表", systemImage: "arrow.clockwise")
                    }

                    Button {
                        Task { await triggerRefreshSubscribes() }
                    } label: {
                        Label("向服务器请求刷新", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        Task { await triggerSearchSubscribes() }
                    } label: {
                        Label("执行全站追更检索", systemImage: "magnifyingglass.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: moviepilot.boundServerID) {
            // iOS 上 tab 保活：换绑另一台 MP 服务器后本页 @State 不销毁，
            // 旧服务器的订阅/搜索残留。绑定标识变化（登出后重绑、换一台）即整体作废；
            // 回到同一台服务器则保留数据，避免每次切回 tab 都重拉。
            if loadedForServerID != moviepilot.boundServerID {
                resetServerScopedState()
                loadedForServerID = moviepilot.boundServerID
            }
            // Bangumi 详情页「MoviePilot下载」带过来的搜索词：取走即清，发起一次搜索。
            if let pending = app.pendingMoviePilotQuery {
                app.pendingMoviePilotQuery = nil
                submittedKeyword = pending
                search()
            }
            if subscribes.isEmpty {
                await loadSubscribes()
            }
        }
        .sheet(isPresented: $isPresentingAddSheet) {
            MoviePilotSubscribeSheet(mode: .add(media: sheetMedia)) {
                Task { await loadSubscribes() }
            }
        }
        .sheet(item: $editingSubscribe) { subscribe in
            MoviePilotSubscribeSheet(mode: .edit(subscribe: subscribe)) {
                Task { await loadSubscribes() }
            }
        }
        .confirmationDialog(
            "取消订阅？",
            isPresented: Binding(
                get: { pendingDeleteSubscribe != nil },
                set: { if !$0 { pendingDeleteSubscribe = nil } }
            ),
            presenting: pendingDeleteSubscribe
        ) { subscribe in
            Button("取消订阅「\(subscribe.name ?? "该条目")」", role: .destructive) {
                Task { await deleteSubscribe(subscribe) }
            }
        } message: { _ in
            Text("取消订阅后，MoviePilot 将停止自动检索和下载后续更新。已下载的文件不会被删除。")
        }
    }

    // MARK: - 订阅主视图

    private var subscriptionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let notice {
                    noticeBanner(notice, isError: isNoticeError)
                        .padding(.horizontal, contentLeading)
                        .padding(.top, 12)
                }

                // 顶部控制栏（分类切换 + 状态统计 + 快捷添加）
                headerControlBar
                    .padding(.horizontal, contentLeading)
                    .padding(.top, 16)
                    .padding(.bottom, 22)

                if isLoadingSubscribes && subscribes.isEmpty {
                    skeletonGrid
                } else if let subscribesError, subscribes.isEmpty {
                    ContentUnavailableView {
                        Label("加载订阅失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(subscribesError)
                    } actions: {
                        Button(UIStrings.retry) { Task { await loadSubscribes() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .padding(.top, 40)
                } else if displayedSubscribes.isEmpty {
                    emptySubscriptionsView
                } else {
                    subscriptionsGrid
                        .padding(.horizontal, contentLeading)
                        .padding(.bottom, 36)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .refreshable {
            await loadSubscribes()
        }
    }

    private var headerControlBar: some View {
        HStack(spacing: 16) {
            Picker("分类", selection: $selectedCategory) {
                Text("全部 (\(subscribes.count))").tag(SubscribeCategory.all)
                Text("电影 (\(movieCount))").tag(SubscribeCategory.movie)
                Text("剧集 (\(tvCount))").tag(SubscribeCategory.tv)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            if !subscribes.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(watchingCount) 部追更中")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.quaternary, in: Capsule())
            }
        }
    }

    private var emptySubscriptionsView: some View {
        ContentUnavailableView {
            Label(
                selectedCategory == .all ? "暂无 MoviePilot 订阅" : "暂无\(selectedCategory.rawValue)订阅",
                systemImage: "film.stack"
            )
        } description: {
            Text(
                selectedCategory == .all
                    ? "在上方搜索框搜索电影或电视剧，即可一键加入订阅自动追更和下载；也可以点击下方按钮手动配置。"
                    : "当前分类下没有订阅。可切换分类浏览或添加新订阅。"
            )
        } actions: {
            HStack(spacing: 12) {
                Button("添加订阅") {
                    sheetMedia = nil
                    isPresentingAddSheet = true
                }
                .buttonStyle(.borderedProminent)

                Button("刷新") {
                    Task { await loadSubscribes() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.top, 40)
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
            ForEach(0..<10, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock()
                        .aspectRatio(2 / 3, contentMode: .fit)
                    SkeletonBlock(cornerRadius: 4)
                        .frame(height: 14)
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 80, height: 12)
                }
            }
        }
        .padding(.horizontal, contentLeading)
        .padding(.bottom, 28)
        .skeletonShimmer()
    }

    private var subscriptionsGrid: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
            ForEach(displayedSubscribes) { subscribe in
                MoviePilotSubscribeCard(
                    subscribe: subscribe,
                    onEdit: { editingSubscribe = subscribe },
                    onDelete: { pendingDeleteSubscribe = subscribe },
                    onRefresh: { Task { await triggerRefreshSubscribes() } }
                )
            }
        }
    }

    // MARK: - 搜索结果视图

    private var searchResultsView: some View {
        Group {
            if isSearching && results.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在搜索媒体…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchError, results.isEmpty {
                ContentUnavailableView {
                    Label(UIStrings.searchFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(searchError)
                } actions: {
                    Button(UIStrings.retry, action: search)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: submittedKeyword)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let notice {
                            noticeBanner(notice, isError: isNoticeError)
                                .padding(.top, 8)
                        }

                        if isSearching {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在更新搜索结果…")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                            .padding(.vertical, 4)
                        } else if let searchError {
                            Text(searchError)
                                .foregroundStyle(.red)
                                .font(.callout)
                                .padding(.vertical, 4)
                        }

                        // 媒体结果标题与数量统计
                        HStack(spacing: 8) {
                            Text("媒体结果")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)

                            Text("\(results.count)")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.fill.quaternary, in: Capsule())

                            Spacer()
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                        // 结果卡片流（液态玻璃）
                        ForEach(results) { media in
                            MoviePilotMediaGlassCard(
                                media: media,
                                isSubscribed: isMediaSubscribed(media),
                                isAdding: subscribingMediaIDs.contains(media.id),
                                onQuickSubscribe: {
                                    Task { await addSubscribeForMedia(media) }
                                },
                                onConfigureSubscribe: {
                                    sheetMedia = media
                                    isPresentingAddSheet = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal, contentLeading)
                    .padding(.bottom, 48)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func isMediaSubscribed(_ media: MPMediaInfo) -> Bool {
        if localSubscribedMediaIDs.contains(media.id) { return true }
        return subscribes.contains { sub in
            if let subTmdb = sub.tmdbId, let mediaTmdb = media.tmdbId, subTmdb == mediaTmdb {
                return true
            }
            if let subDouban = sub.doubanId, let mediaDouban = media.doubanId, subDouban == mediaDouban {
                return true
            }
            if let subBgm = sub.bangumiId, let mediaBgm = media.bangumiId, subBgm == mediaBgm {
                return true
            }
            if let subName = sub.name, let mediaTitle = media.title, subName == mediaTitle {
                return true
            }
            return false
        }
    }

    private func noticeBanner(_ text: String, isError: Bool) -> some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(isError ? .red : .green)
            .font(.callout)
            .padding(.vertical, 4)
    }

    // MARK: - 数据流与操作

    private var displayedSubscribes: [MPSubscribe] {
        switch selectedCategory {
        case .all:
            return subscribes
        case .movie:
            return subscribes.filter(\.isMovie)
        case .tv:
            return subscribes.filter { $0.isTV || !$0.isMovie }
        }
    }

    private var movieCount: Int {
        subscribes.filter(\.isMovie).count
    }

    private var tvCount: Int {
        subscribes.filter { $0.isTV || !$0.isMovie }.count
    }

    private var watchingCount: Int {
        subscribes.filter { ($0.state ?? "R").uppercased() == "R" }.count
    }

    private func loadSubscribes() async {
        guard !isLoadingSubscribes else { return }
        isLoadingSubscribes = true
        subscribesError = nil
        do {
            let list = try await MoviePilotAPIClient.shared.subscribes()
            subscribes = list
        } catch {
            subscribesError = (error as? MoviePilotError)?.userMessage ?? "\(error)"
        }
        isLoadingSubscribes = false
    }

    private func search() {
        let trimmed = submittedKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 允许重入：搜索在途时再次提交直接取消旧任务，不再静默吞掉新关键词。
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchError = nil
        searchTask = Task {
            do {
                let found = try await MoviePilotAPIClient.shared.searchMedia(title: trimmed)
                guard generation == searchGeneration else { return }
                results = found
            } catch {
                guard generation == searchGeneration else { return }
                searchError = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            }
            if generation == searchGeneration {
                isSearching = false
            }
        }
    }

    /// 换绑服务器后作废本页所有服务器相关的本地缓存。
    private func resetServerScopedState() {
        searchTask?.cancel()
        searchGeneration += 1
        subscribes = []
        subscribingMediaIDs = []
        localSubscribedMediaIDs = []
        results = []
        submittedKeyword = ""
        keyword = ""
        isSearching = false
        searchError = nil
        subscribesError = nil
        notice = nil
        pendingDeleteSubscribe = nil
    }

    private func addSubscribeForMedia(_ media: MPMediaInfo) async {
        subscribingMediaIDs.insert(media.id)
        notice = nil
        do {
            try await MoviePilotAPIClient.shared.addSubscribe(media: media)
            localSubscribedMediaIDs.insert(media.id)
            notice = "已成功添加订阅「\(media.title ?? "")」"
            isNoticeError = false
            Task { await loadSubscribes() }
        } catch {
            notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            isNoticeError = true
        }
        subscribingMediaIDs.remove(media.id)
    }

    private func deleteSubscribe(_ subscribe: MPSubscribe) async {
        notice = nil
        do {
            if let subId = subscribe.subscribeId {
                try await MoviePilotAPIClient.shared.deleteSubscribe(id: subId)
            } else if let mediaId = subscribe.asMediaInfo.mediaId {
                try await MoviePilotAPIClient.shared.deleteSubscribeByMedia(mediaId: mediaId)
            }
            subscribes.removeAll { $0.id == subscribe.id }
            notice = "已取消「\(subscribe.name ?? "")」的订阅"
            isNoticeError = false
        } catch {
            notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            isNoticeError = true
        }
    }

    private func triggerRefreshSubscribes() async {
        notice = nil
        do {
            try await MoviePilotAPIClient.shared.refreshSubscribes()
            notice = "已向服务器发送刷新订阅指令"
            isNoticeError = false
            await loadSubscribes()
        } catch {
            notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            isNoticeError = true
        }
    }

    private func triggerSearchSubscribes() async {
        notice = nil
        do {
            try await MoviePilotAPIClient.shared.searchSubscribes()
            notice = "已向服务器发送全站追更检索指令"
            isNoticeError = false
        } catch {
            notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            isNoticeError = true
        }
    }
}

// MARK: - 订阅海报卡片组件

private struct MoviePilotSubscribeCard: View {
    let subscribe: MPSubscribe
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        NavigationLink {
            MoviePilotResourceView(media: subscribe.asMediaInfo)
                .id(subscribe.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 严格 2:3 锁定的海报框体（保证每一个卡片的海报高度与宽度完全一致）
                posterContainer

                // 2. 追更进度细轨（有集数的剧集展示进度，没有集数或电影则保持统一间距）
                if let fraction = progressFraction {
                    progressTrack(fraction)
                        .frame(height: 3)
                        .padding(.top, 7)
                } else {
                    Color.clear
                        .frame(height: 3)
                        .padding(.top, 7)
                }

                // 3. 标题与信息栏（固定高度与对齐，保证整行卡片底部对齐）
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(subscribe.name ?? "未知条目")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 4)

                        if let year = subscribe.year {
                            Text(year)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let progress = subscribe.progressText {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if subscribe.isMovie {
                        Text("电影")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("剧集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("编辑订阅设置", systemImage: "pencil")
            }

            NavigationLink {
                MoviePilotResourceView(media: subscribe.asMediaInfo)
            } label: {
                Label("搜索站点资源", systemImage: "magnifyingglass")
            }

            Button {
                onRefresh()
            } label: {
                Label("在 MoviePilot 刷新", systemImage: "arrow.clockwise")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("取消订阅", systemImage: "trash")
            }
        }
    }

    /// 严格 2:3 比例的海报容器，并在内部叠放状态徽章、季数与评分
    private var posterContainer: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    // 海报图片
                    RemoteImage(url: subscribe.posterURL, authHeader: nil, maxPixelSize: 500)
                        .scaledToFill()

                    // 底部暗部渐变
                    LinearGradient(
                        colors: [.black.opacity(0.7), .black.opacity(0.2), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )

                    // 底部信息（左侧：季数/分类；右侧：评分）
                    HStack(alignment: .bottom, spacing: 4) {
                        if let seasonText = subscribe.seasonText {
                            badgeText(seasonText, background: .black.opacity(0.7), foreground: .white)
                        } else if subscribe.isMovie {
                            badgeText("电影", background: .black.opacity(0.7), foreground: .white)
                        }

                        Spacer(minLength: 4)

                        if let vote = subscribe.voteAverage, vote > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(BangumiStatusColor.rating)
                                Text(String(format: "%.1f", vote))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                        }
                    }
                    .padding(8)

                    // 右上角状态徽章（追更中 / 已完成 / 已暂停）
                    VStack {
                        HStack {
                            Spacer()
                            statusBadge(subscribe.stateText)
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private var progressFraction: Double? {
        guard let total = subscribe.totalEpisode, total > 0, let lack = subscribe.lackEpisode else {
            return nil
        }
        let completed = max(total - lack, 0)
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    private func progressTrack(_ fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.12))
            Rectangle()
                .fill(Color.accentColor)
                .scaleEffect(x: max(0, min(1, fraction)), y: 1, anchor: .leading)
        }
        .clipShape(Capsule())
    }

    private func badgeText(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(foreground)
    }

    private func statusBadge(_ stateText: String) -> some View {
        let isWatching = stateText == "追更中"
        let isDone = stateText == "已完成"

        return Text(stateText)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                isWatching ? Color.green.opacity(0.92) : (isDone ? Color.blue.opacity(0.92) : Color.gray.opacity(0.85)),
                in: Capsule()
            )
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

// MARK: - 媒体搜索结果液态玻璃卡片

private struct MoviePilotMediaGlassCard: View {
    let media: MPMediaInfo
    let isSubscribed: Bool
    let isAdding: Bool
    let onQuickSubscribe: () -> Void
    let onConfigureSubscribe: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // 2:3 标准胶片海报
            RemoteImage(url: media.posterURL, authHeader: nil, maxPixelSize: 360)
                .frame(width: 76, height: 114)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

            // 媒体主要元信息
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title ?? "未知条目")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // 标签行（类型 / 年份 / 评分 / 源）
                HStack(spacing: 6) {
                    if let type = media.type, !type.isEmpty {
                        Text(type)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    if let year = media.titleYear ?? media.year, !year.isEmpty {
                        Text(year)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    if let rating = media.voteAverage, rating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.yellow.opacity(0.12), in: Capsule())
                    }

                    if let source = media.mediaSource, !source.isEmpty {
                        Text(source.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.04), in: Capsule())
                    }
                }

                if let overview = media.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .lineSpacing(2)
                } else if !media.subtitle.isEmpty {
                    Text(media.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 操作区：液态玻璃胶囊交互组
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // 订阅菜单
                    Menu {
                        Button {
                            onQuickSubscribe()
                        } label: {
                            Label("快捷加入订阅", systemImage: "plus.circle")
                        }
                        .disabled(isSubscribed || isAdding)

                        Button {
                            onConfigureSubscribe()
                        } label: {
                            Label("配置规则并订阅…", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isAdding {
                                ProgressView().controlSize(.small)
                            } else if isSubscribed {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("已订阅")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "plus")
                                Text("订阅")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCapsule(
                        tint: isSubscribed ? Color.green.opacity(0.15) : nil,
                        isInteractive: !isSubscribed && !isAdding
                    )
                    .disabled(isSubscribed || isAdding)

                    // 查资源入口
                    NavigationLink {
                        MoviePilotResourceView(media: media)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                            Text("查资源")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCapsule(
                        tint: Color.accentColor.opacity(0.22),
                        isInteractive: true
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18, isInteractive: false)
    }
}
