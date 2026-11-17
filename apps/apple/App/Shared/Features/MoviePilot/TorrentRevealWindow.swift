import Foundation

/// 资源搜索结果列表的**展示窗口**：一次物化多少条进 `LazyVStack`。
///
/// ## 它解决的问题不是「条数」，是「容器怎么懒」
///
/// 全量结果必须留在内存（筛选候选聚合、下载时原样回传 `media_in` 都要它），
/// 所以「少存」不是选项；能省的只有**同时物化进视图树的行数**。
/// 窗口把这件事做成一个纯值：`shownCount(total:)` 给出该物化的前缀长度，
/// `reveal(total:)` 是触底续载，`clamp(total:)` 是结果变少后的收敛。
///
/// - Note: 窗口**只决定条数**。真正让它生效的是「卡片流必须是 `LazyVStack` 的
///   直接子视图」——`MoviePilotTorrentList` 的 body 一旦被 `VStack` 包住，
///   `LazyVStack` 会把那整块当成**一个**子视图一次求值，窗口再小也是全量物化
///   （2026-11-01 本机探针实测：60 条窗口 → 首帧物化 120 行，且触底续载再也
///   不触发）。两边是配套的，改一处必须同时看另一处。
///
/// ## 为什么是值类型、为什么不用 `PagedListLoader`
///
/// `PagedListLoader` 管的是**取数**（offset 分页、代次守卫、去重）；这里的数据
/// 来自一条 SSE 全量流（`/api/v1/search/title/stream`），没有 offset 可分，
/// 只有「已落账的全量数组」和「露多少」。两件事没有共同状态，硬套会让窗口
/// 跟着网络代次走（切筛选也会被当成重新取数）。
struct TorrentRevealWindow: Equatable {
    /// 一窗的条数：首窗、以及每次触底续载的步长。
    ///
    /// 60 是「一屏十几张玻璃卡」的六倍左右——单次续载远大于一屏，才能保证续载后
    /// footer 被新行顶出视口（否则 footer 会在视口里换身份、反复触发）。
    static let defaultPageSize = 60

    /// 每次续载的步长。
    let pageSize: Int
    /// 当前窗口上界（条数，不是下标）。
    private(set) var limit: Int

    init(pageSize: Int = TorrentRevealWindow.defaultPageSize) {
        self.pageSize = max(1, pageSize)
        self.limit = self.pageSize
    }

    /// 该物化多少条（永不越界）。
    func shownCount(total: Int) -> Int {
        min(limit, max(0, total))
    }

    /// 是否还有没露出来的结果（决定 footer 出不出现）。
    func hasMore(total: Int) -> Bool {
        shownCount(total: total) < max(0, total)
    }

    /// 触底续载一窗。
    ///
    /// 已经全露完了就什么都不做（流式批次继续增长时 footer 会重新出现，
    /// 那时这里才有事可做），所以「滚出滚回」最多只把窗口推到 `total`，
    /// 不会越过数据上界。
    mutating func reveal(total: Int) {
        let total = max(0, total)
        guard limit < total else { return }
        limit = min(limit + pageSize, total)
    }

    /// 结果变少（筛选 / 排序 / 新批次替换）后把窗口收敛回来。
    ///
    /// **不回落到一页以下**：窗口是「用户已经滚到多深」的记忆，筛掉一批之后再
    /// 放开条件，用户不该被弹回顶部重滚。上界夹到 `total`，避免 `prefix` 之外的
    /// 无意义持有。
    mutating func clamp(total: Int) {
        let total = max(0, total)
        limit = min(max(limit, pageSize), max(pageSize, total))
    }

    /// 新搜索：窗口打回首窗大小。
    mutating func reset() {
        limit = pageSize
    }
}
