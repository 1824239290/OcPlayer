import AppDesignKit
import CoreModel
import JellyfinKit
import SwiftUI

/// 媒体库网格页：海报墙。电影库直接铺电影，剧集库铺剧集。
/// 分页加载：首屏一页，翻页时新卡片带入场动画淡入。
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let library: MediaLibrary

    private static let pageSize = 100
    /// 单库分页缓存上限：到顶后 `hasMore` 置 false（**停止翻页**，不是淘汰旧页——
    /// 注释曾宣称淘汰，与实现不符）。1000 条 ≈ 十几 MB 元数据，是「切回来不重拉」
    /// 和「会话内不无界累积」的折中点；全局兜底是 AppModel.cacheLibraryPage 的
    /// 20 000 条目上限（超限整份清空）。
    private static let maxCachedItems = 1000

    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var activeLoadID: UUID?
    /// 库内搜索词（`.searchable` 输入，防抖后触发服务端 `searchTerm` 查询）。
    /// 视图实例跨库复用，切库时在 `task(id:)` 里清空——注意只在**真的换库**时清
    /// （见 `lastLibraryID`）。
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?
    /// 上一次 `task(id:)` 见过的库 id。`.task(id:)` 不只在 id 变化时重跑，视图每次
    /// appear 都会重跑（push 详情再返回也算），所以必须比对 id 才能区分「换库」和
    /// 「同一个库重新出现」——否则搜索结果点进详情再返回，搜索词和滚动位置全丢。
    @State private var lastLibraryID: String?
    /// 当前**取页用的**搜索词（`AppModel.LibraryPageKey` 的搜索维）。
    ///
    /// 为什么不直接用 `searchText`：它是防抖的，改词后要 350 ms 才更新缓存，
    /// 而「切库时清词」与「回浏览页」都需要**同步**生效——`searchText` 同为 ""
    /// 时 `onChange(of: searchText)` 根本不触发，光靠它切不回浏览页。所以这里
    /// 显式跟着走：onChange 与 `task(id:)` 各同步一次。
    @State private var currentPageSearchTerm = ""

    /// 每库独立记忆的排序字段与方向（key 带库 id，各库互不干扰）。
    /// 动态 key 的 @AppStorage 只能在 init 里注入，存 rawValue 字符串。
    @AppStorage private var sortFieldRaw: String
    @AppStorage private var sortAscending: Bool
    /// 每库独立记忆的观看状态筛选（全部 / 没看过 / 看过）。
    @AppStorage private var watchStateRaw: String

    init(library: MediaLibrary) {
        self.library = library
        _sortFieldRaw = AppStorage(
            wrappedValue: MediaItemsSortField.name.rawValue,
            "library.sort.field.\(library.id)"
        )
        _sortAscending = AppStorage(wrappedValue: true, "library.sort.ascending.\(library.id)")
        _watchStateRaw = AppStorage(
            wrappedValue: MediaItemsWatchState.all.rawValue,
            "library.watch.\(library.id)"
        )
    }

    /// 分页数据住在 `AppModel.libraryPages`，不在视图 `@State` 里：
    /// 侧栏切走再切回来时不用从第一页重拉（见 `AppModel.LibraryPage`）。
    /// 键 = 库 + 搜索词：浏览页与搜索页各占一格，否则两者会互相顶掉
    /// （搜完点进详情再回首页，回来会只剩搜索结果、搜索框却是空的）。
    private var pageKey: AppModel.LibraryPageKey {
        AppModel.LibraryPageKey(libraryID: library.id, searchTerm: currentPageSearchTerm)
    }

    private var currentPage: AppModel.LibraryPage? { app.libraryPages[pageKey] }
    private var items: [MediaItem] { currentPage?.items ?? [] }
    private var totalCount: Int? { currentPage?.totalCount }
    private var nextStartIndex: Int { currentPage?.nextStartIndex ?? 0 }
    private var lastPageWasFull: Bool { currentPage?.lastPageWasFull ?? false }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var columns: [GridItem] {
        if isCompact {
            return [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
            ]
        }
        return [GridItem(.adaptive(minimum: Metrics.posterWidth + 8), spacing: Metrics.railSpacing)]
    }

    private var gridSpacing: CGFloat {
        isCompact ? 14 : Metrics.railSpacing + 8
    }

    private var cardWidth: CGFloat? {
        isCompact ? nil : Metrics.posterWidth
    }

    private var hasMore: Bool {
        guard items.count < Self.maxCachedItems else { return false }
        if let totalCount {
            return nextStartIndex < totalCount
        }
        // 总数未知时：上一页是服务端满页才允许再试。按本地条数取模的启发式
        // 会被去重/过滤干扰（100 条里去重掉 3 条就误判「没有更多了」）。
        return lastPageWasFull
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                skeletonGrid
            } else if let loadError, items.isEmpty {
                EmptyState(failure: loadError, systemImage: "wifi.exclamationmark") {
                    Task { await reload() }
                }
            } else if items.isEmpty {
                let term = searchText.trimmingCharacters(in: .whitespaces)
                EmptyState(
                    empty: isSearching
                        ? (term.count < 2 ? "「\(term)」没有匹配" : "没有匹配「\(term)」的结果")
                        : "这里还没有内容",
                    systemImage: isSearching ? "magnifyingglass" : "tray",
                    message: searchEmptyMessage(term: term)
                )
            } else {
                grid
            }
        }
        .searchable(text: $searchText, prompt: Text("搜索本库"))
        .onChange(of: searchText) { _, _ in
            searchDebounce?.cancel()
            // 立刻把取页键切到新词：不切的话这 350 ms 里网格会继续读旧词的格子，
            // 出现「框里是新词、内容还是上一个词的结果」。
            currentPageSearchTerm = searchText
            // 切键的同时进入加载态。新词那一格必然是空的，而请求要等 350 ms 防抖
            // 加网络往返；这段窗口里若不置位，body 会落到 `items.isEmpty` 分支、
            // 满屏渲染「没有匹配」——打字时每敲一个字闪一次空结果页。置位后同一
            // 窗口渲染骨架屏，等真实结果（或真的没结果）落地再切过去。
            isLoading = true
            isLoadingMore = false
            loadError = nil
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                // await 而不是同步入口：这样 `searchDebounce?.cancel()` 能把取消
                // 一路传到 URLSession，慢速连续输入不会并发堆请求。
                await reloadFromFirstPageCancellable()
            }
        }
        .navigationTitle(library.name)
        #if os(macOS)
        .navigationSubtitle(subtitleText)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                sortToolbarButton
            }
        }
        .task(id: library.id) {
            // 视图实例跨库复用，上一库的搜索词不能带进新库（清空会经 onChange
            // 触发一次防抖重载，与 loadIfNeeded 的加载落账互不干扰）。
            // 只在 id 真的变了时清：`.task(id:)` 每次 appear 都会重跑，不比对
            // 的话「搜索结果 → 进详情 → 返回」会把搜索词连滚动位置一起清掉。
            if lastLibraryID != library.id {
                lastLibraryID = library.id
                // 切库一定会重新进来（此刻不在导航栈里），浏览页就是落脚点。
                currentPageSearchTerm = ""
                // searchText 是 `@State`：侧栏切到首页时视图可能整个被销毁，回来
                // 它是干净的；但 push 详情再返回时视图还在、搜索词必须留着（搜索结果
                // 里点进条目再返回，不该把搜索词和滚动位置清掉）。所以这里只在词确实
                // 非空时清，onChange 会顺带把取页键切回浏览页。
                if !searchText.isEmpty { searchText = "" }
            }
            await loadIfNeeded()
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索空态的副文案。单字：服务端 `searchTerm` 的分词不匹配单字（实测两字以上
    /// 的子串才命中），给「多输入几个字」的引导；剧集库：说明检索粒度是剧集条目
    /// 本身，单集标题搜不到（分集搜索是刻意不做的）。
    private func searchEmptyMessage(term: String) -> String? {
        guard isSearching else { return nil }
        if term.count < 2 { return "搜索至少要两个字，多输入几个字试试。" }
        return library.collectionType == .tvshows ? "只匹配剧集条目，单集标题不参与检索。" : nil
    }

    /// 首屏骨架：一墙和真实网格同列宽/同卡片尺寸的灰色海报卡，加载完原位替换。
    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
                ForEach(0..<Self.skeletonCount, id: \.self) { _ in
                    SkeletonPosterCard(width: cardWidth)
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.vertical, 28)
        }
        // 骨架不该比真实内容更能滚（滚动条会闪一下），也不用真去测窗口高度：
        // `LazyVGrid` 只实例化可视行，卡数给足够铺满最高常见窗口即可，多给不吃成本。
        .scrollDisabled(true)
        .skeletonShimmer()
    }

    private static let skeletonCount = 36

    private var subtitleText: String {
        if let totalCount {
            return "已加载 \(items.count) / \(totalCount)"
        }
        return items.isEmpty ? "" : "已加载 \(items.count)"
    }

    private var grid: some View {
        ScrollView {
            // footer 必须待在 lazy 容器里：`onAppear` 在非 lazy 的 ScrollView 内容
            // 里只在加入视图树时触发一次，那样第 3 页起就不会再自动预取。
            LazyVStack(spacing: 0) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
                    ForEach(items) { item in
                        PosterCard(item: item, server: app.server, width: cardWidth) {
                            app.openDetail(item)
                        }
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .padding(.horizontal, contentLeading)
                .padding(.vertical, 28)

                if hasMore || isLoadingMore {
                    loadMoreFooter
                        .padding(.bottom, 28)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await reload() }
        .animation(loadedMoreMotion, value: items.count)
    }

    /// 翻页新卡片入场过渡；减弱动态效果时直接显示。
    private var loadedMoreMotion: Animation? {
        reduceMotion ? nil : Motion.standard
    }

    private var loadMoreFooter: some View {
        VStack(spacing: 10) {
            if let loadError, !items.isEmpty {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isLoadingMore {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Button(UIStrings.loadMore) {
                    Task { await loadMore() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        // footer 进入可视区即预取下一页，不用手动点。前提是它待在 lazy 容器里
        // （见 grid 的 LazyVStack），否则只在加入视图树时触发一次。
        .onAppear {
            guard hasMore, !isLoading, !isLoadingMore else { return }
            Task { await loadMore() }
        }
    }

    /// 库类型 → 展示维度。剧集库要按「电视剧」列（而不是递归铺到每一集），
    /// 电影库按「电影」列。其它库类型暂时不映射（沿用递归叶子）。
    private var itemKinds: [MediaItem.Kind]? {
        switch library.collectionType {
        case .movies: return [.movie]
        case .tvshows: return [.series]
        default: return nil
        }
    }

    // MARK: - 排序与筛选

    /// 当前生效的排序字段：存档值不在该库候选集里（换了服务器 / 库类型变化）时回落名称。
    private var sortField: MediaItemsSortField {
        LibrarySort.resolvedField(rawValue: sortFieldRaw, collectionType: library.collectionType)
    }

    private var sortOptions: [MediaItemsSortField] {
        MediaItemsSortField.options(for: library.collectionType)
    }

    /// 当前生效的观看状态筛选（all = 不过滤）。
    private var watchState: MediaItemsWatchState {
        LibrarySort.resolvedWatchState(rawValue: watchStateRaw)
    }

    /// 右上角排序：系统下拉菜单（与 MoviePilot 首页菜单 / Bangumi 排序同款，
    /// macOS 26 / iOS 26 由系统渲染成液态玻璃）。三组单选：排序字段（带对勾）、
    /// 顺序（字段有方向时才有）、观看状态筛选。
    private var sortToolbarButton: some View {
        Menu {
            Picker("排序", selection: Binding(
                get: { sortField },
                set: { changeSort($0) }
            )) {
                ForEach(sortOptions, id: \.self) { field in
                    Label(field.sortLabel, systemImage: field.sortIcon).tag(field)
                }
            }
            .pickerStyle(.inline)

            if sortField.hasSortDirection {
                Picker("顺序", selection: Binding(
                    get: { sortAscending },
                    set: { setSortDirection($0) }
                )) {
                    Label("升序", systemImage: "arrow.up").tag(true)
                    Label("降序", systemImage: "arrow.down").tag(false)
                }
                .pickerStyle(.inline)
            }

            Picker("观看状态", selection: Binding(
                get: { watchState },
                set: { changeWatchState($0) }
            )) {
                ForEach(MediaItemsWatchState.allCases, id: \.self) { state in
                    Label(state.watchLabel, systemImage: state.watchIcon).tag(state)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("排序与观看状态筛选")
        .accessibilityLabel("排序与观看状态筛选")
        .accessibilityValue(
            watchState == .all ? sortField.sortLabel : "\(sortField.sortLabel)、\(watchState.watchLabel)"
        )
    }

    /// 换字段：方向重置到该字段的自然默认（避免「评分按低到高」这种反直觉组合）。
    private func changeSort(_ field: MediaItemsSortField) {
        guard field != sortField else { return }
        sortFieldRaw = field.rawValue
        sortAscending = field.defaultAscending
        reloadFromFirstPage()
    }

    private func setSortDirection(_ ascending: Bool) {
        guard ascending != sortAscending else { return }
        sortAscending = ascending
        reloadFromFirstPage()
    }

    private func changeWatchState(_ state: MediaItemsWatchState) {
        guard state != watchState else { return }
        watchStateRaw = state.rawValue
        reloadFromFirstPage()
    }

    /// 排序或观看状态变了，旧分页在新条件下是错序 / 多余数据：作废缓存从第一页重取。
    /// `activeLoadID` 会让在途的旧请求落账前自行作废，不会写回过期页。
    /// 同步入口，不关心在途请求（下拉刷新 / 排序这类用户动作本来就该重来一次）。
    private func reloadFromFirstPage() {
        prepareFirstPageReload()
        Task { await load(reset: true) }
    }

    /// 搜索词变了：在防抖 Task 里直接 `await`，`searchDebounce?.cancel()` 才能把
    /// 取消传到 URLSession。同步入口新起的是游离 Task，取消不到。
    private func reloadFromFirstPageCancellable() async {
        // 清空搜索框回到浏览页时，浏览页那一格本来就有缓存——它是「切走再回来」的
        // 落脚点，不会被搜索作废。此时若照常清缓存重拉，网格会先空一帧、再进骨架屏，
        // 白闪一次；直接用现成的。搜索词**之间**的切换没有这个性质（旧词的格子随新
        // 词作废丢弃），照常清掉重拉。
        if let cached = currentPage, !cached.items.isEmpty {
            isLoading = false
            isLoadingMore = false
            loadError = nil
            return
        }
        prepareFirstPageReload()
        await load(reset: true)
    }

    /// 作废本库缓存并进入首屏加载态。
    ///
    /// `isLoading` 必须在 `clearLibraryPage` **之前**置位：清缓存那一拍 items 已经
    /// 变空、isLoading 还是 false，body 会命中 `items.isEmpty` 分支闪一帧空态
    /// （搜索时就是闪一帧「没有匹配」）。
    private func prepareFirstPageReload() {
        isLoading = true
        isLoadingMore = false
        app.clearLibraryPage(for: library.id, searchTerm: currentPageSearchTerm)
    }

    /// 切到这个库时：缓存里已经有内容就直接用，不重新请求。
    /// 视图实例在两个库之间是复用的（同一个 `case .library` 分支），
    /// 所以这里要顺手把上一个库残留的加载/错误态清掉。
    private func loadIfNeeded() async {
        loadError = nil
        guard items.isEmpty else {
            isLoading = false
            isLoadingMore = false
            return
        }
        await load(reset: true)
    }

    private func reload() async {
        await load(reset: true)
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard let server = app.server else {
            isLoading = false
            isLoadingMore = false
            return
        }

        let loadID = UUID()
        activeLoadID = loadID

        let libraryID = library.id
        // 只信启动这次请求时还生效的那个词：防抖窗口里用户又改了词的话，这个请求
        // 的结果属于旧词，不能写进（已经切到新词的）当前格。
        let term = currentPageSearchTerm
        let key = AppModel.LibraryPageKey(libraryID: libraryID, searchTerm: term)
        let kinds = itemKinds
        let startIndex = reset ? 0 : nextStartIndex

        if reset {
            isLoading = true
            loadError = nil
        } else {
            isLoadingMore = true
            loadError = nil
        }
        defer {
            // 取消 = 调用方（搜索防抖）马上会用新条件重来一次，这里不能把加载态
            // 落下去：缓存已在 prepareFirstPageReload 里清空，「非加载态 + 空 items」
            // 会闪一帧空态（搜索时就是闪「没有匹配」）。翻页取消没有这个语义，照常落。
            //
            // 用户已经切到别的词时（`term != currentPageSearchTerm`）也不再落：那个
            // 词自己的请求正在跑，它会负责收尾，这里落下去只会把它的加载态提前抹掉。
            if activeLoadID == loadID, !(reset && Task.isCancelled),
               term == currentPageSearchTerm {
                isLoading = false
                isLoadingMore = false
            }
        }

        do {
            let page = try await server.itemsPage(
                parentID: libraryID,
                kinds: kinds,
                recursive: true,
                startIndex: startIndex,
                limit: Self.pageSize,
                sort: MediaItemsSort(field: sortField, ascending: sortAscending),
                watchState: watchState,
                // 用启动时的 `term` 而不是 `isSearching ? searchText : nil`：后者会在
                // await 期间被改词影响，让「第一个词的结果」落到「第二个词的格子」里。
                searchTerm: term.isEmpty ? nil : term
            )
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            var cached = reset ? AppModel.LibraryPage() : (app.libraryPages[key] ?? .init())
            if reset {
                cached.items = page.items
            } else {
                // 防御服务端重复页：按 id 去重追加。
                var existing = Set(cached.items.map(\.id))
                cached.items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
            }
            cached.totalCount = page.totalRecordCount
            cached.nextStartIndex = startIndex + page.items.count
            cached.lastPageWasFull = page.items.count >= Self.pageSize
            app.cacheLibraryPage(cached, for: libraryID, searchTerm: term)
            loadError = nil
        } catch is CancellationError {
            return
        } catch let e as JellyfinKit.JellyfinError {
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            loadError = e.errorDescription
        } catch {
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            loadError = "\(error)"
        }
    }
}
