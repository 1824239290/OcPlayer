import AppDesignKit
import CoreModel
import SwiftUI

/// 首页：按设置「首页栏目」的顺序渲染 继续观看 / 接下来看 / 最近添加 / 媒体库。
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    private var stillWidth: CGFloat { isCompact ? Metrics.compactStillWidth : Metrics.stillWidth }
    private var posterWidth: CGFloat? { isCompact ? Metrics.compactPosterWidth : nil }

    /// 首页栏目顺序与显隐（设置页「首页栏目」可调；缺省 = 隐藏）。
    @AppStorage(SettingsKeys.homeSections) private var homeSectionsRaw = HomeSectionPreference.defaultRaw
    private var homeSections: [HomeSection] { HomeSectionPreference.decode(homeSectionsRaw) }

    /// 全库搜索（`.searchable`，防抖后走服务端 `searchTerm`，不带 parentId 即全部库）。
    /// 结果是瞬态数据，只住本视图 `@State`，不进 AppModel 的分页缓存——回到首页
    /// 就该回到 rails，库页「切回来不重拉」的缓存语义对搜索不成立。
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var searchResults: [MediaItem] = []
    @State private var searchTotalCount: Int?
    @State private var searchNextStartIndex = 0
    @State private var searchLastPageWasFull = false
    @State private var isSearchLoading = false
    @State private var isSearchLoadingMore = false
    @State private var searchError: String?
    /// 本词的搜索结论是否已落地（出结果 / 为空 / 失败都算）。落地前 `searchContent`
    /// 显示骨架屏——`isSearching` 在打字瞬间就为真，直接渲染空态会先闪一帧错误的
    /// 「没有匹配」。注意它**只**用来区分「还在搜」和「搜完了」，不能拿它把整个
    /// 搜索态挡回 rails：那样有旧结果时每改一个字都会整页弹回首页再跳回来。
    @State private var searchLanded = false
    /// 在途的旧搜索请求靠它落账前自行作废，不写回过期页。
    @State private var activeSearchID: UUID?
    private static let searchPageSize = 100

    var body: some View {
        Group {
            if app.server == nil {
                noServerState
            } else if isSearching {
                searchContent
            } else if app.home.isLoading && app.home.latest.isEmpty {
                loadingState
            } else if let error = app.home.error, app.home.latest.isEmpty {
                errorState(error)
            } else {
                content
            }
        }
        .motion(Motion.slide, value: isSearching)
        .navigationTitle("首页")
        #if os(macOS)
        .navigationSubtitle(app.server == nil ? "未连接" : app.serverLabel)
        #endif
        .searchable(text: $searchText, prompt: Text("搜索全部媒体库"))
        .onChange(of: searchText) { _, _ in
            searchDebounce?.cancel()
            // 作废在途请求：防抖的 cancel 管不到已经 await 出去的 URLSession
            // 请求——置 nil 后旧词的翻页回来会在自己的 `activeSearchID == loadID`
            // 守卫处自行作废，不会把旧词的一页追加进新词结果、也不会覆盖
            // `searchNextStartIndex`。加载态一并清掉（那个请求的 defer 随之失效）。
            activeSearchID = nil
            isSearchLoading = false
            isSearchLoadingMore = false
            // 词变了，上一轮的结论作废。注意这里**不**把 body 挡回 rails：
            // 手上还有旧结果就继续显示旧结果，没有旧结果则 searchContent 进
            // 骨架屏（见 searchLanded 与 searchContent 的第一支）。
            searchLanded = false
            // 旧词的失败文案不能留到新词：`searchError` 只在 `runSearch` 里重置，
            // 那是 350ms 防抖之后——不清的话这段窗口里 footer 会一边显示新结果、
            // 一边挂着旧词的报错。
            searchError = nil
            guard isSearching else {
                // 输入清空：退出结果态，作废旧结果防下次进入闪旧数据。
                searchResults = []
                searchTotalCount = nil
                searchNextStartIndex = 0
                searchLastPageWasFull = false
                return
            }
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await runSearch(reset: true)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                openMediaMenu
                refreshToolbarButton
            }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 「打开」菜单：本地视频文件 / 直连链接。播放入口从设置页迁来（设置只放
    /// 设置），置位 AppModel 的请求标志——fileImporter / URLEntrySheet 挂在
    /// RootView，macOS 文件菜单 Cmd+O / Cmd+Shift+O 走同一对标志。
    private var openMediaMenu: some View {
        Menu {
            Button {
                app.isLocalFileImporterPresented = true
            } label: {
                Label("本地视频文件…", systemImage: "folder")
            }
            Button {
                app.isDirectLinkSheetPresented = true
            } label: {
                Label("直连链接…", systemImage: "link")
            }
        } label: {
            Label("打开", systemImage: "folder.badge.plus")
        }
        .accessibilityLabel("打开媒体")
    }

    /// 右上角刷新按钮：点击等同下拉刷新，重新向服务器请求首页与媒体库数据。
    /// 不额外套材质——macOS 26 / iOS 26 的工具栏按钮由系统渲染成液态玻璃，
    /// 手动再叠 `.glassEffect` 会双倍玻璃。加载中换成小转圈给反馈。
    private var refreshToolbarButton: some View {
        Button {
            Task { await app.reloadBrowserData() }
        } label: {
            if app.home.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .help("刷新首页")
        .accessibilityLabel("刷新首页")
        .disabled(app.server == nil)
    }

    private var noServerState: some View {
        ContentUnavailableView {
            Label("还没连接服务器", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text("连上媒体库后，这里会有继续观看和最近添加。本地文件播放不受影响。")
        } actions: {
            Button("去连接") { app.reconnectFlow() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var content: some View {
        // 不再包一层 GeometryReader：它会在每次侧栏拖动/窗口变化时强迫整页重测，
        // 滚轮滚动时也更容易和嵌套横向 Rail 抢布局，手感发沉。
        // 宽度由 Rail 内 `.frame(maxWidth: .infinity)` + 卡片固定宽约束。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(homeSections) { section in
                    sectionRail(section)
                }

                if allConfiguredSectionsEmpty {
                    ContentUnavailableView {
                        Label("媒体库暂无可展示内容", systemImage: "sparkles")
                    } description: {
                        Text("服务器上还没有可展示的内容，媒体库可能正在建立索引。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .padding(.top, 40)
                    .transition(.section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .refreshable { await app.reloadBrowserData() }
        // 下拉刷新会先清空再填充各 Rail 的数组，count 变化触发整体 crossfade。
        .motionAnimation(Motion.slide, value: app.home.resume.count, reduceMotion: reduceMotion)
        .motionAnimation(Motion.slide, value: app.home.nextUp.count, reduceMotion: reduceMotion)
        .motionAnimation(Motion.slide, value: app.home.latest.count, reduceMotion: reduceMotion)
        .motionAnimation(Motion.slide, value: app.libraries.count, reduceMotion: reduceMotion)
    }

    /// 启用的栏目里是否一条内容都没有（空态的判定只看启用栏目）。
    private var allConfiguredSectionsEmpty: Bool {
        homeSections.allSatisfy { section in
            switch section {
            case .resume: app.home.resume.isEmpty
            case .nextUp: app.home.nextUp.isEmpty
            case .latest: app.home.latest.isEmpty
            case .libraries: app.libraries.isEmpty
            }
        }
    }

    @ViewBuilder
    private func sectionRail(_ section: HomeSection) -> some View {
        switch section {
        case .resume:
            if !app.home.resume.isEmpty {
                Rail("继续观看", kind: .still, items: app.home.resume) { item in
                    StillCard(
                        item: item,
                        server: app.server,
                        actionIcon: "chevron.right",
                        actionAccessibilityLabel: "打开 \(item.seriesName ?? item.name) 详情",
                        width: stillWidth
                    ) {
                        app.openSeriesDetail(for: item)
                    }
                }
                .transition(.section)
            }
        case .nextUp:
            if !app.home.nextUp.isEmpty {
                Rail("接下来看", kind: .still, items: app.home.nextUp) { item in
                    StillCard(
                        item: item,
                        server: app.server,
                        actionIcon: "chevron.right",
                        actionAccessibilityLabel: "打开 \(item.seriesName ?? item.name) 详情",
                        width: stillWidth
                    ) {
                        app.openSeriesDetail(for: item)
                    }
                }
                .transition(.section)
            }
        case .latest:
            if !app.home.latest.isEmpty {
                Rail("最近添加", kind: .poster, items: app.home.latest) { item in
                    PosterCard(item: item, server: app.server, width: posterWidth) {
                        app.openDetail(item)
                    }
                }
                .transition(.section)
            }
        case .libraries:
            if !app.libraries.isEmpty {
                Rail("媒体库", kind: .still, items: app.libraries) { library in
                    LibraryCard(library: library, server: app.server, width: stillWidth) {
                        app.openLibrary(library)
                    }
                }
                .transition(.section)
            } else if let error = app.librariesError {
                // 顶栏「媒体库」按钮撤掉后，常规布局下库列表加载失败的唯一出口。
                // 版式对齐 Rail（标题 + 14pt 间距 + 内容行），只是内容换成错误行。
                VStack(alignment: .leading, spacing: 14) {
                    Text("媒体库")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, contentLeading)
                    HStack {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Button(UIStrings.retry) {
                            Task { await app.reloadBrowserData() }
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, contentLeading)
                }
                .padding(.top, 24)
                .transition(.section)
            }
        }
    }

    private var loadingState: some View {
        // 骨架屏：按设置里启用的栏目铺和真实布局同结构的 Rail（继续观看 /
        // 接下来看 = 剧照卡，最近添加 = 海报卡，媒体库 = 剧照卡），数据加载完
        // 原位替换。
        //
        // 内容型栏目铺几条按上一次成功加载的结论走（`home.railPresence`，跨启动
        // 保留）——写死的话，没有「继续观看」的服务器上骨架撤掉时会塌掉几百 pt。
        // 媒体库栏是导航入口，不占 presence 位：可达的服务器几乎必有可见库。
        let presence = app.home.railPresence
        // 上一次内容栏目全空（空库 / 全新服务器）：还是铺「最近添加」，全空的
        // 加载页看着像卡死。
        let showsLatest = presence.latest || presence.railCount == 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(homeSections) { section in
                    switch section {
                    case .resume:
                        if presence.resume {
                            SkeletonRail(title: "继续观看", kind: .still)
                        }
                    case .nextUp:
                        if presence.nextUp {
                            SkeletonRail(title: "接下来看", kind: .still)
                        }
                    case .latest:
                        if showsLatest {
                            SkeletonRail(title: "最近添加", kind: .poster)
                        }
                    case .libraries:
                        SkeletonRail(title: "媒体库", kind: .still)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .scrollDisabled(true)
        .skeletonShimmer()
    }

    private func errorState(_ message: String) -> some View {
        // 同 searchEmptyState：必须用 ScrollView 承载，裸 EmptyState 会让
        // 氛围背景塌成小块、顶栏变纯白。
        ScrollView {
            EmptyState(failure: message, title: "首页加载失败", systemImage: "wifi.exclamationmark") {
                Task { await app.reloadBrowserData() }
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - 全库搜索

    private var hasMoreSearchResults: Bool {
        if let searchTotalCount { return searchNextStartIndex < searchTotalCount }
        return searchLastPageWasFull
    }

    /// 列宽与库页海报墙同款（LibraryView.columns），搜索结果和库浏览观感一致。
    private var searchColumns: [GridItem] {
        if isCompact {
            return [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.adaptive(minimum: Metrics.posterWidth + 8), spacing: Metrics.railSpacing)]
    }

    private var searchCardWidth: CGFloat? { isCompact ? nil : Metrics.posterWidth }

    /// 搜索空态 / 失败态的载体：必须包在 ScrollView 里。`.background` 的氛围
    /// 背景尺寸跟随被包内容，而只有 ScrollView 的 frame 会自然铺到工具栏 /
    /// 侧栏玻璃底下——裸 EmptyState 会把背景塌成本分支的小块、顶栏变纯白
    /// （frame + ignoresSafeArea 都救不回来，实测像素 (249,249,249)）。
    /// `containerRelativeFrame` 让空态内容在可视区内垂直居中。
    private func searchEmptyState<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var searchContent: some View {
        Group {
            // 骨架屏：本词结论还没落地（含 350ms 防抖窗口）或正在重取，且手上
            // 没有旧结果可留。有旧结果时不进这一支——旧结果原地留着，新结果
            // 回来直接替换，改词就不会闪。
            if searchResults.isEmpty && (isSearchLoading || !searchLanded) {
                ScrollView {
                    LazyVGrid(columns: searchColumns, alignment: .leading, spacing: Metrics.railSpacing + 8) {
                        ForEach(0..<24, id: \.self) { _ in
                            SkeletonPosterCard(width: searchCardWidth)
                        }
                    }
                    .padding(.horizontal, contentLeading)
                    .padding(.vertical, 28)
                }
                .scrollDisabled(true)
                .skeletonShimmer()
            } else if let searchError, searchResults.isEmpty {
                searchEmptyState {
                    EmptyState(failure: searchError, systemImage: "wifi.exclamationmark") {
                        Task { await runSearch(reset: true) }
                    }
                }
            } else if searchResults.isEmpty {
                // 服务端 searchTerm 对单字不匹配（Jellyfin/Emby 的分词行为，
                // 实测两字以上的子串才命中），单字无结果时给引导而不是让它
                // 看起来像坏了。
                let term = searchText.trimmingCharacters(in: .whitespaces)
                searchEmptyState {
                    EmptyState(
                        empty: term.count < 2
                            ? "「\(term)」没有匹配"
                            : "没有匹配「\(term)」的结果",
                        systemImage: "magnifyingglass",
                        // 粒度说清楚：检索的是电影 / 剧集条目本身，单集标题搜不到
                        // （分集搜索是刻意不做的，见 CHANGELOG）。
                        message: term.count < 2
                            ? "搜索至少要两个字，多输入几个字试试。"
                            : "只匹配电影与剧集条目，单集标题不参与检索。"
                    )
                }
            } else {
                ScrollView {
                    // footer 必须待在 lazy 容器里：`onAppear` 在非 lazy 的
                    // ScrollView 内容里只在加入视图树时触发一次，那样第 3 页
                    // 起就不会再自动预取，只能手点。
                    LazyVStack(spacing: 0) {
                        LazyVGrid(columns: searchColumns, alignment: .leading, spacing: Metrics.railSpacing + 8) {
                            ForEach(searchResults) { item in
                                PosterCard(item: item, server: app.server, width: searchCardWidth) {
                                    app.openDetail(item)
                                }
                                .transition(reduceMotion ? .identity : .opacity)
                            }
                        }
                        .padding(.horizontal, contentLeading)
                        .padding(.vertical, 28)

                        if hasMoreSearchResults || isSearchLoadingMore {
                            searchLoadMoreFooter
                                .padding(.bottom, 28)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .animation(reduceMotion ? nil : Motion.standard, value: searchResults.count)
            }
        }
    }

    private var searchLoadMoreFooter: some View {
        VStack(spacing: 10) {
            if let searchError, !searchResults.isEmpty {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isSearchLoadingMore {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Button(UIStrings.loadMore) {
                    Task { await runSearch(reset: false) }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        // footer 进入可视区即预取下一页，不用手动点。前提是它待在 lazy 容器里
        // （见 searchContent 的 LazyVStack），否则只在加入视图树时触发一次。
        .onAppear {
            guard hasMoreSearchResults, !isSearchLoading, !isSearchLoadingMore else { return }
            Task { await runSearch(reset: false) }
        }
    }

    /// 全库搜索一页（电影 + 剧集，与首页卡片粒度一致）。
    private func runSearch(reset: Bool) async {
        guard let server = app.server else { return }
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        // 会话代次：搜索在途时切了服务器，旧服务器的结果不能落进新会话。
        let generation = app.sessionGeneration

        let loadID = UUID()
        activeSearchID = loadID
        if reset {
            isSearchLoading = true
        } else {
            isSearchLoadingMore = true
        }
        searchError = nil
        defer {
            if activeSearchID == loadID {
                isSearchLoading = false
                isSearchLoadingMore = false
            }
        }

        do {
            let page = try await server.itemsPage(
                parentID: nil,
                kinds: [.movie, .series],
                recursive: true,
                startIndex: reset ? 0 : searchNextStartIndex,
                limit: Self.searchPageSize,
                sort: nil,
                watchState: nil,
                searchTerm: term
            )
            guard !Task.isCancelled, activeSearchID == loadID else { return }
            // 会话已换（搜索在途时切了服务器）：本词结果作废。清空搜索词回到
            // rails——留着词的话 searchLanded 永远是 false，会一直卡在骨架屏。
            guard app.sessionIsCurrent(generation, server: server) else {
                searchText = ""
                return
            }
            if reset {
                searchResults = page.items
            } else {
                // 防御服务端重复页：按 id 去重追加。
                var existing = Set(searchResults.map(\.id))
                searchResults += page.items.filter { existing.insert($0.id).inserted }
            }
            searchTotalCount = page.totalRecordCount
            searchNextStartIndex = (reset ? 0 : searchNextStartIndex) + page.items.count
            searchLastPageWasFull = page.items.count >= Self.searchPageSize
            searchLanded = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, activeSearchID == loadID else { return }
            // `localizedDescription` 而不是 `"\(error)"`：JellyfinError 是
            // LocalizedError 不是 CustomStringConvertible，插值会把
            // `JellyfinError(kind: …)` 这种反射串直接摆给用户。
            searchError = error.localizedDescription
            searchLanded = true
        }
    }
}
