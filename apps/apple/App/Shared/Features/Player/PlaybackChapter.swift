import Foundation

/// 一个可跳转的章节(从 Jellyfin ChapterInfo / 未来容器解析而来),App 层 UI 只认这个。
struct PlaybackChapter: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    /// 媒体时间起点(秒)。
    let startSeconds: Double
    /// 终点(秒)。单条 Jellyfin 章节没有 end,由「下一条起点」或片长在解析时补齐;为 nil 表示未知。
    var endSeconds: Double?

    /// 章节条目的展示时长(秒),未知时给 0。
    var durationSeconds: Double {
        guard let endSeconds else { return 0 }
        return max(endSeconds - startSeconds, 0)
    }

    /// 给定播放位置(秒)落在哪个章节。章节按起点排序时返回最后一条「起点 ≤ 位置」的章节;
    /// 位置落在章节间隙(end 到下一节起点之间)返回 nil。
    /// 「当前章节」高亮用它判定——注意传入的 position 必须是可观察的发布值
    /// （如 1Hz 的 `displayPosition`），否则面板打开后高亮永远是死数据。
    static func currentIndex(in chapters: [PlaybackChapter], at position: Double) -> Int? {
        chapters.lastIndex {
            position >= $0.startSeconds && ($0.endSeconds.map { position < $0 } ?? true)
        }
    }
}

/// 可跳过的段落类型。
enum SkipKind: String, Hashable, Sendable {
    /// 片头(OP / opening)。
    case opening
    /// 片尾(ED / credits / 结尾)。
    case credits

    /// 悬浮按钮 / 无障碍标签用。
    var buttonTitle: String {
        switch self {
        case .opening: return "跳过片头"
        case .credits: return "跳过片尾"
        }
    }
}

/// 片头 / 片尾标记的数据来源。合并多路信号时按可信度取舍（`rank`）：
/// 服务端智能识别 > AniSkip（投票背书）> anime-skip > 学习值 > TheIntroDB >
/// 弹幕报点 > 章节启发式猜测。
enum SkipMarkSource: String, Hashable, Sendable {
    /// 服务端智能识别(Jellyfin MediaSegments)。
    case mediaSegment
    /// AniSkip 社区标注区间。
    case aniskip
    /// anime-skip 社区时间戳（设置填 client ID 后启用）。
    case animeSkip
    /// 用户手动跳过行为学习出的值。
    case learned
    /// TheIntroDB 社区时间戳（TMDB 索引）。
    case theIntroDB
    /// 弹幕报点推导(DanmakuIntroDetector)。
    case danmaku
    /// 章节名 / 时间位置启发式。
    case chapterHeuristic

    /// 合并优先级：数值大者胜出。
    var rank: Int {
        switch self {
        case .mediaSegment: 6
        case .aniskip: 5
        case .animeSkip: 4
        case .learned: 3
        case .theIntroDB: 2
        case .danmaku: 1
        case .chapterHeuristic: 0
        }
    }
}

/// 一段可跳过的片头 / 片尾区间,带稳定的身份用于会话内去重。
struct SkipMark: Identifiable, Hashable, Sendable {
    let id: String
    let source: SkipMarkSource
    let kind: SkipKind
    let startSeconds: Double
    let endSeconds: Double

    var label: String { kind.buttonTitle }

    /// 位置是否落在这段内。
    func contains(_ position: Double) -> Bool {
        position >= startSeconds && position < endSeconds
    }
}

/// 当前应该展示的「跳过」提示。
///
/// - `.mark(mark)`:`position` 落在一个已识别的片头 / 片尾区间内。
/// - `.endCredits(position:)`(保底规则):未命中任何片尾区间,但 `position` 已进入
///   片长最后一分三十秒,仍给一个「跳过片尾」跳到接近结尾。关联值就是当前播放位置
///   （不是片长——`performSkip` 拿它和「片长 − 保留秒数」取大值，避免往回跳）。
enum SkipPrompt: Equatable, Sendable {
    case mark(SkipMark)
    case endCredits(position: Double)

    var kind: SkipKind {
        switch self {
        case .mark(let mark): return mark.kind
        case .endCredits: return .credits
        }
    }
}

/// 默认评估器:
/// 1. 章节名命中片头/片尾模式(拉丁整词 + CJK 子串)→ 相邻同类章节合并成组,再过位置/时长门槛;
/// 2. 命名没命中时,用时间位置兜底——片头在前部且短,片尾在尾部且短。
///
/// 片头取最早的合格组,片尾取最晚的合格组:「Opening Credits」这类双关名只会判成片头,
/// 片尾的位置门槛会把它踢掉(片尾反序取最后,Jellyfin intro-skipper 同款)。
///
/// 模式与门槛依据(2026-10 调研):intro-skipper 默认正则
/// `(^|\s)(Intro|Introduction|OP|Opening)(?![\s:]+End)(\s|:|$)`,intro 限前 25%/10 分钟、
/// 15–120s,credits 15–450s(电影 900s);VCB-Studio 章节规范:TV 动画 =
/// OP / Part A / Part B / ED / Preview,且章节名也可能是纯 Chapter xx(零语义)。
struct ChapterNameHeuristicEvaluator {
    /// 片头候选的起始窗口:前 25% 与前 10 分钟取小(intro-skipper 同款)。
    private static let openingLeadingFraction = 0.25
    private static let openingLeadingCapSeconds = 600.0
    /// 片尾候选的起始下限:名字命中看后 30%,位置兜底看后 15%。
    private static let creditsNamedTrailingFraction = 0.7
    private static let creditsFallbackTrailingFraction = 0.85
    /// 片头时长区间(秒):命名命中放宽到 180s 吸收偏长的 Opening Credits;兜底收紧到
    /// 120s——冷开场/前情提要常在 150–200s,不该被跳(宁可漏出按钮,不出错按钮)。
    private static let openingMinDuration = 10.0
    private static let openingNamedMaxDuration = 180.0
    private static let openingFallbackMaxDuration = 120.0
    /// 片尾时长区间(秒);电影片尾可长达 15 分钟。
    private static let creditsMinDuration = 15.0
    private static let creditsMaxDuration = 450.0
    private static let movieCreditsMaxDuration = 900.0
    /// 相邻同类别章节的合并间隙容忍(秒):OP Part A / OP Part B 之间常有取整误差。
    private static let mergeGapTolerance = 1.0

    func skipMarks(chapters: [PlaybackChapter], totalSeconds: Double, isMovie: Bool = false) -> [SkipMark] {
        guard totalSeconds > 0, !chapters.isEmpty else { return [] }

        // 补齐每条章节的结束边界:优先已提供且合法的 end;否则用下一条起点或片长。
        let resolved = chapters.enumerated().map { index, chapter in
            var copy = chapter
            if let ownEnd = copy.endSeconds, ownEnd > copy.startSeconds {
                return copy
            }
            if let nextStart = chapters[safe: index + 1]?.startSeconds, nextStart > chapter.startSeconds {
                copy.endSeconds = nextStart
            } else {
                copy.endSeconds = totalSeconds
            }
            return copy
        }

        let creditsCap = isMovie ? Self.movieCreditsMaxDuration : Self.creditsMaxDuration
        let opening = Self.earliestOpeningGroup(in: resolved, totalSeconds: totalSeconds)
            ?? Self.openingFallback(in: resolved, totalSeconds: totalSeconds)
        let credits = Self.latestCreditsGroup(in: resolved, totalSeconds: totalSeconds, cap: creditsCap)
            ?? Self.creditsFallback(in: resolved, totalSeconds: totalSeconds, cap: creditsCap)

        return [opening, credits].compactMap { $0 }
    }

    // MARK: - 命名候选:收集 + 相邻合并

    /// 同类别名命中的章节,相邻(间隙 ≤ 容忍值)合并成组:
    /// 「OP Part A + OP Part B」合而为一,否则「只跳一半」。
    private static func namedGroups(of kind: SkipKind, in chapters: [PlaybackChapter]) -> [(start: Double, end: Double)] {
        var groups: [(start: Double, end: Double)] = []
        for chapter in chapters where matches(kind: kind, name: chapter.name) {
            let end = chapter.endSeconds ?? chapter.startSeconds
            if let last = groups.last,
               chapter.startSeconds >= last.start,
               chapter.startSeconds - last.end <= mergeGapTolerance {
                groups[groups.count - 1] = (last.start, max(last.end, end))
            } else {
                groups.append((chapter.startSeconds, end))
            }
        }
        return groups
    }

    /// 片头:最早的合格组(起始在前部窗口内、时长像 OP)。
    private static func earliestOpeningGroup(
        in chapters: [PlaybackChapter], totalSeconds: Double
    ) -> SkipMark? {
        let leadingCap = min(totalSeconds * openingLeadingFraction, openingLeadingCapSeconds)
        let group = namedGroups(of: .opening, in: chapters).first {
            $0.start <= leadingCap
                && $0.end - $0.start >= openingMinDuration
                && $0.end - $0.start <= openingNamedMaxDuration
        }
        guard let group else { return nil }
        return makeMark(kind: .opening, start: group.start, end: group.end, totalSeconds: totalSeconds)
    }

    /// 片尾:最晚的合格组(起始在尾部窗口内、时长像 credits)。
    private static func latestCreditsGroup(
        in chapters: [PlaybackChapter], totalSeconds: Double, cap: Double
    ) -> SkipMark? {
        let trailingFloor = totalSeconds * creditsNamedTrailingFraction
        let group = namedGroups(of: .credits, in: chapters).last {
            $0.start >= trailingFloor
                && $0.end - $0.start >= creditsMinDuration
                && $0.end - $0.start <= cap
        }
        guard let group else { return nil }
        return makeMark(kind: .credits, start: group.start, end: group.end, totalSeconds: totalSeconds)
    }

    // MARK: - 位置兜底(该类别零命名命中时)

    private static func openingFallback(
        in chapters: [PlaybackChapter], totalSeconds: Double
    ) -> SkipMark? {
        let leadingCap = min(totalSeconds * openingLeadingFraction, openingLeadingCapSeconds)
        guard let first = chapters.first,
              first.startSeconds <= leadingCap,
              first.durationSeconds >= openingMinDuration,
              first.durationSeconds <= openingFallbackMaxDuration,
              let end = first.endSeconds else { return nil }
        return makeMark(kind: .opening, start: first.startSeconds, end: end, totalSeconds: totalSeconds)
    }

    private static func creditsFallback(
        in chapters: [PlaybackChapter], totalSeconds: Double, cap: Double
    ) -> SkipMark? {
        let trailingFloor = totalSeconds * creditsFallbackTrailingFraction
        guard let last = chapters.last(where: {
            $0.startSeconds >= trailingFloor
                && $0.durationSeconds >= creditsMinDuration
                && $0.durationSeconds <= cap
        }), let end = last.endSeconds else { return nil }
        return makeMark(kind: .credits, start: last.startSeconds, end: end, totalSeconds: totalSeconds)
    }

    private static func makeMark(kind: SkipKind, start: Double, end: Double, totalSeconds: Double) -> SkipMark? {
        let clampedEnd = min(end, totalSeconds)
        guard clampedEnd - start > 0.5 else { return nil }
        return SkipMark(
            id: "\(kind.rawValue)-\(Int(start))",
            source: .chapterHeuristic,
            kind: kind,
            startSeconds: start,
            endSeconds: clampedEnd
        )
    }

    // MARK: - 章节名分类

    /// 拉丁整词:容忍编号后缀(OP1 / ED2)与无字版命名(NCOP / NCED);
    /// 不收裸词 open——「Cold Open」是欧美剧的冷开场剧情,不是片头。
    private static let openingLatinKeywords = ["op", "opening", "intro", "introduction", "ncop"]
    private static let creditsLatinKeywords = ["ed", "ending", "credit", "credits", "outro", "nced"]
    /// 多词短语无词边界歧义,按子串命中(欧美剧集章节命名)。
    private static let openingPhrases = ["main title", "title sequence"]
    private static let creditsPhrases = ["closing credits"]
    /// CJK 关键词没有词边界概念,维持子串匹配——「片头曲」就该命中「片头」。
    private static let openingCJKKeywords = ["片头", "片頭", "主题曲", "主題曲", "オープニング"]
    private static let creditsCJKKeywords = ["片尾", "结尾", "結尾", "尾声", "尾聲", "エンディング"]

    private static func matches(kind: SkipKind, name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let latinKeywords: [String]
        let phrases: [String]
        let cjkKeywords: [String]
        switch kind {
        case .opening:
            (latinKeywords, phrases, cjkKeywords) = (openingLatinKeywords, openingPhrases, openingCJKKeywords)
        case .credits:
            (latinKeywords, phrases, cjkKeywords) = (creditsLatinKeywords, creditsPhrases, creditsCJKKeywords)
        }

        for (index, token) in tokens.enumerated()
        where latinKeywords.contains(where: { tokenMatchesKeyword(token, keyword: $0) }) {
            // 「…End」是结束点标记(intro-skipper 同款哨兵):「Intro End」从结束处才开始,
            // 不能当片头本体;「Intro Start」正常命中,配对时区间恰为 [start, end)。
            if tokens[(index + 1)...].first == "end" { continue }
            return true
        }
        return phrases.contains(where: normalized.contains)
            || cjkKeywords.contains(where: normalized.contains)
    }

    /// 整词相等,或「关键词 + 纯数字编号」(OP1 / ED2)。
    private static func tokenMatchesKeyword(_ token: String, keyword: String) -> Bool {
        if token == keyword { return true }
        return token.hasPrefix(keyword)
            && token.count > keyword.count
            && token.dropFirst(keyword.count).allSatisfy { $0.isNumber }
    }
}

// MARK: - 无障碍 Array 访问

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 章节会话(播放期间的章节 + 跳过状态)

/// 一次播放会话内的章节数据与跳过判定。
///
/// 持有:
/// - `chapters`:来源章节(Jellyfin 章节列表,无则空)。
/// - `skipMarks`:识别出的可跳过片头 / 片尾(MediaSegments 优先,回退章节启发式)。
/// - `skippedIDs`:`已跳过` 的集合(会话内去重,避免回拖又弹)。
///
/// 这是纯逻辑,便于单测。
struct ChapterSession {
    var chapters: [PlaybackChapter] = []
    var skipMarks: [SkipMark] = []
    /// 已跳过的标记 id(会话内去重)。
    private(set) var skippedIDs: Set<String> = []
    /// 保底片尾是否已跳过(会话内只兜一次)。不记的话跳到「片尾前保留秒数处」仍在
    /// 90s 窗口内，提示立刻重现、按钮原地循环。
    private(set) var didSkipEndCredits = false

    mutating func reset() {
        chapters = []
        skipMarks = []
        skippedIDs = []
        didSkipEndCredits = false
    }

    /// 当前应展示的「跳过」提示。
    ///
    /// 优先级:
    /// 1. `position` 落在某段 `SkipMark` 内(且未跳过) → `.mark`;
    /// 2. 否则,`duration - position <= 90s` 且未自然结束 → `.endCredits` 保底。
    func prompt(
        at position: Double,
        duration: Double,
        isPlaying: Bool,
        preventCreditsSkip: Bool = false
    ) -> SkipPrompt? {
        guard isPlaying else { return nil }
        guard duration > 0 else { return nil }

        // 1. 命中已识别的片头 / 片尾。
        for mark in skipMarks where !skippedIDs.contains(mark.id) {
            if mark.contains(position) {
                return .mark(mark)
            }
        }

        // 2. 保底:最后一分三十秒,给「跳过片尾」。会话内只兜一次。
        if !preventCreditsSkip,
           !didSkipEndCredits,
           duration - position <= 90,
           duration - position > 1 {
            return .endCredits(position: position)
        }
        return nil
    }

    /// 记录一次跳过(会话内去重)。`mark` 的 id 被标记后,后续不再弹。
    mutating func noteSkipped(_ mark: SkipMark) {
        skippedIDs.insert(mark.id)
    }

    /// 记录一次保底片尾跳过,后续不再重复弹「跳过片尾」。
    mutating func noteEndCreditsSkipped() {
        didSkipEndCredits = true
    }

    /// 注入跳过片头提示（DanmakuKit 的 DanmakuIntroHint → SkipMark）。
    ///
    /// 多路信号按 `SkipMarkSource.rank` 取舍：已有同高或更高优先级的片头标记时让位，
    /// 低优先级的被替换（服务端识别最准；AniSkip 有社区背书，压过自动推导的弹幕
    /// 与章节猜测）。`startSeconds` 为 nil 时从 0 起（无把握不猜冷开场）。
    /// 返回是否注入。
    @discardableResult
    mutating func applySkipTimesHint(
        startSeconds: Double?,
        endSeconds: Double,
        source: SkipMarkSource
    ) -> Bool {
        guard endSeconds > 1 else { return false }
        // 严格更高优先级才让位；同级别刷新走原位替换（重匹配后用新数据覆盖旧提示）。
        if let existing = skipMarks.first(where: { $0.kind == .opening }),
           existing.source.rank > source.rank {
            return false
        }
        skipMarks.removeAll { $0.kind == .opening }
        let start = max(0, startSeconds ?? 0)
        guard start < endSeconds - 1 else { return false }
        let mark = SkipMark(
            id: "skiptimes-opening",
            source: source,
            kind: .opening,
            startSeconds: start,
            endSeconds: endSeconds
        )
        if let index = skipMarks.firstIndex(where: { $0.id == mark.id }) {
            skipMarks[index] = mark
        } else {
            skipMarks.append(mark)
        }
        return true
    }
}