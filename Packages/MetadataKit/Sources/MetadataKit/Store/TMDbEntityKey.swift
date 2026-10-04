import Foundation

/// TMDb 实体的**存储键**：一首/一季/一集的唯一定位串。
///
/// 单独抽出来是因为它同时承担三件事，散在各处写字符串容易漂移：
/// 1. 作为 `tmdb_entity` 的主键（跨启动必须稳定，故不含任何进程内值）
/// 2. 判断「两个条目是不是同一个 TMDb 实体」（如剧与其季的归属）
/// 3. 诊断日志里可读
///
/// 形态（**故意做得像 URL 路径**，因为 TMDb 自己的端点就是这个形状，便于对照）：
/// ```
/// movie/603
/// tv/1399
/// tv/1399/season/1
/// ```
public enum TMDbEntityKey: Hashable, Sendable, CustomStringConvertible {

    /// 电影。
    case movie(Int)
    /// 剧集。
    case tv(Int)
    /// 某剧的某一季。**季没有独立的 TMDb id**（实测：Jellyfin 的季级 ProviderIds
    /// 只有 Tvdb、没有 Tmdb），只能由父剧 id + 季号定位。
    case season(tvID: Int, number: Int)

    public var storageKey: String {
        switch self {
        case .movie(let id): "movie/\(id)"
        case .tv(let id): "tv/\(id)"
        case .season(let tvID, let number): "tv/\(tvID)/season/\(number)"
        }
    }

    public var description: String { storageKey }

    /// 顶层实体（电影/剧）的 TMDb id；季没有自己的 id，返回所含的**剧** id。
    public var tmdbID: Int {
        switch self {
        case .movie(let id), .tv(let id): id
        case .season(let tvID, _): tvID
        }
    }

    public var kind: TMDbMediaType {
        switch self {
        case .movie: .movie
        case .tv: .tv
        case .season: .season
        }
    }

    /// 反解（从库里读回来时用）。无法识别返回 nil。
    public init?(storageKey: String) {
        let parts = storageKey.split(separator: "/").map(String.init)
        switch parts.count {
        case 2:
            guard let id = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "movie": self = .movie(id)
            case "tv": self = .tv(id)
            default: return nil
            }
        case 4:
            guard parts[0] == "tv", parts[2] == "season",
                  let tvID = Int(parts[1]), let number = Int(parts[3]) else { return nil }
            self = .season(tvID: tvID, number: number)
        default:
            return nil
        }
    }
}

/// 「条目 → TMDb 实体」的对应关系是怎么来的。
///
/// 存进库是为了**区分用户手动认定的与自动猜的**：手动匹配过的条目将来重新补全时
/// 不该被自动匹配顶掉（那是用户在纠正我们）。
public enum TMDbLinkSource: String, Sendable, Codable {
    /// 服务端 `ProviderIds["Tmdb"]` 直接给出（权威，置信度 1.0）。
    case providerID
    /// 标题搜索匹配上的（置信度见 `TMDbMatch.confidence`）。
    case search
    /// 用户在手动匹配面板里选定（Phase 3；已先留出入口）。
    case manual

    /// 是否**不可被自动匹配覆盖**。
    public var isAuthoritative: Bool {
        switch self {
        case .providerID, .manual: true
        case .search: false
        }
    }
}

/// 一条已建立的对应关系（从库里读回来的形态）。
public struct TMDbLink: Sendable, Equatable {
    public var itemID: String
    public var entityKey: TMDbEntityKey
    public var source: TMDbLinkSource
    public var confidence: Double
    public var linkedAt: Date

    public init(itemID: String, entityKey: TMDbEntityKey,
                source: TMDbLinkSource, confidence: Double, linkedAt: Date) {
        self.itemID = itemID
        self.entityKey = entityKey
        self.source = source
        self.confidence = confidence
        self.linkedAt = linkedAt
    }
}
