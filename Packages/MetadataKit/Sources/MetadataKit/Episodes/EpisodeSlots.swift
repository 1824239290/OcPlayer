import CoreModel
import Foundation

// MARK: - 来源中立的候选

/// 一个「来源说这一季有第 N 集」的事实。
///
/// ## 为什么要这一层中立类型
///
/// 占位数据的来源有两个：TMDb 的季叠加层（`TMDbOverlay.episodes`）与 Bangumi 的章节
/// 列表（`BangumiEpisodeDTO`）。两者字段名、字段有无都不一样（Bangumi 没有剧照、
/// 时长是字符串），而「哪一格该不该出现占位、算空洞还是算未播出」这套判断是**纯策略**，
/// 只该写一遍、只该测一遍。
///
/// 所以两个来源各自映射成这个结构体再进 `EpisodeSlotBuilder`：`MetadataKit` 因此
/// **不需要依赖 BangumiKit**（依赖方向不变），策略本身也能脱离 App 单独测。
public struct EpisodeCandidate: Sendable, Hashable {
    /// 集号（与 Jellyfin 的 `IndexNumber` 同口径）。≤ 0 一律被 `EpisodeSlotBuilder` 丢弃。
    public var number: Int
    public var title: String?
    public var overview: String?
    /// TMDb 的 `still_path`（`/xxx.jpg`）。Bangumi 侧恒 nil。
    public var stillPath: String?
    /// 播出日期。**nil = 未知，不是「未播出」**——这两件事在占位卡上是两种状态。
    public var airDate: Date?
    public var runtimeSeconds: Double?

    public init(
        number: Int,
        title: String? = nil,
        overview: String? = nil,
        stillPath: String? = nil,
        airDate: Date? = nil,
        runtimeSeconds: Double? = nil
    ) {
        self.number = number
        self.title = title
        self.overview = overview
        self.stillPath = stillPath
        self.airDate = airDate
        self.runtimeSeconds = runtimeSeconds
    }
}

// MARK: - 占位

/// 这一格为什么是占位。决定卡片上的状态文案。
public enum EpisodePlaceholderReason: Sendable, Hashable {
    /// 来源说这一集还没播出（有播出日期且晚于现在）。
    case notAired
    /// 已播出（或播出日期未知）但库里没有。
    case notInLibrary
}

/// 库里没有、但来源说这一季有的一集。
public struct EpisodePlaceholder: Sendable, Hashable {
    public var number: Int
    /// 季号。恒非 nil——季号缺失 / 为 0（特典）时 `EpisodeSlotBuilder` 直接不补占位。
    public var seasonNumber: Int
    public var title: String?
    public var overview: String?
    public var stillPath: String?
    public var airDate: Date?
    public var runtimeSeconds: Double?
    public var reason: EpisodePlaceholderReason

    public init(
        number: Int,
        seasonNumber: Int,
        title: String? = nil,
        overview: String? = nil,
        stillPath: String? = nil,
        airDate: Date? = nil,
        runtimeSeconds: Double? = nil,
        reason: EpisodePlaceholderReason
    ) {
        self.number = number
        self.seasonNumber = seasonNumber
        self.title = title
        self.overview = overview
        self.stillPath = stillPath
        self.airDate = airDate
        self.runtimeSeconds = runtimeSeconds
        self.reason = reason
    }

    /// 展示标题。来源没有标题时回落到「第 N 集」（与 `TMDbOverlay` 认定的服务端占位名同形）。
    ///
    /// 判定用「非空白」而不是「非空」：来源那边空白串等于没给（`TMDbPreferences` 的
    /// 语言回退也踩过同一类坑——空串是「这门语言没有这个字段」的表现）。
    public var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "第 \(number) 集" : trimmed
    }

    /// 「S3E26」这样的集标，与本地分集卡同形（`MediaItem.episodeLabel`）。
    public var episodeLabel: String { "S\(seasonNumber)E\(number)" }
}

// MARK: - 一格

/// 选集轨道里的一格：库里有 → 本地条目；库里没有 → 占位。
///
/// **刻意不做成「合成的 `MediaItem`」**：那种条目会顺着 `episodes` 流进播放、已看标记、
/// 连播、详情快照与磁盘缓存，每一处都得再加一道「这是假的」判断；漏一处就是「点占位
/// 开播失败」或者「占位被写进缓存」。联合类型让「不可播」在类型上就成立。
public enum EpisodeSlot: Sendable, Hashable, Identifiable {
    case local(MediaItem)
    case placeholder(EpisodePlaceholder)

    public var id: String {
        switch self {
        case .local(let item):
            item.id
        case .placeholder(let placeholder):
            // 前缀刻意不是 GUID 形态：Jellyfin 的条目 id 是 32 位十六进制，撞不上。
            "placeholder.s\(placeholder.seasonNumber).e\(placeholder.number)"
        }
    }

    /// 本地条目（占位为 nil）。
    public var episode: MediaItem? {
        if case .local(let item) = self { return item }
        return nil
    }

    /// 占位（本地为 nil）。
    public var placeholder: EpisodePlaceholder? {
        if case .placeholder(let placeholder) = self { return placeholder }
        return nil
    }
}

// MARK: - 策略

/// 把「本地条目 + 来源候选」合成一条选集轨道。**纯函数**：不碰网络、不碰数据库。
public enum EpisodeSlotBuilder {

    /// 库尾往前看多少集（下界另有规则，见 `build` 里的窗口说明）。
    ///
    /// 这是「库内空洞 + 未来一批」与「长番几百集占位」之间的分界：不设它的话，一部
    /// 库里只有 500 集的海贼王（来源 1100 集）会一次冒出 600 张占位卡。24 约等于一个
    /// 标准季的长度，够覆盖「当季还没播完」与「刚缺了一批」两种真实场景。
    public static let forwardWindow = 24

    /// 占位卡总数上限。**安全网**：上面那条窗口已经能挡住长番，这里再兜一次脏数据
    /// （来源给出几百个「未来」集号时不会把轨道刷爆）。
    public static let maxPlaceholders = 60

    /// 合成选集轨道。
    ///
    /// - Parameters:
    ///   - seasonNumber: 当前选中的季号。nil 或 0（特典）时**不补占位**：TMDb 的
    ///     season 0 编号与 Jellyfin 从文件名派生的 SP 编号本来就对不上，硬补只会造出
    ///     一批错号的假卡片。
    ///   - local: 库内条目（服务端返回的当前季分集，顺序不限）。
    ///   - primary: 首选来源（TMDb 季叠加层）。
    ///   - fallback: 兜底来源（Bangumi 章节）。
    ///   - now: 「未播出」的判定基准（注入是为了能测）。
    public static func build(
        seasonNumber: Int?,
        local: [MediaItem],
        primary: [EpisodeCandidate],
        fallback: [EpisodeCandidate],
        now: Date
    ) -> [EpisodeSlot] {
        // 集号 → 本地条目。同号只留第一个：服务端理论上不该重复，真重复了也别因此
        // 让同一格出现两次（宁可少显示一张，也不要轨道里两张同号卡）。
        var localByNumber: [Int: MediaItem] = [:]
        var unnumbered: [MediaItem] = []
        for item in local {
            if let number = item.episodeNumber {
                if localByNumber[number] == nil { localByNumber[number] = item }
            } else {
                unnumbered.append(item)
            }
        }
        let localNumbers = Set(localByNumber.keys)

        guard let seasonNumber, seasonNumber != 0,
              let source = pickSource(primary: primary, fallback: fallback,
                                      local: local, localNumbers: localNumbers)
        else {
            return local.map(EpisodeSlot.local)
        }

        // 窗口下界：库内**最小**集号（库内为空时按 0 起算）。比它更小的集号不补——
        // 那是「没有开头」（用户刻意从中间开始收，或另一套编号的前半段），不是空洞。
        // 不设这条的话，一部只有第 1000 集的库会把 1…999 全算成空洞，占位上限一截，
        // 真正有用的「库尾那 24 集」反而被挤掉。
        let windowMin = localNumbers.min() ?? 0
        // 窗口上界：库内最大集号 + forwardWindow。库内没有集号时按 0 起算，于是
        // 「有季但一集都没有」的条目会补出该季前 forwardWindow 集。
        let windowMax = (localNumbers.max() ?? 0) + forwardWindow

        var candidates: [Int: EpisodeCandidate] = [:]
        for candidate in source where candidate.number > windowMin
            && candidate.number <= windowMax
            && !localNumbers.contains(candidate.number) {
            if candidates[candidate.number] == nil { candidates[candidate.number] = candidate }
        }
        var kept = candidates.keys.sorted()
        if kept.count > maxPlaceholders {
            kept = Array(kept.prefix(maxPlaceholders))
        }
        let keptNumbers = Set(kept)

        var slots: [EpisodeSlot] = []
        for number in localNumbers.union(keptNumbers).sorted() {
            if let item = localByNumber[number] {
                slots.append(.local(item))
            } else if let candidate = candidates[number], keptNumbers.contains(number) {
                slots.append(.placeholder(placeholder(from: candidate, seasonNumber: seasonNumber, now: now)))
            }
        }
        // 没有集号的本地条目接在最后：与服务端那份「集号 nil 排最后」的顺序一致。
        slots.append(contentsOf: unnumbered.map(EpisodeSlot.local))
        return slots
    }

    /// 选出可信的来源。
    ///
    /// **编号可信**是这里唯一的判断：库内已有集号时，来源必须与它**至少有一集同号**。
    /// 实测两种编号口径都存在——Jellyfin 的分集 `IndexNumber` 有时是季内相对号、有时是
    /// 绝对号，而 TMDb / Bangumi 各自也只认自己那一套。没有交集说明两边的编号根本不同源，
    /// 此时**宁可不显示占位，也不显示错号的假卡片**（错号的占位比没有占位更坏：用户会
    /// 按它去找片）。
    ///
    /// 库内为空时没有可对照的事实，直接用来源；库内有条目但**一个集号都没有**时无从判断，
    /// 视为不可信。
    private static func pickSource(
        primary: [EpisodeCandidate],
        fallback: [EpisodeCandidate],
        local: [MediaItem],
        localNumbers: Set<Int>
    ) -> [EpisodeCandidate]? {
        for source in [primary, fallback] {
            let numbers = Set(source.map(\.number).filter { $0 >= 1 })
            guard !numbers.isEmpty else { continue }
            if localNumbers.isEmpty {
                if local.isEmpty { return source }
                continue
            }
            if !numbers.isDisjoint(with: localNumbers) { return source }
        }
        return nil
    }

    private static func placeholder(
        from candidate: EpisodeCandidate,
        seasonNumber: Int,
        now: Date
    ) -> EpisodePlaceholder {
        // 「未播出」必须**有播出日期且晚于现在**。日期未知不等于未播出：那可能是十年前
        // 的一集只是没刮到日期，标成「未播出」会让用户白等。
        let isFuture = candidate.airDate.map { $0 > now } ?? false
        return EpisodePlaceholder(
            number: candidate.number,
            seasonNumber: seasonNumber,
            title: candidate.title,
            overview: candidate.overview,
            stillPath: candidate.stillPath,
            airDate: candidate.airDate,
            runtimeSeconds: candidate.runtimeSeconds,
            reason: isFuture ? .notAired : .notInLibrary)
    }
}

// MARK: - TMDb 季叠加层 → 候选

extension TMDbOverlay {

    /// 这一季的占位候选。
    ///
    /// 只有**季叠加层**才有 `episodes`（剧集级 / 电影的叠加层恒为空数组），所以非季
    /// 叠加层自然返回 `[]`，调用方不需要再判类型。
    public var episodeCandidates: [EpisodeCandidate] {
        episodes.map { entry in
            EpisodeCandidate(
                number: entry.episodeNumber,
                title: entry.name,
                overview: entry.overview,
                stillPath: entry.stillPath,
                airDate: TMDbAirDate.parse(entry.airDate),
                runtimeSeconds: entry.runtime.map { Double($0) * 60 })
        }
    }
}

/// TMDb 的 `air_date` 是 `yyyy-MM-dd`。
///
/// 与 `BangumiEpisodeDTO.airDateValue` **必须同口径**（都是本地时区的当日零点）：
/// 两边算出来的日期若差一天，同一集会在两个来源下被判成不同的播出状态。
/// 解析不出来一律 nil（= 日期未知），**不拿本地时钟顶替**。
enum TMDbAirDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }
}
