import CoreModel
import JellyfinKit
import SwiftUI

/// 媒体库网格页：海报墙。电影库直接铺电影，剧集库铺剧集。
/// 分页加载：首屏一页，底部「加载更多」继续，避免大库一次进内存。
struct LibraryView: View {
    @Environment(AppModel.self) private var app

    let library: MediaLibrary

    private static let pageSize = 100

    @State private var items: [MediaItem] = []
    @State private var totalCount: Int?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var activeLoadID: UUID?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterWidth + 8), spacing: Metrics.railSpacing)]
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
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, items.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") { Task { await reload() } }
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
        .task(id: library.id) { await reload() }
    }

    private var subtitleText: String {
        if let totalCount {
            return "已加载 \(items.count) / \(totalCount)"
        }
        return items.isEmpty ? "" : "已加载 \(items.count)"
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.railSpacing + 8) {
                ForEach(items) { item in
                    PosterCard(item: item, server: app.server) {
                        app.openDetail(item)
                    }
                }
            }
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.vertical, 28)

            if hasMore || isLoadingMore {
                loadMoreFooter
                    .padding(.bottom, 28)
            }
        }
        .refreshable { await reload() }
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

    private func reload() async {
        await load(reset: true)
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        let loadID = UUID()
        activeLoadID = loadID

        guard let server = app.server else {
            isLoading = false
            isLoadingMore = false
            return
        }

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
            if reset {
                items = page.items
            } else {
                // 防御服务端重复页：按 id 去重追加。
                let existing = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            totalCount = page.totalRecordCount
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
