import Foundation
import MoviePilotKit

/// 种子筛选条件（语义对齐 MP 网页端 `useTorrentFilter`）：
/// 多选、精确等值匹配；**空选 = 不过滤**；有选择而字段为 nil 的条目被排除。
struct TorrentFilters: Equatable {
    var site: Set<String> = []
    /// 促销状态（volume_factor 文案：免费 / 普通 / 2x免费…）。
    var freeState: Set<String> = []
    /// 季集（S01 / S01E02…）。
    var season: Set<String> = []
    var releaseGroup: Set<String> = []
    var videoCode: Set<String> = []
    var edition: Set<String> = []
    var resolution: Set<String> = []

    var isActive: Bool {
        activeCount > 0
    }

    var activeCount: Int {
        site.count + freeState.count + season.count + releaseGroup.count
            + videoCode.count + edition.count + resolution.count
    }

    /// 激活项摘要（chips 展示用），如「站点 萝莉、馒头 · 促销 免费」。
    var activeSummary: String {
        var parts: [String] = []
        func append(_ label: String, _ values: Set<String>) {
            if !values.isEmpty {
                parts.append("\(label) \(values.sorted().joined(separator: "、"))")
            }
        }
        append("站点", site)
        append("促销", freeState)
        append("季集", season)
        append("制作组", releaseGroup)
        append("编码", videoCode)
        append("版本", edition)
        append("分辨率", resolution)
        return parts.joined(separator: " · ")
    }

    func matches(_ torrent: MPTorrent) -> Bool {
        pass(site, torrent.siteName)
            && pass(freeState, torrent.volumeFactor)
            && pass(season, torrent.seasonEpisode)
            && pass(releaseGroup, torrent.resourceTeam)
            && pass(videoCode, torrent.videoEncode)
            && pass(edition, torrent.edition)
            && pass(resolution, torrent.resourcePix)
    }

    private func pass(_ filter: Set<String>, _ value: String?) -> Bool {
        filter.isEmpty || (value.map { filter.contains($0) } ?? false)
    }
}

/// 排序字段（对齐 MP 网页端 sortTitles）。
enum TorrentSortField: String, CaseIterable {
    /// 站点优先级（pri_order，MP 的 default）。
    case defaultOrder = "default"
    case site
    case size
    case seeder
    case publishTime

    var label: String {
        switch self {
        case .defaultOrder: "默认"
        case .site: "站点"
        case .size: "大小"
        case .seeder: "做种"
        case .publishTime: "时间"
        }
    }
}

/// 筛选分组的字段元数据（对齐 MP 网页端 TorrentFilterBar 的分组顺序与文案：
/// 站点 / 季 / 促销 / 编码 / 质量 / 分辨率 / 制作组）。顺序即筛选条按钮顺序。
enum TorrentFilterField: String, CaseIterable, Identifiable {
    case site
    case season
    case freeState
    case videoCode
    case edition
    case resolution
    case releaseGroup

    var id: String { rawValue }

    var label: String {
        switch self {
        case .site: "站点"
        case .season: "季"
        case .freeState: "促销"
        case .videoCode: "编码"
        case .edition: "质量"
        case .resolution: "分辨率"
        case .releaseGroup: "制作组"
        }
    }

    /// SF Symbol（对齐 MP 网页端各组的图标语义）。
    var icon: String {
        switch self {
        case .site: "display"
        case .season: "square.stack.3d.up"
        case .freeState: "gift"
        case .videoCode: "video"
        case .edition: "opticaldiscdrive"
        case .resolution: "tv"
        case .releaseGroup: "person.3"
        }
    }

    /// 选中集在 `TorrentFilters` 里的落点（弹窗勾选 / 移除 chip 都经它写）。
    var selectionKeyPath: WritableKeyPath<TorrentFilters, Set<String>> {
        switch self {
        case .site: \TorrentFilters.site
        case .season: \TorrentFilters.season
        case .freeState: \TorrentFilters.freeState
        case .videoCode: \TorrentFilters.videoCode
        case .edition: \TorrentFilters.edition
        case .resolution: \TorrentFilters.resolution
        case .releaseGroup: \TorrentFilters.releaseGroup
        }
    }

    /// 候选值在 `TorrentFilterEngine.Options` 里的落点。
    var optionsKeyPath: KeyPath<TorrentFilterEngine.Options, [String]> {
        switch self {
        case .site: \TorrentFilterEngine.Options.site
        case .season: \TorrentFilterEngine.Options.season
        case .freeState: \TorrentFilterEngine.Options.freeState
        case .videoCode: \TorrentFilterEngine.Options.videoCode
        case .edition: \TorrentFilterEngine.Options.edition
        case .resolution: \TorrentFilterEngine.Options.resolution
        case .releaseGroup: \TorrentFilterEngine.Options.releaseGroup
        }
    }
}

/// 纯函数筛选 / 排序 / 候选聚合。
enum TorrentFilterEngine {

    static func filtered(_ torrents: [MPTorrent], filters: TorrentFilters) -> [MPTorrent] {
        guard filters.isActive else { return torrents }
        return torrents.filter { filters.matches($0) }
    }

    /// 排序保持稳定（原顺序兜底），方向由调用方控制。
    static func sorted(
        _ torrents: [MPTorrent], field: TorrentSortField, ascending: Bool
    ) -> [MPTorrent] {
        let sign: Double = ascending ? 1 : -1
        return torrents.enumerated().map { (index, torrent) in (index, torrent) }
            .sorted { lhs, rhs in
                let order = compare(lhs.1, rhs.1, field: field) * sign
                if order != 0 { return order < 0 }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    private static func compare(
        _ lhs: MPTorrent, _ rhs: MPTorrent, field: TorrentSortField
    ) -> Double {
        switch field {
        case .defaultOrder:
            return Double(lhs.priOrder - rhs.priOrder)
        case .site:
            switch (lhs.siteName ?? "").compare(rhs.siteName ?? "", options: [.caseInsensitive, .numeric]) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        case .size:
            return (lhs.size ?? 0) - (rhs.size ?? 0)
        case .seeder:
            return Double((lhs.seeders ?? 0) - (rhs.seeders ?? 0))
        case .publishTime:
            // 服务端 pubdate 是 "yyyy-MM-dd HH:mm:ss"，字典序即时间序。
            let left = lhs.pubdate ?? ""
            let right = rhs.pubdate ?? ""
            if left == right { return 0 }
            return left < right ? -1 : 1
        }
    }

    // MARK: - 候选聚合

    struct Options {
        var site: [String] = []
        var freeState: [String] = []
        var season: [String] = []
        var releaseGroup: [String] = []
        var videoCode: [String] = []
        var edition: [String] = []
        var resolution: [String] = []
    }

    /// 从当前结果聚合各筛选项候选值（去重；季集按整季在前、季号倒序）。
    static func options(_ torrents: [MPTorrent]) -> Options {
        var options = Options()
        var site: Set<String> = []
        var freeState: Set<String> = []
        var season: Set<String> = []
        var releaseGroup: Set<String> = []
        var videoCode: Set<String> = []
        var edition: Set<String> = []
        var resolution: Set<String> = []

        for torrent in torrents {
            collect(&site, torrent.siteName)
            collect(&freeState, torrent.volumeFactor)
            collect(&season, torrent.seasonEpisode)
            collect(&releaseGroup, torrent.resourceTeam)
            collect(&videoCode, torrent.videoEncode)
            collect(&edition, torrent.edition)
            collect(&resolution, torrent.resourcePix)
        }
        options.site = site.sorted()
        options.freeState = freeState.sorted()
        options.season = season.sorted(by: seasonBefore)
        options.releaseGroup = releaseGroup.sorted()
        options.videoCode = videoCode.sorted()
        options.edition = edition.sorted()
        options.resolution = resolution.sorted()
        return options
    }

    private static func collect(_ set: inout Set<String>, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        set.insert(value)
    }

    /// "S02" 这类整季排在前面（季号大的在前），"S01E05" 单集跟在同季后面。
    private static func seasonBefore(_ lhs: String, _ rhs: String) -> Bool {
        let l = parseSeason(lhs)
        let r = parseSeason(rhs)
        if l.season != r.season { return l.season > r.season }
        if l.episode == nil && r.episode == nil { return lhs < rhs }
        if l.episode == nil { return true }
        if r.episode == nil { return false }
        if l.episode != r.episode { return l.episode! > r.episode! }
        return lhs < rhs
    }

    private static func parseSeason(_ text: String) -> (season: Int, episode: Int?) {
        // 形如 S01 / S01E02 / S2E3（识别结果的 season_episode 是规整的，宽容解析即可）。
        guard let match = text.range(of: #"S(\d+)(?:E(\d+))?"#, options: .regularExpression) else {
            return (0, nil)
        }
        let parts = text[match]
        let numbers = parts.dropFirst()
            .split(whereSeparator: { !"0123456789".contains($0) })
            .compactMap { Int($0) }
        guard let season = numbers.first else { return (0, nil) }
        return (season, numbers.count > 1 ? numbers[1] : nil)
    }
}
