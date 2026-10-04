import CoreModel
import Foundation
import JellyfinKit

/// 库页 / 搜索页的缓存键。
///
/// 与 `AppModel.LibraryPageKey`（库 + 搜索词）**同构**——那个键的存在理由在这里
/// 同样成立：库内搜索是把结果原地写进该库的分页缓存，键上不带搜索词的话
/// 「浏览页」与「搜索页」会共用一格，切走再回来看到的就是上次的搜索残留。
///
/// 比 `LibraryPageKey` 多带排序 / 观看状态筛选 / 分页窗口：
/// - 排序：换排序时旧页在新顺序下是**错序数据**，不能当同一格复用；
/// - 观看状态：同理（「未看」与「全部」是两份不同的列表）；
/// - 分页窗口：按起始页分格，翻页只覆盖翻到过的那几格。
///
/// 各段一律用类型的 `rawValue`（都是 String 枚举），**不拼 `String(describing:)`**：
/// 后者会把调试格式写进缓存键，将来给类型加字段或改实现就静默产生新键，
/// 旧缓存全部失配（等于每次升级都白缓存一遍）。
public struct PageKey: Hashable, Sendable {
    public var parentID: String
    public var kinds: String
    public var sortKey: String
    public var watchState: String
    public var searchTerm: String
    public var startIndex: Int
    public var limit: Int

    public init(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?,
        searchTerm: String?,
        startIndex: Int,
        limit: Int
    ) {
        self.parentID = parentID ?? ""
        // 排序后拼接：调用方传参顺序不该影响缓存命中。
        self.kinds = (kinds ?? []).map(\.rawValue).sorted().joined(separator: ",")
        self.sortKey = sort.map { "\($0.field.rawValue):\($0.ascending ? "asc" : "desc")" } ?? ""
        self.watchState = watchState?.rawValue ?? ""
        self.searchTerm = searchTerm ?? ""
        self.startIndex = startIndex
        self.limit = limit
    }
}
