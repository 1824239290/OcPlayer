import Foundation
import Observation
import SwiftUI

/// 列表加载的统一状态：空转 / 首载 / 成功 / 失败。
public enum LoadableState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var value: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// 分页列表加载器：把「isLoading / isLoadingMore / loadError / hasMore /
/// 代次守卫 / 追加去重」这套每个列表页都抄一遍的状态机收成一份。
///
/// 语义（从 LibraryView / BangumiHomeView / BangumiCollectionListView 三份
/// 手写实现归纳）：
/// - `loadInitial` 与 `loadMore` 互斥，重入直接丢弃；
/// - 代次守卫：响应回来时若期间发生过 `reload`（或另一次 `loadInitial`），
///   这一页结果作废——防止旧条件的数据污染新列表；
/// - 追加以 `id` 去重（同步窗口内本地库被改过时同一条目可能重复出现）；
/// - `hasMore`：服务端给了 total 按 total 判，没给按「最后一页是否满页」判。
@MainActor
@Observable
public final class PagedListLoader<Item: Identifiable> {
    public struct Page {
        public var items: [Item]
        /// 服务端给的总数；nil = 服务不返回总数（按满页判断 hasMore）。
        public var total: Int?

        public init(items: [Item], total: Int? = nil) {
            self.items = items
            self.total = total
        }
    }

    public private(set) var items: [Item] = []
    public private(set) var totalCount: Int?
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var loadError: String?

    /// 翻页/重取代次。响应回来只对当代次生效。
    private var generation: UInt64 = 0
    /// 最后一页是否满页（服务端不返 total 时的 hasMore 依据）。
    private var lastPageWasFull = true

    public let pageSize: Int
    private let fetch: @MainActor (Int, Int) async throws -> Page
    private let errorMessage: (Error) -> String
    /// 取消类错误（用户改输入/切条件把请求作废）不算失败，不占错误位。
    private let isCancellation: (Error) -> Bool

    /// - Parameters:
    ///   - pageSize: 每页条数。
    ///   - fetch: (offset, limit) → 一页数据。
    ///   - errorMessage: 错误 → 用户文案。默认 `localizedDescription`。
    ///   - isCancellation: 取消类错误判定（默认只认 CancellationError）。
    public init(
        pageSize: Int,
        fetch: @escaping @MainActor (Int, Int) async throws -> Page,
        errorMessage: @escaping (Error) -> String = { $0.localizedDescription },
        isCancellation: @escaping (Error) -> Bool = { $0 is CancellationError }
    ) {
        self.pageSize = pageSize
        self.fetch = fetch
        self.errorMessage = errorMessage
        self.isCancellation = isCancellation
    }

    public var hasMore: Bool {
        if let totalCount { return items.count < totalCount }
        return lastPageWasFull && !items.isEmpty
    }

    /// 首载 / 整份重取。进行中的翻页结果随后会被代次守卫丢弃。
    public func loadInitial() async {
        generation &+= 1
        let gen = generation
        isLoading = true
        isLoadingMore = false
        loadError = nil
        defer { if generation == gen { isLoading = false } }
        do {
            let page = try await fetch(0, pageSize)
            guard generation == gen else { return }
            items = Self.deduped(page.items)
            totalCount = page.total
            lastPageWasFull = page.items.count >= pageSize
        } catch {
            guard generation == gen, !isCancellation(error) else { return }
            loadError = errorMessage(error)
        }
    }

    /// 追加下一页。重入 / 没有更多 / 首载进行中时直接返回。
    public func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let gen = generation
        isLoadingMore = true
        defer { if generation == gen { isLoadingMore = false } }
        do {
            let page = try await fetch(items.count, pageSize)
            guard generation == gen else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            totalCount = page.total ?? totalCount
            lastPageWasFull = page.items.count >= pageSize
        } catch {
            // 翻页失败不覆盖整页错误位——列表内容还在，错误留给下一次滚动触发重试。
            guard generation == gen else { return }
        }
    }

    /// 显式重试（空态/错误位的「重试」按钮）。
    public func retry() async {
        if items.isEmpty {
            await loadInitial()
        } else {
            await loadMore()
        }
    }

    // MARK: - 带外变更（同步/单条刷新等不走翻页路径的写入）

    /// 按 id 原位替换一条（单条刷新回来用）；不存在则不动。
    public func replace(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    /// 按 id 移除一条（条目已离开列表语义时用，如「在看」被取消收藏）。
    public func remove(id: Item.ID) {
        items.removeAll { $0.id == id }
    }

    /// 带外失败（同步失败等）也要占错误位——列表为空时让用户看到失败而不是空态。
    public func reportError(_ message: String) {
        loadError = message
    }

    private static func deduped(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// 分页列表尾部：自动触发翻页 + 手动「加载更多」+ 首载失败的占位由调用方按
/// `loader.loadError` 自行渲染（空态文案各页不同）。
public struct LoadMoreFooter<Item: Identifiable>: View {
    public let loader: PagedListLoader<Item>

    public init(loader: PagedListLoader<Item>) {
        self.loader = loader
    }

    public var body: some View {
        if loader.hasMore || loader.isLoadingMore {
            HStack(spacing: 8) {
                if loader.isLoadingMore {
                    ProgressView().controlSize(.small)
                } else {
                    Button(UIStrings.loadMore) {
                        Task { await loader.loadMore() }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // 滚到底附近自动翻页；视图为空（不满足 hasMore）时不渲染也就不会触发。
            .onAppear {
                Task { await loader.loadMore() }
            }
        }
    }
}
