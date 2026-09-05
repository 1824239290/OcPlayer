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
    /// 最近一次拉取是否为服务端满页（hasMore 在总数未知时的判据）。
    @State private var lastPageFull = false
    @State private var activeLoadID: UUID?

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
    private var items: [MediaItem] { app.libraryPages[library.id]?.items ?? [] }
    private var totalCount: Int? { app.libraryPages[library.id]?.totalCount }

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
            return items.count < totalCount
        }
        // 总数未知时：上一页是服务端满页才允许再试。按本地条数取模的启发式
        // 会被去重/过滤干扰（100 条里去重掉 3 条就误判「没有更多了」）。
        return lastPageFull
    }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                skeletonGrid
            } else if let loadError, items.isEmpty {
                ContentUnavailableView {
                    Label(UIStrings.loadFailed, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(UIStrings.retry) { Task { await reload() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView("这里还没有内容", systemImage: "tray")
            } else {
                grid
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
        .task(id: library.id) { await loadIfNeeded() }
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
        // footer 进入可视区即预取下一页，不用手动点。
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
    private func reloadFromFirstPage() {
        app.clearLibraryPage(for: library.id)
        Task { await load(reset: true) }
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
        let kinds = itemKinds
        let startIndex = reset ? 0 : items.count

        if reset {
            isLoading = true
            loadError = nil
        } else {
            isLoadingMore = true
            loadError = nil
        }
        defer {
            if activeLoadID == loadID {
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
                watchState: watchState
            )
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            var cached = reset ? AppModel.LibraryPage() : (app.libraryPages[libraryID] ?? .init())
            if reset {
                cached.items = page.items
                lastPageFull = false
            } else {
                // 防御服务端重复页：按 id 去重追加。
                let existing = Set(cached.items.map(\.id))
                cached.items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            cached.totalCount = page.totalRecordCount
            lastPageFull = page.items.count == Self.pageSize
            app.cacheLibraryPage(cached, for: libraryID)
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
