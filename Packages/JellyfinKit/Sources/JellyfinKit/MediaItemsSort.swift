/// 媒体库网格的排序字段（传输层口径；UI 文案与按库类型的候选集在 App 层）。
/// 值域刻意收窄到 Emby / Jellyfin 两家服务端都稳定支持的 sortBy。
public enum MediaItemsSortField: String, Sendable, Equatable, CaseIterable {
    /// 名称（SortName）。
    case name
    /// 入库时间（DateCreated）——「最近进了什么」。
    case dateAdded
    /// 发行 / 首播年份（ProductionYear；对剧集就是首播年）。
    case year
    /// 社区评分（CommunityRating）。
    case rating
    /// 片长（Runtime；剧集条目是单集时长，剧集库不提供这项）。
    case runtime
    /// 服务端随机（Random），方向无意义。
    case random
}

/// 排序字段 + 方向的组合，直接透传给 items API 在**服务端**排序——
/// 分页大库本地只能排到手的第一页，全量顺序只有服务端能保证。
public struct MediaItemsSort: Sendable, Equatable {
    public var field: MediaItemsSortField
    public var ascending: Bool

    public init(field: MediaItemsSortField, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    /// 换算成 items API 的 sortBy / sortOrder（两个数组按下标一一配对）。
    /// 主键之外固定挂「名称升序」副键，同值不打架；随机只有单键，方向只是占位。
    ///
    /// 返回**原始串**而不是 SDK 枚举：Emby 走裸传输层直接用，Jellyfin 侧再转回
    /// `ItemSortBy` / `SortOrder`。一张表两家用，避免两份映射各自漂移。
    func rawKeysAndOrders() -> ([String], [String]) {
        let primary = ascending ? "Ascending" : "Descending"
        switch field {
        case .name:
            return (["SortName"], [primary])
        case .dateAdded:
            return (["DateCreated", "SortName"], [primary, "Ascending"])
        case .year:
            return (["ProductionYear", "SortName"], [primary, "Ascending"])
        case .rating:
            return (["CommunityRating", "SortName"], [primary, "Ascending"])
        case .runtime:
            return (["Runtime", "SortName"], [primary, "Ascending"])
        case .random:
            return (["Random"], [primary])
        }
    }
}

/// 观看状态筛选（isPlayed / isUnplayed 服务端过滤；all = 不过滤）。
/// 这是筛选不是排序——按状态排序只会把条目分成两坨，用户要的是「只看没看过的」。
public enum MediaItemsWatchState: String, Sendable, Equatable, CaseIterable {
    case all
    case watched
    case unwatched
}
