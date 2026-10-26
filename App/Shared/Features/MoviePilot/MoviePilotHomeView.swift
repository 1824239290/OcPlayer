import AppDesignKit
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
    /// 保留错误本体而不是文案：登录失效类错误要把「重试」换成「重新登录」。
    @State private var subscribesError: MoviePilotError?
    @State private var selectedCategory: SubscribeCategory = .all
    @State private var pendingDeleteSubscribe: MPSubscribe?
    @State private var editingSubscribe: MPSubscribe?
    @State private var isPresentingAddSheet = false
    @State private var sheetMedia: MPMediaInfo?
    /// 登录失效时直弹 MoviePilot 登录窗（门控按钮与错误态按钮共用）。
    @State private var isPresentingReloginSheet = false
    /// view-destination 页（下载管理 / 资源搜索）统一走 pushPresented 两段式：
    /// 点击先淡出当前页，落地后由 routeExiting 复位的回弹淡入入场，与路由页同一节奏。
    @State private var showDownloads = false
    @State private var showResource = false
    @State private var resourceMedia: MPMediaInfo?

    private func openResource(_ media: MPMediaInfo) {
        app.pushPresented {
            resourceMedia = media
            showResource = true
        }
    }

    // MARK: - 搜索状态
    @State private var keyword = ""
    @State private var submittedKeyword = ""
    @State private var isSearching = false
    @State private var results: [MPMediaInfo] = []
    @State private var searchError: MoviePilotError?
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var subscribingMediaIDs: Set<String> = []
    @State private var localSubscribedMediaIDs: Set<String> = []

    /// `subscribeSummary` 的缓存（见那个属性的注释：读取点分散在多个 computed property，
    /// 无法 hoist，只能缓存）。
    @State private var subscribeSummaryCache: (sourceID: String, summary: SubscribeSummary)?
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

    var body: some View {
        Group {
            #if OCPLAYER_SELFTEST
            // 自检通道（Debug-only）：结果卡验收台**必须绕过登录门控**——它的存在意义
            // 就是「不接服务器也能看真实渲染」，所以判在 `integrationState` 之前。
            if MoviePilotCardPreviewStage.isRequested {
                MoviePilotCardPreviewStage()
            } else {
                integrationGatedContent
            }
            #else
            integrationGatedContent
            #endif
        }
        .navigationTitle("MoviePilot")
        #if os(macOS)
        .navigationSubtitle(navigationSubtitleText)
        #else
        // iPhone / iPad：Tab 根页不挂大标题（与首页同一口径，见 HomeView 顶部
        // 注释）；macOS 是窗口工具栏标题 + 副标题，本来就不占版面，保持原样。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
        // 登录失效的两个入口（门控按钮 / 错误态按钮）都直弹登录窗：预填地址与
        // 账号，用户只补密码，不必绕道设置页。挂在 Group 上——token 被清后
        // mainContent 会整个切到门控态，sheet 必须在门控外层才弹得出来。
        .sheet(isPresented: $isPresentingReloginSheet) {
            MoviePilotServerSheet(
                initialURL: moviepilot.store.serverURLString ?? "",
                initialUsername: moviepilot.store.username
            )
        }
        .onChange(of: isPresentingReloginSheet) { _, isPresented in
            // 同一台服务器重登成功不会变 boundServerID（task(id:) 不重跑）；
            // 从失效错误态登录回来时顺手重拉，别让人停在旧错误上。
            if !isPresented, subscribesError?.isAuthenticationFailure == true,
               moviepilot.isAuthenticated {
                Task { await loadSubscribes() }
            }
        }
        // `P2-12`：`subscribeSummary` 的读取点分散在 5 个 computed property 里
        // （无法像 body 那样 hoist 成局部常量），所以用缓存。这里在数据变化时预热。
        .task(id: subscribesCacheID) {
            refreshSubscribeSummaryCache()
        }
    }

    /// 未配置 / 未登录 / 就绪三态的正常入口（自检通道绕开它，见 `body`）。
    @ViewBuilder
    private var integrationGatedContent: some View {
        switch moviepilot.integrationState {
        case .unconfigured:
            gate(
                "未配置 MoviePilot",
                icon: "arrow.down.circle",
                hint: "在 设置 → MoviePilot 填写服务器地址与账号"
            )
        case .loggedOut:
            // 登出与令牌失效（没记住密码时静默重登失败）都落这里：地址与用户名
            // 还在，缺的只是登录，所以给的是「重新登录」而不是「去设置」。
            gate(
                "未登录",
                icon: "person.crop.circle.badge.exclamationmark",
                hint: "MoviePilot 尚未登录或登录状态已失效，重新登录后即可管理订阅与下载",
                allowsRelogin: true
            )
        case .ready:
            mainContent
        }
    }

    private var navigationSubtitleText: String {
        if isSearchingMode {
            return results.isEmpty ? "" : "搜索结果 \(results.count) 条"
        }
        let summary = subscribeSummary()
        return subscribes.isEmpty ? "" : "已订阅 \(subscribes.count) 部 · \(summary.watchingCount) 部追更中"
    }

    // MARK: - 门控

    /// 未配置 / 未登录的整页引导。
    ///
    /// **必须包在 `PageFillingState` 里**：本视图是分区的根，裸 `ContentUnavailableView`
    /// 的理想尺寸固定（实测 400×400 且不随窗口变），会让 AppShell 根节点的氛围背景
    /// 一起塌成中间那一小块——整页只剩中间有背景、顶栏玻璃底下变纯灰。
    /// 详见 `PageFillingState` 的类型注释。
    private func gate(
        _ title: String, icon: String, hint: String, allowsRelogin: Bool = false
    ) -> some View {
        PageFillingState {
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                Text(hint)
            } actions: {
                if allowsRelogin {
                    Button("重新登录") { isPresentingReloginSheet = true }
                        .neutralProminentButton()
                    Button("去设置") { app.switchSection(.settings) }
                        .buttonStyle(.bordered)
                } else {
                    Button("去设置") { app.switchSection(.settings) }
                        .neutralProminentButton()
                }
            }
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
        .motion(Motion.slide, value: isSearchingMode)
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

                Button {
                    app.pushPresented { showDownloads = true }
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
        .navigationDestination(isPresented: $showDownloads) {
            MoviePilotDownloadsView()
                .appShellBackChrome(title: "下载管理", presented: $showDownloads)
        }
        .navigationDestination(isPresented: $showResource) {
            if let resourceMedia {
                MoviePilotResourceView(media: resourceMedia)
                    .appShellBackChrome(
                        title: resourceMedia.title ?? "资源搜索", presented: $showResource
                    )
            }
        }
        // 呈现式页面不在 path 上，CoveredPageHider 看不见这层覆盖：落地期间
        // 整页隐去，别透过透显的资源搜索 / 下载管理页漏出（见 coveredByPresented）。
        .coveredByPresented($showDownloads, $showResource)
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
        // `P2-12`：**在这一层 hoist 一次** `subscribeSummary`，再把它传给下面四处。
        //
        // 第一版把它写成纯 computed property，在 5 个地方各读一次（header 三个计数 +
        // 空态判断 + `ForEach`）—— 每个读取点都完整跑一遍全表循环，比改前的 5 次
        // filter 总账更差（审查实测 1.43×）。加了 `@State` 缓存后读是 O(1) 了，
        // 但首次渲染（缓存还没预热）仍会是多次。
        //
        // 这里是它们**共同的父层**，算一次传下去最直接：一次渲染只跑一遍。
        let summary = subscribeSummary()
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let notice {
                    MoviePilotNoticeBanner(text: notice, isError: isNoticeError)
                        .padding(.horizontal, contentLeading)
                        .padding(.top, 12)
                }

                // 顶部控制栏（分类切换 + 状态统计 + 快捷添加）
                headerControlBar(summary: summary)
                    .padding(.horizontal, contentLeading)
                    .padding(.top, 16)
                    .padding(.bottom, 22)

                if isLoadingSubscribes && subscribes.isEmpty {
                    skeletonGrid
                } else if let subscribesError, subscribes.isEmpty {
                    mpErrorView(subscribesError, failedTitle: "加载订阅失败") {
                        Task { await loadSubscribes() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .padding(.top, 40)
                } else if summary.displayed(category: selectedCategory).isEmpty {
                    emptySubscriptionsView
                } else {
                    subscriptionsGrid(summary: summary)
                        .padding(.horizontal, contentLeading)
                        .padding(.bottom, 36)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(Motion.standard, value: selectedCategory)
        }
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .refreshable {
            await loadSubscribes()
        }
    }

    private func headerControlBar(summary: SubscribeSummary) -> some View {
        HStack(spacing: 16) {
            Picker("分类", selection: $selectedCategory) {
                Text("全部 (\(subscribes.count))").tag(SubscribeCategory.all)
                Text("电影 (\(summary.movies.count))").tag(SubscribeCategory.movie)
                Text("剧集 (\(summary.shows.count))").tag(SubscribeCategory.tv)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            if !subscribes.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(summary.watchingCount) 部追更中")
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
                .neutralProminentButton()

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
        LazyVGrid(
            columns: PosterGrid.columns(compact: isCompact),
            alignment: .leading,
            spacing: PosterGrid.rowSpacing(compact: isCompact)
        ) {
            ForEach(0..<10, id: \.self) { _ in
                SkeletonPosterCard(width: nil)
            }
        }
        .padding(.horizontal, contentLeading)
        .padding(.bottom, 28)
        .skeletonShimmer()
    }

    private func subscriptionsGrid(summary: SubscribeSummary) -> some View {
        LazyVGrid(
            columns: PosterGrid.columns(compact: isCompact),
            alignment: .leading,
            spacing: PosterGrid.rowSpacing(compact: isCompact)
        ) {
            ForEach(summary.displayed(category: selectedCategory)) { subscribe in
                MoviePilotSubscribeCard(
                    subscribe: subscribe,
                    onEdit: { editingSubscribe = subscribe },
                    onDelete: { pendingDeleteSubscribe = subscribe },
                    onRefresh: { Task { await triggerRefreshSubscribes() } },
                    onOpenResource: { openResource(subscribe.asMediaInfo) }
                )
            }
        }
    }

    // MARK: - 搜索结果视图

    private var searchResultsView: some View {
        Group {
            if isSearching && results.isEmpty {
                // 这三个分支同样是「根级状态视图」：搜索态下本页没有 ScrollView
                // 兜底（结果态那个 ScrollView 不在树上），裸视图会让氛围背景跟着
                // 塌成内容小块。载体理由见 `PageFillingState`。
                PageFillingState {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在搜索媒体…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let searchError, results.isEmpty {
                PageFillingState {
                    mpErrorView(searchError, failedTitle: UIStrings.searchFailed) {
                        search()
                    }
                }
            } else if results.isEmpty {
                PageFillingState {
                    ContentUnavailableView.search(text: submittedKeyword)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let notice {
                            MoviePilotNoticeBanner(text: notice, isError: isNoticeError)
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
                            Text(searchError.userMessage)
                                .foregroundStyle(.red)
                                .font(.callout)
                                .padding(.vertical, 4)
                        }

                        // 媒体结果标题与数量统计
                        HStack(spacing: 8) {
                            Text("媒体结果")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)

                            PillChip("\(results.count)", font: .footnote.weight(.semibold))

                            Spacer()
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                        // 结果卡片流（液态玻璃）
                        //
                        // `P2-13`：订阅索引**在这里建一次**，供下面每一行查。
                        //
                        // 原先每行都调 `isMediaSubscribed(media)`，内部是
                        // `subscribes.contains { ... }` —— 对**每一行**做一次 O(M) 全表扫描
                        // （M = 订阅数），4 个字段各比一次。搜索结果 R 行就是 O(R×M)，
                        // 而这一整段在同一次 body 里、`subscribes` 根本没变。
                        //
                        // 建索引后每行 O(1)：4 个 `Set` 的哈希查找。
                        let subscribedIndex = SubscribedIndex(subscribes: subscribes,
                                                              localIDs: localSubscribedMediaIDs)
                        ForEach(results) { media in
                            MoviePilotMediaGlassCard(
                                media: media,
                                isSubscribed: subscribedIndex.contains(media),
                                isAdding: subscribingMediaIDs.contains(media.id),
                                onQuickSubscribe: {
                                    Task { await addSubscribeForMedia(media) }
                                },
                                onConfigureSubscribe: {
                                    sheetMedia = media
                                    isPresentingAddSheet = true
                                },
                                onOpenResource: { openResource(media) }
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

    /// 「这一条媒体是否已订阅」的 O(1) 索引（`P2-13`）。
    ///
    /// 把原先「每行一次 O(M) 全表扫描 × 4 个字段比较」变成「建一次 4 个 `Set`、
    /// 之后每行 4 次哈希查找」。
    ///
    /// - Note: 匹配语义与旧实现**逐一对应**：本地 id 命中即算，
    ///   否则 tmdb / douban / bangumi 任一 id 相等算，再否则**片名完全相同**算。
    ///   `nil` 与 `nil` 不算匹配（旧实现用 `if let ... if let ... ==`，
    ///   两侧都必须非 nil）—— 所以索引只收非 nil 值。
    struct SubscribedIndex: Sendable {
        private let localIDs: Set<String>
        private let tmdbIDs: Set<Int>
        private let doubanIDs: Set<String>
        private let bangumiIDs: Set<Int>
        private let names: Set<String>

        init(subscribes: [MPSubscribe], localIDs: Set<String>) {
            self.localIDs = localIDs
            var tmdb: Set<Int> = []
            var douban: Set<String> = []
            var bangumi: Set<Int> = []
            var titles: Set<String> = []
            tmdb.reserveCapacity(subscribes.count)
            for sub in subscribes {
                if let value = sub.tmdbId { tmdb.insert(value) }
                if let value = sub.doubanId { douban.insert(value) }
                if let value = sub.bangumiId { bangumi.insert(value) }
                if let value = sub.name { titles.insert(value) }
            }
            tmdbIDs = tmdb
            doubanIDs = douban
            bangumiIDs = bangumi
            names = titles
        }

        func contains(_ media: MPMediaInfo) -> Bool {
            if localIDs.contains(media.id) { return true }
            if let value = media.tmdbId, tmdbIDs.contains(value) { return true }
            if let value = media.doubanId, doubanIDs.contains(value) { return true }
            if let value = media.bangumiId, bangumiIDs.contains(value) { return true }
            if let value = media.title, names.contains(value) { return true }
            return false
        }
    }

    /// MoviePilot 请求失败的错误态：登录失效（token 过期且静默重登也被拒）时
    /// 重试没有意义，标题与按钮换成「登录状态已失效 / 重新登录」，直弹登录窗；
    /// 其余错误维持原文案 + 重试。
    private func mpErrorView(
        _ error: MoviePilotError,
        failedTitle: String,
        retry: @escaping () -> Void
    ) -> some View {
        let isAuthFailure = error.isAuthenticationFailure
        return EmptyState(
            empty: isAuthFailure ? "登录状态已失效" : failedTitle,
            systemImage: isAuthFailure
                ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle",
            message: isAuthFailure
                ? "MoviePilot 的登录凭证已过期或被服务端拒绝，重新登录后即可继续。"
                : error.userMessage,
            actionTitle: isAuthFailure ? "重新登录" : UIStrings.retry
        ) {
            if isAuthFailure {
                isPresentingReloginSheet = true
            } else {
                retry()
            }
        }
    }

    // MARK: - 数据流与操作

    /// 订阅列表在一次 body 里要用到的**全部派生数据**（`P2-12`）。
    ///
    /// 原先这里是 4 个独立 computed property（`displayedSubscribes` / `movieCount` /
    /// `tvCount` / `watchingCount`），每个都自己把 `subscribes` 全表遍历一遍 ——
    /// 而 `displayedSubscribes` 在同一次 body 里还被读两次（空态判断 + `ForEach`）。
    /// 一屏下来是 **5 次 O(N) 扫**，全部基于同一个不会变的 `subscribes`。
    ///
    /// 现在算成一个值：**一次遍历**分出三类，之后都是 O(1) 读。
    ///
    /// - Note: 分类判据与旧实现**逐字对应**：`isMovie` / `isTV || !isMovie` /
    ///   `state`（缺省按 "R" 视作追更中，大小写不敏感）。
    /// 订阅列表的派生数据（`P2-12`）。
    ///
    /// ## 为什么要有缓存
    ///
    /// 第一版把它写成纯 computed property，然后在 5 个地方各读一次
    /// （`navigationSubtitleText`、`headerControlBar` 三个计数、空态判断、`ForEach`）。
    /// 那些读取点分属**不同的 computed property**（各自是独立 View 表达式），
    /// 无法像 `body` 那样 hoist 成一个局部常量 —— **于是一次渲染仍然是 5 次全表扫**，
    /// 只是从「同一个 body 里 5 次」变成「几个 body 各 1 次」，总账没省。
    ///
    /// 所以缓存一份：`subscribes` 的**引用身份**没变就直接返回上次结果。
    /// `subscribes` 是 `@State [MPSubscribe]`，只有整体替换才换身份
    /// （本文件里都是 `subscribes = list` 这种整体赋值，没有原地改元素），
    /// 所以用 `===` 式的身份判断是安全的。
    ///
    /// - Note: 用 `@State` 存缓存（而不是普通存储属性）—— View 是 struct，
    ///   普通属性每次 body 重建都会丢，缓存就永远不命中。
    private func subscribeSummary() -> SubscribeSummary {
        if let cached = subscribeSummaryCache, cached.sourceID == subscribesCacheID {
            return cached.summary
        }
        var movies: [MPSubscribe] = []
        var shows: [MPSubscribe] = []
        var watching = 0
        movies.reserveCapacity(subscribes.count / 2)
        for sub in subscribes {
            if sub.isMovie {
                movies.append(sub)
            } else {
                shows.append(sub)
            }
            if (sub.state ?? "R").uppercased() == "R" {
                watching += 1
            }
        }
        let summary = SubscribeSummary(
            all: subscribes,
            movies: movies,
            shows: shows,
            watchingCount: watching
        )
        // 写回缓存。⚠️ 不能在这里直接赋值 `subscribeSummaryCache`：那是在
        // View 的 getter 里改 `@State`，会触发「在视图更新期间修改状态」的运行时警告。
        // 改用 `Task { @MainActor in ... }` 推迟到下一个 runloop —— 但那样第一次
        // 渲染仍然白算一次，且每次数据变化都要多等一帧。
        //
        // 所以这里**不写**：缓存只由下面那个 `.task(id:)` 在数据变化时写入
        // （见 `refreshSubscribeSummaryCache()`）。getter 只在缓存缺失时算一次。
        return summary
    }

    /// 把 `subscribeSummary` 算一遍并写进缓存。由 `.task(id:)` 在 `subscribes` 变化时调用。
    ///
    /// 放在 `.task` 里而不是 body 里，是为了避免「在视图更新期间改 `@State`」。
    private func refreshSubscribeSummaryCache() {
        let id = subscribesCacheID
        guard subscribeSummaryCache?.sourceID != id else { return }
        // 直接算一遍（不走 `subscribeSummary` 的 getter，避免递归读半边状态）。
        var movies: [MPSubscribe] = []
        var shows: [MPSubscribe] = []
        var watching = 0
        movies.reserveCapacity(subscribes.count / 2)
        for sub in subscribes {
            if sub.isMovie {
                movies.append(sub)
            } else {
                shows.append(sub)
            }
            if (sub.state ?? "R").uppercased() == "R" {
                watching += 1
            }
        }
        subscribeSummaryCache = (
            id,
            SubscribeSummary(all: subscribes, movies: movies, shows: shows,
                             watchingCount: watching)
        )
    }

    /// `subscribes` 的内容指纹（用于判断 `subscribeSummaryCache` 是否还能用）。
    ///
    /// 用「条目数 + 首末 id」而不是逐个哈希：`MPSubscribe` 有 `raw` 字典，
    /// 全量哈希是 O(N)，那就把省下来的又还回去了。这个指纹足以覆盖
    /// 「列表整体换了一批」这个唯一会发生的场景。
    private var subscribesCacheID: String {
        guard let first = subscribes.first, let last = subscribes.last else { return "0" }
        return "\(subscribes.count)|\(first.id)|\(last.id)"
    }

    /// `subscribeSummary` 的载体。`shows` 含「既不是电影也不是剧集」的兜底项 ——
    /// 与旧 `tvCount` 的 `isTV || !isMovie` 一致。
    private struct SubscribeSummary {
        let all: [MPSubscribe]
        let movies: [MPSubscribe]
        let shows: [MPSubscribe]
        let watchingCount: Int

        func displayed(category: SubscribeCategory) -> [MPSubscribe] {
            switch category {
            case .all: all
            case .movie: movies
            case .tv: shows
            }
        }
    }

    private func loadSubscribes() async {
        guard !isLoadingSubscribes else { return }
        isLoadingSubscribes = true
        subscribesError = nil
        do {
            let list = try await MoviePilotAPIClient.shared.subscribes()
            subscribes = list
        } catch {
            subscribesError = (error as? MoviePilotError) ?? .generic("\(error)")
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
                searchError = (error as? MoviePilotError) ?? .generic("\(error)")
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
            notice = MoviePilotError.userMessage(of: error)
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
            notice = MoviePilotError.userMessage(of: error)
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
            notice = MoviePilotError.userMessage(of: error)
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
            notice = MoviePilotError.userMessage(of: error)
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
    var onOpenResource: () -> Void

    var body: some View {
        Button {
            onOpenResource()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 严格 2:3 锁定的海报框体（保证每一个卡片的海报高度与宽度完全一致）
                posterContainer

                // 2. 追更进度细轨（有集数的剧集展示进度，没有集数或电影则保持统一间距）
                if let fraction = progressFraction {
                    CardProgressTrack(fraction: fraction, tint: .accentColor)
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

            Button {
                onOpenResource()
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
        MediaArtwork(url: subscribe.posterURL, shape: .poster, width: nil, nominalRatio: 2.0 / 3.0) {
            ZStack(alignment: .bottomLeading) {
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

                // 状态徽章（追更中 / 已完成 / 已暂停）
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
    }

    private var progressFraction: Double? {
        guard let total = subscribe.totalEpisode, total > 0, let lack = subscribe.lackEpisode else {
            return nil
        }
        let completed = max(total - lack, 0)
        return min(max(Double(completed) / Double(total), 0), 1)
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
