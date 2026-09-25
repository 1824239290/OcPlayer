import Foundation

/// 弹弹play 剧集编号的两种形态。
///
/// 正片是「第 N 话」；特典 / OP-ED / 其他附属集在弹弹play 库里与正片同属一个作品，
/// 但用字母命名空间编号：`S<n>`（特典、圣地巡礼等）、`C<n>`（Opening / Ending 等）、
/// `O<n>`（发布会、警告等其他）。官方 `search/episodes` 的 `episode` 参数正好接受
/// 这个字面形态（`C1`/`S1`/`O1`），所以搜索时直接发 token 的 `searchValue`。
public enum DanmakuSpecialKind: String, Sendable, CaseIterable, Equatable {
    /// `S<n>`：特典 / 特别篇 / 圣地巡礼等。
    case special = "S"
    /// `C<n>`：Opening / Ending 等附属影像。
    case extra = "C"
    /// `O<n>`：发布会、警告等其他集。
    case other = "O"

    /// 搜索 / 打分用的字面形态（与官方 `episode` 参数一致）。
    public var prefix: String { rawValue }

    /// 规范名里给文件名用的关键词（弹弹play 自己的特典标题用 `S2 xxx`，正片外一律带字母前缀）。
    public var keyword: String {
        switch self {
        case .special: "SP"
        case .extra: "C"
        case .other: "O"
        }
    }

    /// 未确定命名空间时的尝试顺序（Jellyfin 的 season 0 无法区分 S/C/O）。
    public static let fallbackOrder: [DanmakuSpecialKind] = [.special, .extra, .other]
}

/// 一集的编号 token：正片集数，或特典的「命名空间 + 序号」。
public enum DanmakuEpisodeToken: Sendable, Equatable {
    case number(Int)
    case special(kind: DanmakuSpecialKind, index: Int)

    /// 官方 `episode` 参数与规范名的字面形态（`12` / `S2` / `C1` / `O1`）。
    public var searchValue: String {
        switch self {
        case .number(let value): String(value)
        case .special(let kind, let index): "\(kind.prefix)\(index)"
        }
    }

    /// 正片集数（特典为 nil）。
    public var numberValue: Int? {
        if case .number(let value) = self { return value }
        return nil
    }

    private static let specialPrefixRegex = DanmakuFilenameParser.compiled("^([SCO])(\\d{1,3})(?![0-9])")
    private static let numberedEpisodeRegex = DanmakuFilenameParser.compiled(
        "(?i)第\\s*(\\d+)\\s*[话話集回期]")
    private static let chineseWordEpisodeRegex = DanmakuFilenameParser.compiled(
        "(?i)第\\s*([一二两三四五六七八九十]+)\\s*[话話集回期]")
    private static let leadingNumberRegex = DanmakuFilenameParser.compiled(
        "^(?:EP|E)?\\s*(\\d{1,4})(?:\\b|\\s|$)")

    /// 解析一集标题（弹弹play 的 `episodeTitle`，或本地文件的分集名）。
    ///
    /// 顺序：字母命名空间前缀 → 「第 N 话/集/回」→ 开头独立数字 → 通用文件名解析。
    /// 故意**不做**「标题里出现过这个数字就算命中」的宽松兜底：`S5 聖地巡礼` 这类特典
    /// 标题里的 5 会被误判成第 5 话，正是特典污染正片匹配的来源。
    public static func parse(_ title: String?) -> DanmakuEpisodeToken? {
        guard let title, !title.isEmpty else { return nil }
        let normalized = DanmakuFilenameParser.normalizeFullWidth(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(normalized.startIndex..., in: normalized)

        if let match = specialPrefixRegex.firstMatch(in: normalized, range: range),
           let kindRange = Range(match.range(at: 1), in: normalized),
           let indexRange = Range(match.range(at: 2), in: normalized),
           let kind = DanmakuSpecialKind(rawValue: String(normalized[kindRange]).uppercased()),
           let index = Int(normalized[indexRange]), index > 0 {
            return .special(kind: kind, index: index)
        }

        if let match = numberedEpisodeRegex.firstMatch(in: normalized, range: range),
           let numberRange = Range(match.range(at: 1), in: normalized),
           let number = Int(normalized[numberRange]) {
            return .number(number)
        }

        if let match = chineseWordEpisodeRegex.firstMatch(in: normalized, range: range),
           let numberRange = Range(match.range(at: 1), in: normalized),
           let number = DanmakuFilenameParser.parseChineseNumber(String(normalized[numberRange])) {
            return .number(number)
        }

        if let match = leadingNumberRegex.firstMatch(in: normalized, range: range),
           let numberRange = Range(match.range(at: 1), in: normalized),
           let number = Int(normalized[numberRange]) {
            return .number(number)
        }

        if let number = DanmakuFilenameParser.parse(title).episodeNumber {
            return .number(number)
        }
        return nil
    }
}

/// 目标侧的特典信息。命名空间可能不确定（Jellyfin 的 season 0 分不出 S/C/O），
/// 因此携带一个按序尝试的候选列表。
public struct DanmakuSpecialTarget: Sendable, Equatable {
    public let index: Int
    /// 尝试顺序：`kinds[0]` 是首选的搜索命名空间。
    public let kinds: [DanmakuSpecialKind]

    public init(index: Int, kinds: [DanmakuSpecialKind]) {
        self.index = index
        self.kinds = kinds.isEmpty ? DanmakuSpecialKind.fallbackOrder : kinds
    }
}

/// 本地文件 / 分集标题里的特典关键词 → 命名空间。
public enum DanmakuSpecialKeyword {
    private static let extraKeywords = [
        "ncop", "nced", "non-credit", "noncredit", "opening", "ending", "menu",
        "preview", "pv", "cm", "予告", "预告", "オープニング", "エンディング",
    ]
    /// OVA/OAD 故意不在列：弹弹play 常把它们编成该作品的正片「第 1 话」，
    /// 认成特典会让正确候选被扣分（正片候选与特典目标不同命名空间）。
    private static let specialKeywords = [
        "sp", "special", "特典", "特别篇", "特別篇", "番外",
    ]

    /// 关键词命中的命名空间；认不出返回 nil（调用方按 `fallbackOrder` 依次试）。
    public static func kind(in text: String) -> DanmakuSpecialKind? {
        let normalized = DanmakuFilenameParser.normalizeFullWidth(text).lowercased()
        // 附属影像先判：`NCOP` 里含 `op`，别被特典关键词抢走。
        if extraKeywords.contains(where: { containsToken(normalized, $0) }) { return .extra }
        if specialKeywords.contains(where: { containsToken(normalized, $0) }) { return .special }
        return nil
    }

    /// 关键词必须是独立 token（`sp` 不该命中 `sports`、`spring`）。
    private static func containsToken(_ text: String, _ keyword: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: keyword, range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex
                || !text[text.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == text.endIndex
                || !text[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }
}
