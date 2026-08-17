import CoreModel
import JellyfinKit
import SwiftUI

/// 媒体库网格页：海报墙。电影库直接铺所有电影，剧集库铺所有剧集。
struct LibraryView: View {
    @Environment(AppModel.self) private var app

    let library: MediaLibrary

    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Metrics.posterWidth + 8), spacing: Metrics.railSpacing)]
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
                    Button("重试") { Task { await load() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView("这里还没有内容", systemImage: "tray")
            } else {
                grid
            }
        }
        .navigationTitle(library.name)
        .task(id: library.id) { await load() }
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
        }
        .refreshable { await load() }
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

    private func load() async {
        guard let server = app.server, !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            items = try await server.items(parentID: library.id, kinds: itemKinds, recursive: true, limit: 500)
        } catch let e as JellyfinKit.JellyfinError {
            loadError = e.errorDescription
        } catch {
            loadError = "\(error)"
        }
        isLoading = false
    }
}
