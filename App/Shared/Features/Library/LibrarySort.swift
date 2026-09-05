import CoreModel
import JellyfinKit

/// 媒体库排序的 UI 层口径：文案、按库类型的候选集、每库持久化的回落解析。
/// 字段值域与服务端映射在 JellyfinKit（`MediaItemsSortField` / `MediaItemsSort`）。
extension MediaItemsSortField {
    var sortLabel: String {
        switch self {
        case .name: "名称"
        case .dateAdded: "最近添加"
        case .year: "发行年份"
        case .rating: "评分"
        case .runtime: "片长"
        case .random: "随机"
        }
    }

    /// 随机没有方向可言，下拉里不显示升降序。
    var hasSortDirection: Bool { self != .random }

    /// 自然默认方向：名称 A→Z 升，其余按「新 / 高 / 长」在前（降）。
    /// 换字段时方向重置到这个值，避免「评分按低到高」这种反直觉组合。
    var defaultAscending: Bool { self == .name }

    /// 按库类型给候选集：
    /// - 电影 / 合集：全字段；
    /// - 剧集：去掉片长（剧集的 Runtime 是单集时长，对整部剧排序意义不大，
    ///   服务端也不支持按集数排；「首播年」对剧集就是 ProductionYear，
    ///   与发行年份同字段，不重复出两项）；
    /// - 其它类型（混合内容 / 家庭视频 / 音乐 / 图书…）：评分年份常常缺失，
    ///   只留通用三项。
    static func options(for collectionType: MediaLibrary.CollectionType) -> [MediaItemsSortField] {
        switch collectionType {
        case .movies, .boxsets:
            [.name, .dateAdded, .year, .rating, .runtime, .random]
        case .tvshows:
            [.name, .dateAdded, .year, .rating, .random]
        default:
            [.name, .dateAdded, .random]
        }
    }
}

/// 每库持久化字段（rawValue）的回落解析：存档值不在该库候选集里
/// （换了服务器 / 库类型变化）时回落名称，宁可退回默认也不给不可用的选项。
enum LibrarySort {
    static func resolvedField(
        rawValue: String?,
        collectionType: MediaLibrary.CollectionType
    ) -> MediaItemsSortField {
        guard let rawValue,
              let field = MediaItemsSortField(rawValue: rawValue),
              MediaItemsSortField.options(for: collectionType).contains(field) else {
            return .name
        }
        return field
    }
}
