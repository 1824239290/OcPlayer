import Foundation

/// Bangumi OAuth 应用凭证，登录/刷新 token 都需要。
/// 通过 xcconfig 注入 Info.plist（BANGUMI_APP_ID / BANGUMI_APP_SECRET）读取。
public struct BangumiAppInfo: Codable, Sendable {
    public var clientId: String
    public var clientSecret: String
    public var callbackURL: String

    public init(clientId: String, clientSecret: String, callbackURL: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.callbackURL = callbackURL
    }
}

/// OAuth token 交换接口的响应体（snake_case 由解码器转换）。
public struct BangumiTokenResponse: Codable, Sendable {
    public var accessToken: String
    public var expiresIn: UInt
    public var tokenType: String
    public var refreshToken: String

    public init(accessToken: String, expiresIn: UInt, tokenType: String, refreshToken: String) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.refreshToken = refreshToken
    }
}

/// 内存/持久化的登录凭证。`expiresAt` 是绝对过期时间，便于直接判断。
public struct BangumiAuth: Codable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String

    public init(response: BangumiTokenResponse) {
        self.accessToken = response.accessToken
        self.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        self.refreshToken = response.refreshToken
    }

    public func isExpired() -> Bool {
        Date() > expiresAt
    }
}

/// 条目类型
/// 1 书籍 / 2 动画 / 3 音乐 / 4 游戏 / 6 三次元（没有 5）
public enum BangumiSubjectType: Int, Codable, Identifiable, CaseIterable, Sendable {
    case none = 0
    case book = 1
    case anime = 2
    case music = 3
    case game = 4
    case real = 6

    public var id: Self { self }

    public init(_ value: Int = 0) {
        self = Self(rawValue: value) ?? .none
    }

    /// 有「剧集/章节」概念的类型，进度管理页面的分段选项。
    public static var progressTypes: [Self] {
        [.none, .book, .anime, .real]
    }

    public static var allTypes: [Self] {
        [.anime, .game, .book, .music, .real]
    }

    public var description: String {
        switch self {
        case .none: return "全部"
        case .book: return "书籍"
        case .anime: return "动画"
        case .music: return "音乐"
        case .game: return "游戏"
        case .real: return "三次元"
        }
    }

    public var icon: String {
        switch self {
        case .none: return "questionmark"
        case .book: return "book.closed"
        case .anime: return "film"
        case .music: return "music.note"
        case .game: return "gamecontroller"
        case .real: return "tv"
        }
    }
}

/// 收藏类型
/// 1 想看 / 2 看过 / 3 在看 / 4 搁置 / 5 抛弃
public enum BangumiCollectionType: Int, Codable, Identifiable, CaseIterable, Sendable {
    case none = 0
    case wish = 1
    case collect = 2
    case doing = 3
    case onHold = 4
    case dropped = 5

    public var id: Self { self }

    public init(_ value: Int = 0) {
        self = Self(rawValue: value) ?? .none
    }

    public static func allTypes() -> [Self] {
        [.wish, .collect, .doing, .onHold, .dropped]
    }

    /// 进度/收藏列表默认优先选中的类型。
    public static func timelineTypes() -> [Self] {
        [.doing, .collect]
    }

    public var icon: String {
        switch self {
        case .none: return "questionmark"
        case .wish: return "heart"
        case .collect: return "checkmark"
        case .doing: return "eyes"
        case .onHold: return "hourglass"
        case .dropped: return "trash"
        }
    }

    public func description(_ type: BangumiSubjectType?) -> String {
        let action: String
        switch type ?? .none {
        case .book: action = "读"
        case .music: action = "听"
        case .game: action = "玩"
        default: action = "看"
        }
        switch self {
        case .none: return "全部"
        case .wish: return "想" + action
        case .collect: return action + "过"
        case .doing: return "在" + action
        case .onHold: return "搁置"
        case .dropped: return "抛弃"
        }
    }
}

/// 单集类型
public enum BangumiEpisodeType: Int, Codable, Identifiable, CaseIterable, Sendable {
    case main = 0
    case sp = 1
    case op = 2
    case ed = 3
    case trailer = 4
    case mad = 5
    case other = 6

    public var id: Self { self }

    public init(_ value: Int = 0) {
        self = Self(rawValue: value) ?? .main
    }

    public var name: String {
        switch self {
        case .main: return "ep"
        case .sp: return "sp"
        case .op: return "op"
        case .ed: return "ed"
        case .trailer: return "trailer"
        case .mad: return "mad"
        case .other: return "other"
        }
    }

    public var description: String {
        switch self {
        case .main: return "本篇"
        case .sp: return "SP"
        case .op: return "OP"
        case .ed: return "ED"
        case .trailer: return "预告"
        case .mad: return "MAD"
        case .other: return "其他"
        }
    }
}

/// 单集收藏状态
/// 0 未收藏 / 1 想看 / 2 看过 / 3 抛弃
public enum BangumiEpisodeCollectionType: Int, Codable, Identifiable, CaseIterable, Sendable {
    case none = 0
    case wish = 1
    case collect = 2
    case dropped = 3

    public var id: Self { self }

    public init(_ value: Int = 0) {
        self = Self(rawValue: value) ?? .none
    }

    public var description: String {
        switch self {
        case .none: return "未收藏"
        case .wish: return "想看"
        case .collect: return "看过"
        case .dropped: return "抛弃了"
        }
    }

    public var action: String {
        switch self {
        case .none: return "撤销"
        case .wish: return "想看"
        case .collect: return "看过"
        case .dropped: return "抛弃"
        }
    }

    public var icon: String {
        switch self {
        case .none: return "arrow.counterclockwise"
        case .wish: return "heart"
        case .collect: return "checkmark"
        case .dropped: return "trash"
        }
    }

    public func otherTypes() -> [Self] {
        switch self {
        case .none: return [.collect, .wish, .dropped]
        case .wish: return [.none, .collect, .dropped]
        case .collect: return [.none, .wish, .dropped]
        case .dropped: return [.none, .collect, .wish]
        }
    }
}

/// 用户组
public enum BangumiUserGroup: Int, Codable, Sendable {
    case none = 0
    case admin = 1
    case bangumiManager = 2
    case doujinManager = 3
    case banned = 4
    case forbidden = 5
    case characterManager = 8
    case wikiManager = 9
    case user = 10
    case wikipedians = 11

    public init(_ value: Int = 0) {
        self = Self(rawValue: value) ?? .none
    }

    public var description: String {
        switch self {
        case .none: return "未知用户组"
        case .admin: return "管理员"
        case .bangumiManager: return "Bangumi 管理猿"
        case .doujinManager: return "天窗管理猿"
        case .banned: return "禁言用户"
        case .forbidden: return "禁止访问用户"
        case .characterManager: return "人物管理猿"
        case .wikiManager: return "维基条目管理猿"
        case .user: return "用户"
        case .wikipedians: return "维基人"
        }
    }
}

/// 条目封面图 URL 集合。
public struct BangumiSubjectImages: Codable, Hashable, Sendable {
    public var large: String
    public var common: String
    public var medium: String
    public var small: String
    public var grid: String

    public init(large: String = "", common: String = "", medium: String = "", small: String = "", grid: String = "") {
        self.large = large
        self.common = common
        self.medium = medium
        self.small = small
        self.grid = grid
    }

    enum CodingKeys: String, CodingKey {
        case large, common, medium, small, grid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let large = (try? container.decode(String.self, forKey: .large)) ?? ""
        let common = (try? container.decode(String.self, forKey: .common)) ?? ""
        let medium = (try? container.decode(String.self, forKey: .medium)) ?? ""
        let small = (try? container.decode(String.self, forKey: .small)) ?? ""
        let grid = (try? container.decode(String.self, forKey: .grid)) ?? ""

        self.large = large.isEmpty ? (medium.isEmpty ? small : medium) : large
        self.common = common.isEmpty ? self.large : common
        self.medium = medium.isEmpty ? self.large : medium
        self.small = small.isEmpty ? self.large : small
        self.grid = grid.isEmpty ? self.small : grid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(large, forKey: .large)
        try container.encode(common, forKey: .common)
        try container.encode(medium, forKey: .medium)
        try container.encode(small, forKey: .small)
        try container.encode(grid, forKey: .grid)
    }
}

/// 头像图 URL 集合。
public struct BangumiAvatar: Codable, Hashable, Sendable {
    public var large: String
    public var medium: String
    public var small: String

    public init(large: String = "", medium: String = "", small: String = "") {
        self.large = large
        self.medium = medium
        self.small = small
    }

    enum CodingKeys: String, CodingKey {
        case large, medium, small
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let large = (try? container.decode(String.self, forKey: .large)) ?? ""
        let medium = (try? container.decode(String.self, forKey: .medium)) ?? ""
        let small = (try? container.decode(String.self, forKey: .small)) ?? ""
        self.large = large
        self.medium = medium.isEmpty ? large : medium
        self.small = small.isEmpty ? (self.medium) : small
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(large, forKey: .large)
        try container.encode(medium, forKey: .medium)
        try container.encode(small, forKey: .small)
    }
}

/// 条目标签（名称 + 使用数）。
public struct BangumiTag: Codable, Hashable, Sendable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int = 0) {
        self.name = name
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case name, count
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
            self.count = (try? container.decode(Int.self, forKey: .count)) ?? 0
        } else if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            self.name = str
            self.count = 0
        } else {
            self.name = ""
            self.count = 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(count, forKey: .count)
    }
}

/// 条目放送/发行时间信息。
public struct BangumiSubjectAirtime: Codable, Hashable, Sendable {
    public var date: String
    public var month: Int
    public var weekday: Int
    public var year: Int

    public init(date: String?) {
        self.date = date ?? ""
        self.month = 0
        self.weekday = 0
        self.year = 0
    }

    enum CodingKeys: String, CodingKey {
        case date, month, weekday, year
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = (try? container.decode(String.self, forKey: .date)) ?? ""
        self.month = (try? container.decode(Int.self, forKey: .month)) ?? 0
        self.weekday = (try? container.decode(Int.self, forKey: .weekday)) ?? 0
        self.year = (try? container.decode(Int.self, forKey: .year)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(month, forKey: .month)
        try container.encode(weekday, forKey: .weekday)
        try container.encode(year, forKey: .year)
    }
}

/// 条目评分信息。
public struct BangumiSubjectRating: Codable, Hashable, Sendable {
    public var count: [Int]
    public var total: Int
    public var score: Float
    public var rank: Int

    public init() {
        self.count = []
        self.total = 0
        self.score = 0
        self.rank = 0
    }

    enum CodingKeys: String, CodingKey {
        case count, total, score, rank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let countArray = try? container.decode([Int].self, forKey: .count) {
            self.count = countArray
        } else if let countDict = try? container.decode([String: Int].self, forKey: .count) {
            var arr = Array(repeating: 0, count: 10)
            for (k, v) in countDict {
                if let idx = Int(k), idx >= 1, idx <= 10 {
                    arr[idx - 1] = v
                }
            }
            self.count = arr
        } else {
            self.count = []
        }
        self.total = (try? container.decode(Int.self, forKey: .total)) ?? 0
        if let s = try? container.decode(Float.self, forKey: .score) {
            self.score = s
        } else if let d = try? container.decode(Double.self, forKey: .score) {
            self.score = Float(d)
        } else {
            self.score = 0
        }
        self.rank = (try? container.decode(Int.self, forKey: .rank)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(total, forKey: .total)
        try container.encode(score, forKey: .score)
        try container.encode(rank, forKey: .rank)
    }
}

/// 当前用户的条目收藏信息（挂在 SubjectDTO.interest 上）。
public struct BangumiSubjectInterest: Codable, Hashable, Sendable {
    public var comment: String
    public var epStatus: Int
    public var volStatus: Int
    public var `private`: Bool
    public var rate: Int
    public var tags: [String]
    public var type: BangumiCollectionType
    public var updatedAt: Int

    public init(
        comment: String, epStatus: Int, volStatus: Int, `private`: Bool, rate: Int,
        tags: [String], type: BangumiCollectionType, updatedAt: Int
    ) {
        self.comment = comment
        self.epStatus = epStatus
        self.volStatus = volStatus
        self.`private` = `private`
        self.rate = rate
        self.tags = tags
        self.type = type
        self.updatedAt = updatedAt
    }

    /// 与新增字段兼容的缩略版本。
    public var slim: BangumiSlimSubjectInterest {
        BangumiSlimSubjectInterest(
            rate: rate, type: type, comment: comment, tags: tags, updatedAt: updatedAt)
    }
}

/// 条目收藏状态的缩略版本（挂在 SlimSubjectDTO 上）。
public struct BangumiSlimSubjectInterest: Codable, Hashable, Sendable {
    public var rate: Int
    public var type: BangumiCollectionType
    public var comment: String
    public var tags: [String]
    public var updatedAt: Int

    public init(rate: Int, type: BangumiCollectionType, comment: String, tags: [String], updatedAt: Int) {
        self.rate = rate
        self.type = type
        self.comment = comment
        self.tags = tags
        self.updatedAt = updatedAt
    }
}

/// 全站收藏统计（SubjectDTO.collection），key 是 CollectionType.rawValue 的字符串。
public typealias BangumiSubjectCollection = [String: Int]

public extension BangumiSubjectCollection {
    var wish: Int { self[String(BangumiCollectionType.wish.rawValue)] ?? 0 }
    var collect: Int { self[String(BangumiCollectionType.collect.rawValue)] ?? 0 }
    var doing: Int { self[String(BangumiCollectionType.doing.rawValue)] ?? 0 }
    var onHold: Int { self[String(BangumiCollectionType.onHold.rawValue)] ?? 0 }
    var dropped: Int { self[String(BangumiCollectionType.dropped.rawValue)] ?? 0 }
}

/// 当前用户的单集收藏状态（挂在 EpisodeDTO.collection 上）。
public struct BangumiEpisodeCollectionStatus: Codable, Hashable, Sendable {
    public var status: Int
    public var updatedAt: Int?

    public init(status: Int, updatedAt: Int?) {
        self.status = status
        self.updatedAt = updatedAt
    }

    public var typeEnum: BangumiEpisodeCollectionType {
        BangumiEpisodeCollectionType(status)
    }
}
