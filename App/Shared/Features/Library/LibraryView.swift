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

    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var activeLoadID: UUID?

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
        if let totalCount {
            return items.count < totalCount
        }
        // 总数未知时：上一页若满页，允许再试一页。
        return !items.isEmpty && items.count % Self.pageSize == 0
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
        reduceMotion ? nil : .easeOut(duration: 0.25)
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
                Button("加载更多") {
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
                limit: Self.pageSize
            )
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            var cached = reset ? AppModel.LibraryPage() : (app.libraryPages[libraryID] ?? .init())
            if reset {
                cached.items = page.items
            } else {
                // 防御服务端重复页：按 id 去重追加。
                let existing = Set(cached.items.map(\.id))
                cached.items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            cached.totalCount = page.totalRecordCount
            app.libraryPages[libraryID] = cached
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
