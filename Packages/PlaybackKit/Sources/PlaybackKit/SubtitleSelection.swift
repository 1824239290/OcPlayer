import Foundation

/// 用户在设置里选的字幕语言偏好。
///
/// 内核（Erika）打开媒体时按 **probe 顺序取第一条字幕轨**（不看 disposition，也不
/// 认语言偏好——见上游 `playback.rs` 的 `find(|t| t.kind == Subtitle)`）——片源里
/// 第一条是英文字幕 / 日文字幕时，中文用户每次开片都要手动切一次。
/// 偏好由 App 层在轨道列表刷新后翻译成 `selectSubtitleTrack`（见
/// `SubtitleTrackSelector`）：内核只提供「选哪条」的能力，判断留给宿主。
public enum SubtitleLanguagePreference: String, Sendable, CaseIterable, Codable {
    /// 中文优先（简体优先）。默认值——大陆用户看到的就是这一档。
    case chineseSimplified = "zh-Hans"
    /// 中文优先（繁体优先）。
    case chineseTraditional = "zh-Hant"
    /// 跟随文件默认：内核选哪条就哪条，App 完全不干预。
    case followSource = "followSource"
    /// 默认关闭字幕。
    case off = "off"
}

/// 自动选轨要执行的动作。`keep` 是绝大多数刷新里的结果，调用方据此保持静默。
public enum SubtitleSelection: Equatable, Sendable {
    /// 不动当前选择（内核的默认被认可 / 已经是最优解）。
    case keep
    /// 关闭字幕。
    case disable
    /// 选中指定轨道。
    case select(Int64)
}

/// 按语言偏好从轨道列表里挑字幕。
///
/// 纯函数：不碰引擎、不读 UserDefaults，方便逐条钉住识别与排序规则——这段判断
/// 全是「字符串像不像中文」的启发式，只有用例能把边界固定下来。
///
/// 设计取舍：
/// - **只认中文，不认「第一条」**。一个中文字幕都没有时保留内核/容器的默认选择，
///   宁可不切也不乱切（这正是用户抱怨的「默认用第一个」）。
/// - **同分优先保留当前选中**：双语片里内核挑中的第一条常常正好是简体轨，能被认可就不要
///   为等价候选来回切。
/// - 判据来自 `language` / `title` / 外挂字幕显示名三处拼接：内封轨的语言标签常为
///   空、语言信息藏在轨名里（"简体中文"、"CHS&JPN"），而 Jellyfin 侧车字幕的
///   可读名（"简体"）只存在于 App 层映射里。
public enum SubtitleTrackSelector {
    /// 轨名 / 语言里能看出简繁时用的档位。
    private enum ChineseScript {
        case simplified, traditional, unknown
    }

    /// 选出该执行的动作。
    ///
    /// - Parameters:
    ///   - tracks: 当前全部轨道（视频 / 音频会被过滤掉）。
    ///   - preference: 用户偏好。
    ///   - current: 当前选中的字幕轨 id（`nil` = 现在是关的）。
    ///   - displayNames: 轨道 id → App 层显示名（Jellyfin 侧车字幕的标题）。
    ///     内核不带这些元数据，菜单里靠它显示，选轨时也靠它判断语言。
    public static func selection(
        in tracks: [TrackInfo],
        preference: SubtitleLanguagePreference,
        current: Int64?,
        displayNames: [Int64: String] = [:]
    ) -> SubtitleSelection {
        let subtitles = tracks.filter { $0.kind == .subtitle }
        guard !subtitles.isEmpty else { return .keep }
        // 「全是外挂字幕、且一条都没被选中」→ 兜第一条。
        //
        // 内封轨由内核按 probe 顺序挑第一条，宿主不该推翻；但**外挂轨内核完全不碰**，
        // 不兜就是「有字幕却一条都不显示」（只有侧车字幕的直连片源就是这种）。
        // 这是加偏好之前的既有行为，`followSource` 档也照旧保留。
        if preference != .off, current == nil,
           subtitles.allSatisfy({ $0.source == .external }),
           let first = subtitles.first {
            return .select(first.id)
        }
        switch preference {
        case .followSource:
            return .keep
        case .off:
            return current == nil ? .keep : .disable
        case .chineseSimplified, .chineseTraditional:
            break
        }
        let preferred: ChineseScript =
            preference == .chineseSimplified ? .simplified : .traditional
        var best: (id: Int64, score: Int)?
        for track in subtitles {
            guard let score = chineseScore(
                for: track, displayName: displayNames[track.id], preferred: preferred
            ) else { continue }
            // 同分保持先出现的（内封在前、外挂按装载顺序），结果与轨道顺序一样稳定。
            if let currentBest = best, score <= currentBest.score { continue }
            best = (track.id, score)
        }
        guard let best else {
            // 一条中文字幕都没有：保持内核的选择，不退回「第一条」——用户抱怨的是
            // 「默认用第一个」，不是「没有中文也要乱切」。
            return .keep
        }
        guard current != best.id else { return .keep }
        // 当前选中的与最优解同档（例如都是中文、只差简繁标注）→ 尊重内核的默认。
        if let current,
           let currentTrack = subtitles.first(where: { $0.id == current }),
           chineseScore(
               for: currentTrack, displayName: displayNames[current], preferred: preferred
           ) == best.score {
            return .keep
        }
        return .select(best.id)
    }

    /// 一条字幕轨的「中文契合度」：nil = 看不出中文；数字越大越贴合偏好。
    ///
    /// 分档刻意留出间隔而不是并列：偏好简体的用户拿到「没标简繁的中文」应优于
    /// 「明确标了繁体」，但两者都远优于没有中文字幕（后者根本不进候选）。
    private static func chineseScore(
        for track: TrackInfo,
        displayName: String?,
        preferred: ChineseScript
    ) -> Int? {
        let fields = Fields(track: track, displayName: displayName)
        guard fields.looksChinese else { return nil }
        let detected = fields.script
        if detected == preferred { return 120 }
        return detected == .unknown ? 110 : 105
    }

    /// 参与判定的三段文本，按**可信度**分开对待——三段里的同一串 token 含义并不相同：
    ///
    /// - `language`：内核给的语言标签（`chi` / `zh-Hans`…）。这里的 `sc` / `sg` / `mo`
    ///   是**真语言码**（撒丁语 / 桑戈语 / 摩尔多瓦语），不能当简繁标注看。
    /// - `title`：内封轨的轨名，发布组习惯在这里写 `CHS` / `SC` / `Big5`——短 token
    ///   在这一段里可信。
    /// - `display`：App 层给外挂字幕拼的显示名，兜底可能是 `codec.uppercased()`
    ///   （外部输入，不受控），短 token 在这一段里同样不算数。
    private struct Fields {
        let language: String
        let title: String
        let display: String

        init(track: TrackInfo, displayName: String?) {
            language = normalize([track.language])
            title = normalize([track.title])
            display = normalize([displayName])
        }

        /// 三段里任一段出现「强」信号即算中文轨；弱信号（`SC` / `TC` 这类两字母
        /// 标注）只在**轨名**里能单独成立。
        var looksChinese: Bool {
            for field in [language, title, display] where hasStrongSignal(field) { return true }
            return hasWeakScriptToken(title)
        }

        /// 简繁判定：三段各自得出一个结论，**互相矛盾就降级为「不知道」**。
        /// muxer 常把整条轨的语言码标成别的（整条继承第一条），此时轨名才是用户的
        /// 真实信号；两个结论打架时按「未标注」处理（110 分），避免选中与偏好相反的那条。
        var script: ChineseScript {
            var conclusive: [ChineseScript] = []
            for (field, allowsWeak) in [(language, false), (title, true), (display, false)] {
                let value = scriptOf(field, allowsWeakTokens: allowsWeak)
                if value != .unknown { conclusive.append(value) }
            }
            guard let first = conclusive.first else { return .unknown }
            return conclusive.allSatisfy { $0 == first } ? first : .unknown
        }
    }

    /// 参与匹配的三段文本拼成一个小写 haystack：分隔符统一成空格，便于按 token
    /// 命中 "zh-cn" → "zh cn" 这类带区划的标签，同时保留 CJK 词做子串匹配。
    private static func normalize(_ parts: [String?]) -> String {
        parts
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber { return character }
                return " "
            }
            .reduce(into: "") { $0.append($1) }
    }

    private static func tokens(_ haystack: String) -> [String] {
        haystack.split(separator: " ").map(String.init)
    }

    /// 语言标签或轨名里任一处指向中文（含 `chinese` 这类英文全称）即算中文轨。
    private static func hasStrongSignal(_ haystack: String) -> Bool {
        let parts = tokens(haystack)
        let set = Set(parts)
        if !set.isDisjoint(with: chineseLanguageTokens) { return true }
        if !set.isDisjoint(with: strongScriptTokens) { return true }
        let compact = parts.joined()
        return chineseWords.contains { compact.contains($0) }
    }

    private static func hasWeakScriptToken(_ haystack: String) -> Bool {
        !Set(tokens(haystack)).isDisjoint(with: weakScriptTokens)
    }

    private static func scriptOf(_ haystack: String, allowsWeakTokens: Bool) -> ChineseScript {
        let parts = tokens(haystack)
        let set = Set(parts)
        let compact = parts.joined()
        if !set.isDisjoint(with: simplifiedTokens) { return .simplified }
        if !set.isDisjoint(with: traditionalTokens) { return .traditional }
        if allowsWeakTokens {
            if !set.isDisjoint(with: weakSimplifiedTokens) { return .simplified }
            if !set.isDisjoint(with: weakTraditionalTokens) { return .traditional }
        }
        if simplifiedWords.contains(where: { compact.contains($0) }) { return .simplified }
        if traditionalWords.contains(where: { compact.contains($0) }) { return .traditional }
        return .unknown
    }

    // MARK: - 词表

    /// 语言代码（ISO 639-1/2/3 + 常见别名）。只认**整 token**，避免在
    /// "jpn"/"eng" 这类标签里误命中。
    private static let chineseLanguageTokens: Set<String> = [
        "zh", "zho", "chi", "chn", "cmn", "yue", "cn",
        "zhcn", "zhtw", "zhhk", "zhsg", "zhs", "zht", "zhhans", "zhhant",
        "chinese", "mandarin", "cantonese",
    ]

    /// 简繁标注里**不会歧义**的 token（发布组习惯用法 + 英文全称——Jellyfin 的流
    /// 标题常写成 "Chinese (Simplified)"）。`tc` / `tw` / `hk` / `gb` 都不是 ISO
    /// 语言码，在这里出现就只能是简繁标注。
    private static let strongScriptTokens: Set<String> = [
        "chs", "cht", "tc", "tcl", "gb", "gb2312", "big5", "hans", "hant",
        "simplified", "traditional",
    ]

    /// 会与 ISO 639-1 语言码撞车的短 token：`sc` = 撒丁语、`sg` = 桑戈语、
    /// `mo` = 摩尔多瓦语。所以只在**轨名**里当作简繁标注认。
    private static let weakScriptTokens: Set<String> = ["sc", "sg", "mo"]

    private static let simplifiedTokens: Set<String> = [
        "hans", "cn", "chs", "scl", "gb", "gb2312", "simplified",
    ]
    /// `tw`（台湾）/ `hk`（香港）是区划码而不是语言码，出现即繁体。
    private static let traditionalTokens: Set<String> = [
        "hant", "cht", "tc", "tcl", "big5", "traditional", "tw", "hk",
    ]
    private static let weakSimplifiedTokens: Set<String> = ["sc", "sg"]
    private static let weakTraditionalTokens: Set<String> = ["mo"]

    /// CJK 词（子串匹配；这些词不会出现在非中文轨名里）。
    ///
    /// 「中日/中英/简日…」这类**双语轨名**是内封 ASS 的常见写法，且内封轨的
    /// `language` 往往是空的——只认语言码会连同它们一起漏掉。
    private static let chineseWords: Set<String> = [
        "中文", "中字", "简体", "繁体", "繁體", "简中", "繁中", "国语", "國語",
        "华语", "華語", "汉语", "漢語", "粤语", "粤語", "广东话", "廣東話",
        "中日", "日中", "中英", "英中", "中韩", "韩中",
        "简日", "日简", "繁日", "日繁", "简英", "繁英", "简繁", "繁简",
    ]

    /// 「简」「繁」单字也认：「简体字幕」「繁體中文字幕」这类轨名不一定有完整词。
    private static let simplifiedWords: Set<String> = ["简", "簡"]
    private static let traditionalWords: Set<String> = ["繁", "正体", "正體"]
}
