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

/// 一段可跳过的片头 / 片尾区间,带稳定的身份用于会话内去重。
struct SkipMark: Identifiable, Hashable, Sendable {
    let id: String
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
/// - `.endCredits(duration:)`(保底规则):未命中任何片尾区间,但 `position` 已进入
///   片长最后一分三十秒,仍给一个「跳过片尾」跳到接近结尾。
enum SkipPrompt: Equatable, Sendable {
    case mark(SkipMark)
    case endCredits(duration: Double)

    var kind: SkipKind {
        switch self {
        case .mark(let mark): return mark.kind
        case .endCredits: return .credits
        }
    }
}

/// 从章节列表里识别「片头 / 片尾」的可跳过段落。
///
/// 设计成协议,是给未来接真正的 `/MediaSegments` 识别器留的口子:
/// 现在只有名字 + 时间位置的启发式识别;将来换 / 叠加一个新的实现即可,UI 不感知。
protocol ChapterSkippingEvaluator {
    /// 给定章节与片长,产出可跳过的片头 / 片尾段落(不一定命中,可能为空)。
    func skipMarks(chapters: [PlaybackChapter], totalSeconds: Double) -> [SkipMark]
}

/// 默认评估器:
/// 1. 章节名命中关键词(OP / 片头 / Opening;ED / 片尾 / Ending / Credits)直接判定;
/// 2. 命名没命中时,用时间位置兜底——片头在前部且短,片尾在尾部且短。
///
/// 每类只保留命中最早的一条,避免同一视频出多个「跳过片头」按钮。
struct ChapterNameHeuristicEvaluator: ChapterSkippingEvaluator {
    /// 「前部可作片头」的窗口上限(片长的比例)。
    private static let openingLeadingFraction = 0.12
    /// 「尾部可作片尾」的窗口起点(片长的比例)。
    private static let creditsTrailingFraction = 0.85
    /// 片头单段时长上限(秒):再长多半是正片分章,不该当 OP 跳。
    private static let openingMaxDuration: Double = 240
    /// 片尾单段时长上限(秒)。
    private static let creditsMaxDuration: Double = 300

    func skipMarks(chapters: [PlaybackChapter], totalSeconds: Double) -> [SkipMark] {
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

        var opening: SkipMark?
        var credits: SkipMark?

        for chapter in resolved.enumerated().map(\.element) {
            if opening == nil, isOpeningName(chapter.name) {
                opening = makeMark(kind: .opening, chapter: chapter, totalSeconds: totalSeconds)
            }
            if credits == nil, isCreditsName(chapter.name) {
                credits = makeMark(kind: .credits, chapter: chapter, totalSeconds: totalSeconds)
            }
        }

        // 命名没命中时走位置兜底。
        if opening == nil,
           let first = resolved.first,
           first.startSeconds <= totalSeconds * Self.openingLeadingFraction,
           first.durationSeconds > 0,
           first.durationSeconds <= Self.openingMaxDuration {
            opening = makeMark(kind: .opening, chapter: first, totalSeconds: totalSeconds)
        }
        if credits == nil,
           let last = resolved.last(where: {
               $0.startSeconds >= totalSeconds * Self.creditsTrailingFraction && $0.durationSeconds <= Self.creditsMaxDuration
           }) {
            credits = makeMark(kind: .credits, chapter: last, totalSeconds: totalSeconds)
        }

        return [opening, credits].compactMap { $0 }
    }

    private func makeMark(kind: SkipKind, chapter: PlaybackChapter, totalSeconds: Double) -> SkipMark? {
        let end = min(chapter.endSeconds ?? totalSeconds, totalSeconds)
        guard end - chapter.startSeconds > 0.5 else { return nil }
        return SkipMark(
            id: "\(kind.rawValue)-\(Int(chapter.startSeconds))",
            kind: kind,
            startSeconds: chapter.startSeconds,
            endSeconds: end
        )
    }

    private func isOpeningName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let keywords = ["op", "open", "opening", "片头", "主题曲", "オープニング", "オープニング曲"]
        return normalizedMatches(normalized, containsAny: keywords)
    }

    private func isCreditsName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let keywords = ["ed", "ending", "end credits", "credits", "片尾", "结尾", "尾声",
                        "エンディング", "エンディング曲", "ending credits"]
        return normalizedMatches(normalized, containsAny: keywords)
    }

    private func normalizedMatches(_ name: String, containsAny keywords: [String]) -> Bool {
        keywords.contains { keyword in
            name == keyword
                || name.hasPrefix(keyword + " ")
                || name.hasPrefix(keyword + "-")
                || name.hasSuffix(" " + keyword)
                || name.contains(keyword)
        }
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

    mutating func reset() {
        chapters = []
        skipMarks = []
        skippedIDs = []
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

        // 2. 保底:最后一分三十秒,给「跳过片尾」。
        if !preventCreditsSkip,
           duration - position <= 90,
           duration - position > 1 {
            return .endCredits(duration: position)
        }
        return nil
    }

    /// 记录一次跳过(会话内去重)。`mark` 的 id 被标记后,后续不再弹。
    mutating func noteSkipped(_ mark: SkipMark) {
        skippedIDs.insert(mark.id)
    }
}