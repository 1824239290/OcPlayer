import Foundation

/// 分页响应体。
public struct BangumiPagedDTO<T: Sendable & Codable>: Codable, Sendable {
    public var data: [T]
    public var total: Int

    public init(data: [T], total: Int) {
        self.data = data
        self.total = total
    }
}

/// 当前用户权限。
public struct BangumiPermissions: Codable, Hashable, Sendable {
    public var subjectWikiEdit: Bool

    public init(subjectWikiEdit: Bool) {
        self.subjectWikiEdit = subjectWikiEdit
    }
}

/// 登录用户的精简资料，持久化在 UserDefaults（profile key）。
public struct BangumiProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var avatar: BangumiAvatar?
    public var group: Int
    public var location: String
    public var nickname: String
    public var permissions: BangumiPermissions
    public var sign: String
    public var site: String
    public var username: String
    public var joinedAt: Int?

    public init() {
        self.id = 0
        self.username = ""
        self.nickname = "匿名"
        self.avatar = nil
        self.sign = ""
        self.joinedAt = 0
        self.group = 0
        self.location = ""
        self.permissions = BangumiPermissions(subjectWikiEdit: false)
        self.site = ""
    }

    public var name: String {
        nickname.isEmpty ? "用户\(username)" : nickname
    }

    public var groupEnum: BangumiUserGroup {
        BangumiUserGroup(group)
    }

    /// 编码成 JSON 字符串（与 Bangumi-iOS 的 AppConfig.profile 持久化方式一致）。
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    public init(from rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(BangumiProfile.self, from: data)
        else {
            self = BangumiProfile()
            return
        }
        self = decoded
    }
}

/// 完整条目（含当前用户收藏状态 interest）。
public struct BangumiSubjectDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var airtime: BangumiSubjectAirtime
    public var collection: BangumiSubjectCollection
    public var eps: Int
    public var images: BangumiSubjectImages?
    public var infobox: [BangumiInfoboxItem]
    public var info: String
    public var locked: Bool
    public var metaTags: [String]
    public var tags: [BangumiTag]
    public var name: String
    public var nameCN: String
    public var nsfw: Bool
    public var platform: BangumiSubjectPlatform
    public var rating: BangumiSubjectRating
    public var redirect: Int
    public var series: Bool
    public var seriesEntry: Int
    public var summary: String
    public var type: BangumiSubjectType
    public var volumes: Int
    public var interest: BangumiSubjectInterest?

    public init(
        id: Int,
        airtime: BangumiSubjectAirtime = BangumiSubjectAirtime(date: nil),
        collection: BangumiSubjectCollection = [:],
        eps: Int = 0,
        images: BangumiSubjectImages? = nil,
        infobox: [BangumiInfoboxItem] = [],
        info: String = "",
        locked: Bool = false,
        metaTags: [String] = [],
        tags: [BangumiTag] = [],
        name: String = "",
        nameCN: String = "",
        nsfw: Bool = false,
        platform: BangumiSubjectPlatform = BangumiSubjectPlatform(name: ""),
        rating: BangumiSubjectRating = BangumiSubjectRating(),
        redirect: Int = 0,
        series: Bool = false,
        seriesEntry: Int = 0,
        summary: String = "",
        type: BangumiSubjectType = .none,
        volumes: Int = 0,
        interest: BangumiSubjectInterest? = nil
    ) {
        self.id = id
        self.airtime = airtime
        self.collection = collection
        self.eps = eps
        self.images = images
        self.infobox = infobox
        self.info = info
        self.locked = locked
        self.metaTags = metaTags
        self.tags = tags
        self.name = name
        self.nameCN = nameCN
        self.nsfw = nsfw
        self.platform = platform
        self.rating = rating
        self.redirect = redirect
        self.series = series
        self.seriesEntry = seriesEntry
        self.summary = summary
        self.type = type
        self.volumes = volumes
        self.interest = interest
    }

    public var slim: BangumiSlimSubjectDTO {
        BangumiSlimSubjectDTO(self)
    }
}

/// 精简条目（搜索/他人收藏等场景）。
public struct BangumiSlimSubjectDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var images: BangumiSubjectImages?
    public var info: String?
    public var rating: BangumiSubjectRating?
    public var locked: Bool
    public var metaTags: [String]
    public var name: String
    public var nameCN: String
    public var nsfw: Bool
    public var type: BangumiSubjectType
    public var interest: BangumiSlimSubjectInterest?

    public init() {
        self.id = 0
        self.images = nil
        self.info = nil
        self.rating = nil
        self.locked = false
        self.metaTags = []
        self.name = ""
        self.nameCN = ""
        self.nsfw = false
        self.type = .none
        self.interest = nil
    }

    public init(_ subject: BangumiSubjectDTO) {
        self.id = subject.id
        self.images = subject.images
        self.info = subject.info
        self.rating = subject.rating
        self.locked = subject.locked
        self.metaTags = subject.metaTags
        self.name = subject.name
        self.nameCN = subject.nameCN
        self.nsfw = subject.nsfw
        self.type = subject.type
        self.interest = subject.interest?.slim
    }

    public func title(preferChinese: Bool) -> String {
        if preferChinese {
            return nameCN.isEmpty ? name : nameCN
        }
        return name
    }
}

/// 条目信息框条目（infobox 的「键」）。
public struct BangumiInfoboxItem: Codable, Hashable, Sendable {
    public var key: String
    public var values: [BangumiInfoboxValue]

    public init(key: String, values: [BangumiInfoboxValue]) {
        self.key = key
        self.values = values
    }

    /// 提取出非空展示文本
    public var displayValuesText: String {
        let texts = values.compactMap { val -> String? in
            let trimmed = val.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return texts.joined(separator: "、")
    }

    public var hasValue: Bool {
        !displayValuesText.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case key
        case values
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)

        if let valuesArray = try? container.decode([BangumiInfoboxValue].self, forKey: .values) {
            self.values = valuesArray
        } else if let valuesArray = try? container.decode([BangumiInfoboxValue].self, forKey: .value) {
            self.values = valuesArray
        } else if let singleString = try? container.decode(String.self, forKey: .value) {
            self.values = [BangumiInfoboxValue(text: singleString)]
        } else {
            self.values = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(values, forKey: .values)
    }
}

/// 条目信息框值（可能带链接）。
public struct BangumiInfoboxValue: Codable, Hashable, Sendable {
    public var text: String?
    public var link: String?
    public var key: String?

    public init(text: String? = nil, link: String? = nil, key: String? = nil) {
        self.text = text
        self.link = link
        self.key = key
    }

    enum CodingKeys: String, CodingKey {
        case text
        case v
        case value
        case link
        case l
        case k
        case key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? container.decode(String.self, forKey: .v) {
            self.text = v
        } else if let text = try? container.decode(String.self, forKey: .text) {
            self.text = text
        } else if let val = try? container.decode(String.self, forKey: .value) {
            self.text = val
        } else {
            self.text = nil
        }

        if let l = try? container.decode(String.self, forKey: .l) {
            self.link = l
        } else if let link = try? container.decode(String.self, forKey: .link) {
            self.link = link
        } else {
            self.link = nil
        }

        if let k = try? container.decode(String.self, forKey: .k) {
            self.key = k
        } else if let key = try? container.decode(String.self, forKey: .key) {
            self.key = key
        } else {
            self.key = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .v)
        try container.encodeIfPresent(link, forKey: .l)
        try container.encodeIfPresent(key, forKey: .k)
    }
}

/// 条目平台/制作组信息。
public struct BangumiSubjectPlatform: Codable, Hashable, Sendable {
    public var alias: String
    public var id: Int
    public var searchString: String?
    public var sortKeys: [String]?
    public var type: String
    public var typeCN: String
    public var wikiTpl: String?

    public init(name: String) {
        self.alias = ""
        self.id = 0
        self.searchString = ""
        self.sortKeys = []
        self.type = ""
        self.typeCN = name
        self.wikiTpl = ""
    }
}

/// 单个章节。
public struct BangumiEpisodeDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var subjectID: Int
    public var type: BangumiEpisodeType
    public var sort: Float
    public var name: String
    public var nameCN: String
    public var duration: String
    public var airdate: String
    public var comment: Int
    public var disc: Int
    public var desc: String?
    public var collection: BangumiEpisodeCollectionStatus?
    public var subject: BangumiSlimSubjectDTO?

    public init(
        id: Int,
        subjectID: Int,
        type: BangumiEpisodeType,
        sort: Float,
        name: String,
        nameCN: String,
        duration: String,
        airdate: String,
        comment: Int,
        disc: Int,
        desc: String? = nil,
        collection: BangumiEpisodeCollectionStatus? = nil,
        subject: BangumiSlimSubjectDTO? = nil
    ) {
        self.id = id
        self.subjectID = subjectID
        self.type = type
        self.sort = sort
        self.name = name
        self.nameCN = nameCN
        self.duration = duration
        self.airdate = airdate
        self.comment = comment
        self.disc = disc
        self.desc = desc
        self.collection = collection
        self.subject = subject
    }

    public var collectionTypeEnum: BangumiEpisodeCollectionType {
        collection?.typeEnum ?? .none
    }

    /// 该集是否已开播（airdate 有值且不晚于今天）。
    public var aired: Bool {
        guard !airdate.isEmpty else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: airdate) else { return false }
        return date <= Date()
    }

    /// 集号显示文本（整数补零两位，小数保留一位）。
    public var sortDisplay: String {
        if sort == sort.rounded() {
            return String(format: "%02d", Int(sort))
        }
        return String(format: "%.1f", sort)
    }

    /// 标题（优先中文名）。
    public func title(preferChinese: Bool) -> String {
        let epName = preferChinese && !nameCN.isEmpty ? nameCN : name
        return "\(type.name).\(sortDisplay) \(epName)"
    }
}

/// 进度页面用的条目 + 近期剧集窗口组合。
public struct BangumiProgressSubject: Codable, Hashable, Identifiable, Sendable {
    public var subject: BangumiSubjectDTO
    public var episodes: [BangumiEpisodeDTO]

    public var id: Int { subject.id }

    public init(subject: BangumiSubjectDTO, episodes: [BangumiEpisodeDTO]) {
        self.subject = subject
        self.episodes = episodes
    }

    /// 已看集数 / 总集数。
    public var progressText: String {
        "\(watchedCount) / \(subject.eps)"
    }

    public var watchedCount: Int {
        subject.interest?.epStatus ?? 0
    }

    public var progressFraction: Double? {
        guard subject.eps > 0 else { return nil }
        return min(Double(watchedCount) / Double(subject.eps), 1)
    }

    /// 本地章节是否已补齐（进度页据此区分「还没同步到」和「真的没有章节」）。
    public var hasEpisodeData: Bool { !episodes.isEmpty }

    /// 下一集待看的本篇（nil = 没有可标记的下一集）。
    public var nextEpisode: BangumiEpisodeDTO? {
        episodes.first { $0.type == .main && $0.collectionTypeEnum == .none }
    }

    /// 是否确实看完了。
    ///
    /// **不能用「找不到下一集」来判断**：章节还没同步下来时列表本来就是空的，
    /// 那种情况要显示成「等待同步」而不是「已看完」。
    public var isFinished: Bool {
        guard subject.eps > 0 else { return hasEpisodeData && nextEpisode == nil }
        return watchedCount >= subject.eps
    }
}

// MARK: - 每日放送（番剧时间表）



/// 每日放送按星期分组的 DTO。
public struct BangumiCalendarDayDTO: Codable, Identifiable, Hashable, Sendable {
    public var weekday: BangumiCalendarWeekdayDTO
    public var items: [BangumiCalendarItemDTO]

    public var id: Int { weekday.id }

    public init(weekday: BangumiCalendarWeekdayDTO, items: [BangumiCalendarItemDTO] = []) {
        self.weekday = weekday
        self.items = items
    }
}

/// 每日放送星期信息。
public struct BangumiCalendarWeekdayDTO: Codable, Identifiable, Hashable, Sendable {
    public var en: String
    public var cn: String
    public var ja: String
    public var id: Int

    public init(en: String, cn: String, ja: String, id: Int) {
        self.en = en
        self.cn = cn
        self.ja = ja
        self.id = id
    }

    /// 短中文名称（如：周一、周二）。
    public var shortCN: String {
        switch id {
        case 1: return "周一"
        case 2: return "周二"
        case 3: return "周三"
        case 4: return "周四"
        case 5: return "周五"
        case 6: return "周六"
        case 7: return "周日"
        default: return cn
        }
    }
}

/// 每日放送单条番剧条目。
public struct BangumiCalendarItemDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var url: String
    public var type: BangumiSubjectType
    public var name: String
    public var nameCN: String
    public var summary: String?
    public var airDate: String?
    public var airWeekday: Int?
    public var rating: BangumiSubjectRating?
    public var rank: Int?
    public var images: BangumiSubjectImages?
    public var collection: BangumiSubjectCollection?

    public init(
        id: Int,
        url: String = "",
        type: BangumiSubjectType = .anime,
        name: String = "",
        nameCN: String = "",
        summary: String? = nil,
        airDate: String? = nil,
        airWeekday: Int? = nil,
        rating: BangumiSubjectRating? = nil,
        rank: Int? = nil,
        images: BangumiSubjectImages? = nil,
        collection: BangumiSubjectCollection? = nil
    ) {
        self.id = id
        self.url = url
        self.type = type
        self.name = name
        self.nameCN = nameCN
        self.summary = summary
        self.airDate = airDate
        self.airWeekday = airWeekday
        self.rating = rating
        self.rank = rank
        self.images = images
        self.collection = collection
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case type
        case name
        case nameCn
        case nameCN
        case summary
        case airDate
        case airWeekday
        case rating
        case rank
        case images
        case collection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
        if let typeInt = try? container.decode(Int.self, forKey: .type) {
            self.type = BangumiSubjectType(typeInt)
        } else if let typeEnum = try? container.decode(BangumiSubjectType.self, forKey: .type) {
            self.type = typeEnum
        } else {
            self.type = .anime
        }
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.nameCN = (try? container.decode(String.self, forKey: .nameCn))
            ?? (try? container.decode(String.self, forKey: .nameCN))
            ?? ""
        self.summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        self.airDate = try? container.decodeIfPresent(String.self, forKey: .airDate)
        self.airWeekday = try? container.decodeIfPresent(Int.self, forKey: .airWeekday)
        self.rating = try? container.decodeIfPresent(BangumiSubjectRating.self, forKey: .rating)
        self.rank = try? container.decodeIfPresent(Int.self, forKey: .rank)
        self.images = try? container.decodeIfPresent(BangumiSubjectImages.self, forKey: .images)
        self.collection = try? container.decodeIfPresent(BangumiSubjectCollection.self, forKey: .collection)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(type.rawValue, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(nameCN, forKey: .nameCn)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(airDate, forKey: .airDate)
        try container.encodeIfPresent(airWeekday, forKey: .airWeekday)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(rank, forKey: .rank)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(collection, forKey: .collection)
    }

    /// 显示标题（中文名优先）。
    public var displayName: String {
        nameCN.isEmpty ? name : nameCN
    }

    /// 原版日文名（若与中文名不同）。
    public var originalName: String? {
        nameCN.isEmpty || nameCN == name ? nil : name
    }

    /// 封面大图 URL。
    public var coverURL: URL? {
        guard let large = images?.large, !large.isEmpty else { return nil }
        return URL(string: BangumiURL.imageURLString(from: large))
    }

    /// 在看人数。
    public var doingCount: Int {
        collection?.doing ?? 0
    }

    /// 转为精简 DTO，便于导航传递。
    public func toSlimSubject() -> BangumiSlimSubjectDTO {
        var slim = BangumiSlimSubjectDTO()
        slim.id = id
        slim.images = images
        slim.rating = rating
        slim.name = name
        slim.nameCN = nameCN
        slim.type = type
        return slim
    }
}

