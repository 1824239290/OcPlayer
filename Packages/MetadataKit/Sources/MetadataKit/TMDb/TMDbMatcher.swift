import CoreModel
import Foundation

/// 一次匹配的结果。
public struct TMDbMatch: Sendable, Equatable {
    public var entityKey: TMDbEntityKey
    public var source: TMDbLinkSource
    /// 0…1。`providerID` 恒为 1.0（服务端给的 id 是权威）。
    public var confidence: Double
    /// 命中的标题（诊断/手动面板展示用）。
    public var matchedTitle: String?
    /// 落选但够接近的候选，供「手动匹配」面板直接列出（Phase 3）。
    public var alternatives: [TMDbSearchResult]

    public init(entityKey: TMDbEntityKey, source: TMDbLinkSource, confidence: Double,
                matchedTitle: String? = nil, alternatives: [TMDbSearchResult] = []) {
        self.entityKey = entityKey
        self.source = source
        self.confidence = confidence
        self.matchedTitle = matchedTitle
        self.alternatives = alternatives
    }

    /// 是否**足够可信到可以自动落库**。
    ///
    /// 阈值而不是「有结果就用」：错误的匹配比没有匹配更糟——用户看到的是**别人的
    /// 剧情简介和海报**，而且会显示得像真的一样。宁可让他手动选（Phase 3）。
    public var shouldApplyAutomatically: Bool {
        confidence >= TMDbMatcher.autoApplyThreshold
    }
}

/// 匹配器：把服务端条目对应到 TMDb 实体。
///
/// ## 优先级
///
/// 1. **`ProviderIds["Tmdb"]`**（权威）：服务端自己就有 TMDb id，直接用，置信度 1.0。
/// 2. **标题搜索 + 年份**（兜底）：没有 id 的条目（用户自建库、老刮削器）靠此匹配。
///
/// ## 一个必须守住的边界：集与季的 `tmdbID` 不是剧集 id
///
/// 实测（本机 Jellyfin 12.1.0）：
/// ```
/// 剧   二十世纪电气目录  ProviderIds["Tmdb"] = 153217     ← 剧集 id
/// 季   第 1 季         ProviderIds 只有 Tvdb（无 Tmdb）  ← 没有 id 可用
/// 集   S1E1            ProviderIds["Tmdb"] = 3384539     ← 单集 id
/// ```
/// 所以**集与季绝不能拿自己的 `tmdbID` 去查 `/tv/{id}`**——那是单集 id，
/// 会拉到另一部剧或 404。它们一律从**父剧**的对应关系推导：`tv/{剧id}/season/{季号}`。
///
/// 这个判断收在 `entityKey(for:)` 里，是匹配器唯一的入口，避免调用点各写一遍。
public struct TMDbMatcher: Sendable {

    /// 自动落库的置信度门槛。0.85 = 「标题精确匹配 + 年份相符」这一档。
    ///
    /// 定在 0.85 而不是更低：0.7 那一档（标题对但年份差 1）在中文剧名上很危险
    /// （重名、翻拍、特别篇），误配的代价是展示别人的简介。
    public static let autoApplyThreshold = 0.85

    private let search: @Sendable (String, TMDbMediaType, Int?, String) async throws -> [TMDbSearchResult]
    private let language: String

    /// - Parameter search: 搜索入口（生产传 `TMDbClient.search`；测试传固定结果）。
    ///   用闭包而不是直接持有 client：匹配逻辑是纯函数式的打分，不该被网络依赖绑住。
    public init(
        language: String,
        search: @escaping @Sendable (String, TMDbMediaType, Int?, String) async throws -> [TMDbSearchResult]
    ) {
        self.language = language
        self.search = search
    }

    // MARK: - 入口

    /// 为一个条目决定它的 TMDb 实体键。
    ///
    /// - Parameters:
    ///   - item: 服务端条目。
    ///   - seriesLink: **父剧**已建立的对应（集/季从它推导；电影/剧传 nil）。
    ///   - allowSearch: 是否允许走搜索兜底（批量补全时可按开关关掉）。
    public func match(
        item: MediaItem,
        seriesLink: TMDbLink? = nil,
        allowSearch: Bool = true
    ) async -> TMDbMatch? {
        // ① 集 / 季：只用父剧推导，**不看自己的 tmdbID**（见类型注释）。
        switch item.kind {
        case .season, .episode:
            guard let seriesLink,
                  case .tv(let tvID) = seriesLink.entityKey,
                  let seasonNumber = item.seasonNumber
            else { return nil }
            return TMDbMatch(
                entityKey: .season(tvID: tvID, number: seasonNumber),
                source: seriesLink.source,
                confidence: seriesLink.confidence,
                matchedTitle: item.seriesName)
        case .movie, .series:
            break
        default:
            return nil
        }

        // ② 电影 / 剧：先用 ProviderIds。
        if let id = providerTmdbID(of: item) {
            let key: TMDbEntityKey = item.kind == .movie ? .movie(id) : .tv(id)
            return TMDbMatch(entityKey: key, source: .providerID, confidence: 1.0,
                             matchedTitle: item.name)
        }

        guard allowSearch else { return nil }
        return await matchBySearch(item: item)
    }

    /// `ProviderIds["Tmdb"]` → Int。脏数据（空串 / 非数字 / ≤0）一律当没有。
    ///
    /// 服务端的刮削器偶尔会写进 `""` 或 `"0"`，直接用会拿 0 去查 TMDb 并得到 404，
    /// 日志里表现为「明明有 id 却查不到」，很难查。
    func providerTmdbID(of item: MediaItem) -> Int? {
        guard let raw = item.tmdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let id = Int(raw), id > 0
        else { return nil }
        return id
    }

    // MARK: - 搜索匹配

    func matchBySearch(item: MediaItem) async -> TMDbMatch? {
        let mediaType: TMDbMediaType = item.kind == .movie ? .movie : .tv
        // 年份：优先用服务端字段；服务端没给时从标题里认（「某片 (2019)」）。
        //
        // 为什么值得兜这一层：TMDb 的搜索支持按年份过滤，而**没有年份时同名作品的
        // 候选会混在一起**（重名、翻拍、特别篇），打分只能靠标题精确度硬扛。
        // 服务端把年份写进标题而不写进字段是常见现象（实测库里就有这种条目）。
        let year = item.year ?? TitleNormalizer.year(fromTitle: item.name)

        var candidates = (try? await search(item.name, mediaType, year, language)) ?? []

        // 主语言的标题查不到时，用**原始标题**再试一次。
        //
        // 为什么需要：TMDb 的搜索是按它自己索引的标题匹配的，中文译名不一定在索引里
        // （尤其冷门番剧）。`originalTitle` 常是日文/英文原名，命中率高得多。
        // 只在第一次**没选出可自动应用的候选**时才多打这一趟，多数条目不会走到。
        if !candidates.contains(where: { score($0, item: item) >= Self.autoApplyThreshold }),
           let original = item.originalTitle,
           !original.isEmpty,
           original != item.name {
            candidates += (try? await search(original, mediaType, year, language)) ?? []
        }

        guard !candidates.isEmpty else { return nil }

        let ranked = candidates
            .map { (result: $0, confidence: score($0, item: item)) }
            .sorted { $0.confidence > $1.confidence }

        guard let best = ranked.first else { return nil }
        return TMDbMatch(
            entityKey: best.result.mediaType == .movie ? .movie(best.result.id) : .tv(best.result.id),
            source: .search,
            confidence: best.confidence,
            matchedTitle: best.result.title,
            alternatives: ranked.dropFirst().prefix(5).map(\.result))
    }

    /// 给一个候选打分（0…1）。
    ///
    /// 分档（每一档都对应一个真实场景，不是拍脑袋的连续函数）：
    /// - 标题精确 + 年份相符 → **0.95** 自动应用
    /// - 标题精确 + 双方都有年份但差 ≤1（跨年首播 / 年份写错）→ 0.8（**不自动**）
    /// - 标题精确 + 至少一方没年份 → 0.7（不自动；缺年份时无法排除重名）
    /// - 标题宽松命中（去标点后包含）+ 年份相符 → 0.6（不自动）
    /// - 其余 → 0.1
    func score(_ result: TMDbSearchResult, item: MediaItem) -> Double {
        let target = TitleNormalizer.normalize(item.name)
        let candidate = TitleNormalizer.normalize(result.title)
        let candidateOriginal = TitleNormalizer.normalize(result.originalTitle)
        let targetOriginal = TitleNormalizer.normalize(item.originalTitle)

        // 标题是否精确相符（正标题或原名任一命中都算——用户库里存的可能是原名）
        let exact = !target.isEmpty && (candidate == target
            || candidateOriginal == target
            || (!targetOriginal.isEmpty && (targetOriginal == candidate || targetOriginal == candidateOriginal)))
        let loose = !target.isEmpty && !exact
            && ((!candidate.isEmpty && (candidate.contains(target) || target.contains(candidate)))
                || (!candidateOriginal.isEmpty && candidateOriginal.contains(target)))

        guard exact || loose else { return 0.1 }

        switch (exact, YearRelation(itemYear: item.year, resultYear: result.year)) {
        case (true, .same): return 0.95
        case (true, .offByOne): return 0.8     // 跨年首播 / 年份录错一位
        case (true, .unknown): return 0.7      // 缺年份，无法排除重名
        case (true, .different): return 0.4    // 多半是翻拍/重名，压到很低
        case (false, .same): return 0.6        // 标题只是宽松命中，即使年份对上也不高
        case (false, .offByOne): return 0.5
        case (false, .unknown): return 0.3
        case (false, .different): return 0.1
        }
    }
}

/// 候选年份与条目年份的关系。
///
/// **「差一年」与「不知道」必须分开**：两者都不足以自动应用（都低于阈值），
/// 但当一个候选差一年、另一个完全没有年份时，前者是强得多的证据。
/// 早先用 `Bool?` 把两者一起塞进 `nil`，排序就退化成了「谁在搜索结果里更靠前」。
enum YearRelation {
    /// 同年。
    case same
    /// 差不超过 1 年（跨年首播 / 年份录错）。
    case offByOne
    /// 至少一方没有年份，无法判定。
    case unknown
    /// 明显不符。
    case different

    init(itemYear: Int?, resultYear: Int?) {
        guard let itemYear, let resultYear else {
            self = .unknown
            return
        }
        if itemYear == resultYear {
            self = .same
        } else if abs(itemYear - resultYear) <= 1 {
            self = .offByOne
        } else {
            self = .different
        }
    }
}

/// 标题归一化：做匹配前的比较用。
///
/// 只做「两边同样处理」的变换，不做任何一侧特有的加工（否则会出现单向偏差）：
/// 小写、去标点与空白、全角转半角、去掉常见季数/年份后缀。
///
/// **不做的**：不去罗马数字、不做拼音、不做翻译。那些需要词表，收益不确定而风险
/// 很高——把「阿松」和「阿松 2」归一成同一个是本类最该避免的错误，所以季数只在
/// **明确形如「第 N 季」「Season N」「II」结尾**时才剥掉，且保留数字差异的情况。
enum TitleNormalizer {

    /// 归一化（用于相等比较）。
    static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        var text = raw.lowercased()
        // 全角 → 半角（中文字符不受影响；数字与拉丁字母会）
        text = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        // 去掉标点、空白、以及各种连接符（「：」「·」「-」「_」「!」「?」…）
        text = text.unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.contains($0)
                   && !CharacterSet.whitespacesAndNewlines.contains($0)
                   && !CharacterSet.symbols.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        // 去掉结尾的季数标记（「第2季」「season2」「2ndseason」）
        for pattern in [#"第\d+季$"#, #"season\d+$"#, #"\d+ndseason$"#, #"\d+rdseason$"#, #"\d+thseason$"#] {
            if let range = text.range(of: pattern, options: .regularExpression) {
                text.removeSubrange(range)
            }
        }
        return text
    }

    /// 从标题里猜年份（`"某片 (2019)"` → 2019）。服务端没给 `year` 时的兜底。
    static func year(fromTitle raw: String?) -> Int? {
        guard let raw else { return nil }
        guard let range = raw.range(of: #"[（(](\d{4})[)）]"#, options: .regularExpression) else { return nil }
        let digits = raw[range].filter(\.isNumber)
        guard digits.count == 4, let value = Int(digits), (1900...2100).contains(value) else { return nil }
        return value
    }
}
