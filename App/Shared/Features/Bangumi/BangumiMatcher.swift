import BangumiKit
import CoreModel
import Foundation

/// 动画标题解析出的结构化元数据。
public struct AnimeTitleInfo: Sendable, Equatable {
    public var rawTitle: String
    public var cleanBaseName: String
    public var season: Int?
    public var part: Int?
    public var isFinal: Bool
    public var subtitle: String?
    public var year: Int?

    public init(
        rawTitle: String,
        cleanBaseName: String,
        season: Int? = nil,
        part: Int? = nil,
        isFinal: Bool = false,
        subtitle: String? = nil,
        year: Int? = nil
    ) {
        self.rawTitle = rawTitle
        self.cleanBaseName = cleanBaseName
        self.season = season
        self.part = part
        self.isFinal = isFinal
        self.subtitle = subtitle
        self.year = year
    }
}

/// 动画标题解析与规范化工具。
public enum AnimeTitleParser {

    // MARK: - 静态编译的正则
    //
    // 打分器对**每个候选**都调两次 `parse()`（`nameCN` + `name`），一次自动匹配最多
    // 360 次；而单次 `parse` 原先现场编译 **43 条** `NSRegularExpression`（24 剥离表
    // + 12 ASCII 罗马数字 + 5 季数 + 2 Part）。实测每次 `parse` 的编译次数在 **51–86**
    // 之间（标题不同走到的分支不同；`explicitSeasonName` 非空时最多，走第二次 `cleanBaseString`）。
    //
    // 实测（本机 Debug，5 轮取均值）：
    //   `NSRegularExpression` **编译 61.5 µs / 条**，**匹配 0.53 µs / 条** —— 差两个数量级。
    //   改前单次 `parse` **0.812 ms** → 改后 **0.208 ms（−74%）**；
    //   一次「90 候选 × 2 遍」的 `pickBestCandidate` **262.3 ms → 69.7 ms（−73%）**。
    //
    // 与 `DanmakuKit/DanmakuFilenameParser` 同一套做法（那边注释里写着
    // 「全集搜索可返回数百分集——现场编译正则就是主线程秒级卡顿」，同一个病）。
    //
    // ## 三条刻意的边界
    //
    // **① 只提「本来就走 `NSRegularExpression`」的那批，`finalPatterns` 那 3 条不动。**
    // 那 3 条走 `String.range(of:options:.regularExpression)`。**穷举实测证明两套 API
    // 不等价**：36816 条语料（含 BMP 0x20–0x2FFF 逐码点包裹）上，`finalPatterns`
    // 那 3 条出现 **2300 处分歧**（如 `"Final Season\u{300}"`：`range(of:)` 判不匹配、
    // `NSRegularExpression` 判匹配）。这比 `REJ-02` 记的 `\d` 口径差异**更广** ——
    // 连 `\s` 与大小写折叠都不同。所以那 3 条**必须留在原 API**：它对每次 `parse`
    // 只花 3×4.58 = 13.7 µs，省这点钱去冒语义漂移的险不划算。
    //
    // **② 编译失败仍然静默跳过（`compactMap`），不改成 `preconditionFailure`。**
    // 语义必须逐字保持：改前是 `if let regex = try? ...`，编译失败那条就跳过。
    // 若哪天某条 pattern 编不过，golden 语料（`AnimeTitleParserGoldenTests`）会立刻
    // 报红 —— 有测试兜着，不需要在运行时炸掉用户。
    //
    // ⚠️ 但这句话**曾经是假的**：2026-10-18 独立审查逐条把 43 条 pattern 换成哨兵跑
    // golden，发现 **19 条删掉后 golden 仍全绿**（当时语料只有 39 条）。现已补到
    // **50 条**并逐条复验（每条都实测过「替换成哨兵 → golden 报红」）。将来**新增
    // pattern 必须同时给 golden 加一条能触发它的标题**，否则这个守卫会退化成装饰。
    //
    // **③ 剩下 208 µs 已经不是正则了**：43 条匹配 22.8 µs + 3 条 `range(of:)` 13.7 µs
    // = 36.5 µs，其余 **171.5 µs 是字符串处理**（`normalizeFullWidth` 逐 scalar 重建、
    // `replaceChineseSeasonNumbers` 40 趟 + `replaceRomanNumerals` 22 趟整串替换、
    // `cleanBaseString` 末尾逐字符过滤）。要继续压得往那儿去，别再琢磨正则了。

    /// 编译一条内置正则。模式是常量，理论上不会失败；失败返回 nil 让调用方跳过
    /// （与改动前的 `try?` 语义一致）。
    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    /// `cleanBaseString` 的噪声剥离表（24 条）。
    private static let stripRegexes: [NSRegularExpression] = [
        // 最终季 / 完结篇
        "(?i)(?:the\\s+)?final\\s+season",
        "最终季", "完结篇", "完结",
        // 季数
        "(?i)season\\s*\\d+",
        "(?i)\\d+(?:st|nd|rd|th)\\s*season",
        "(?i)\\bS\\d+\\b",
        "第\\s*\\d+\\s*[季期部]",
        // 结尾独立数字季（如 "吹响吧！上低音号 3" / "约会大作战 4"）
        "(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}a-zA-Z])\\s+\\d{1,2}\\s*$",
        // Part / Cour
        "(?i)part\\s*\\d+",
        "(?i)cour\\s*\\d+",
        "第\\s*\\d+\\s*クール",
        "前半", "后半", "前篇", "后篇",
        // 常见特殊篇章后缀
        "游郭篇", "无限列车篇", "锻刀村篇", "柱训练篇", "怀玉[·・]?玉折", "涩谷事变", "死灭洄游",
        "(?i)after\\s*story",
    ].compactMap { compiled($0) }

    /// ASCII 罗马数字（12 条，pattern 与替换模板配对）。
    ///
    /// 模板串跟着 pattern 一起静态化 —— 只静态化 pattern 会让替换文本留在循环体的
    /// 字面量里，等于白拆一遍。
    private static let asciiRomanReplacements: [(regex: NSRegularExpression, template: String)] = [
        ("(?i)\\bVIII\\b", " 8 "),
        ("(?i)\\bVII\\b", " 7 "),
        ("(?i)\\bVI\\b", " 6 "),
        ("(?i)\\bIV\\b", " 4 "),
        ("(?i)\\bV\\b", " 5 "),
        ("(?i)\\bIII\\b", " 3 "),
        ("(?i)\\bII\\b", " 2 "),
        ("(?i)\\bIX\\b", " 9 "),
        ("(?i)\\bX\\b", " 10 "),
        // 如 デート・ア・ライブIV、Overlord II、Fate/stay night II 等结尾
        ("(?i)(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}a-zA-Z])IV$", " 4"),
        ("(?i)(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}a-zA-Z])III$", " 3"),
        ("(?i)(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}a-zA-Z])II$", " 2"),
    ].compactMap { pattern, template in
        compiled(pattern).map { (regex: $0, template: template) }
    }

    /// 季数识别（5 条）。顺序即优先级 —— 调用点按原 `else if` 链的次序逐个尝试、命中即停。
    private static let seasonRegexes: [NSRegularExpression] = [
        "第\\s*(\\d+)\\s*[季期部]",
        "(?i)season\\s*(\\d+)",
        "(?i)(\\d+)(?:st|nd|rd|th)\\s*season",
        "(?i)(?<=[\\s_\\-.\\[(])S(\\d+)(?=[\\s_\\-.\\])]|$)",
        "(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}a-zA-Z])\\s+(\\d{1,2})\\s*$",
    ].compactMap { compiled($0) }

    /// Part / Cour 识别（2 条）：`Part N` 与 `第 N クール`。
    private static let partRegexes: [NSRegularExpression] = [
        "(?i)part\\s*(\\d+)",
        "第\\s*(\\d+)\\s*クール",
    ].compactMap { compiled($0) }

    /// 中文季数替换表（40 对）—— 原先每次调用都重新分配这个字面量数组。
    private static let chineseDigitReplacements: [(String, String)] = [
        ("第十季度", "第10季"), ("第九季度", "第9季"), ("第八季度", "第8季"),
        ("第七季度", "第7季"), ("第六季度", "第6季"), ("第五季度", "第5季"),
        ("第四季度", "第4季"), ("第三季度", "第3季"), ("第二季度", "第2季"), ("第一季度", "第1季"),
        ("第十季", "第10季"), ("第九季", "第9季"), ("第八季", "第8季"),
        ("第七季", "第7季"), ("第六季", "第6季"), ("第五季", "第5季"),
        ("第四季", "第4季"), ("第三季", "第3季"), ("第二季", "第2季"), ("第一季", "第1季"),
        ("第十期", "第10期"), ("第九期", "第9期"), ("第八期", "第8期"),
        ("第七期", "第7期"), ("第六期", "第6期"), ("第五期", "第5期"),
        ("第四期", "第4期"), ("第三期", "第3期"), ("第二期", "第2期"), ("第一期", "第1期"),
        ("第十部", "第10部"), ("第九部", "第9部"), ("第八部", "第8部"),
        ("第七部", "第7部"), ("第六部", "第6部"), ("第五部", "第5部"),
        ("第四部", "第4部"), ("第三部", "第3部"), ("第二部", "第2部"), ("第一部", "第1部"),
    ]

    /// Unicode 罗马数字替换表（10 对）。
    private static let unicodeRomanReplacements: [(String, String)] = [
        ("Ⅰ", " 1 "), ("Ⅱ", " 2 "), ("Ⅲ", " 3 "), ("Ⅳ", " 4 "), ("Ⅴ", " 5 "),
        ("Ⅵ", " 6 "), ("Ⅶ", " 7 "), ("Ⅷ", " 8 "), ("Ⅸ", " 9 "), ("Ⅹ", " 10 "),
    ]

    /// 最终季识别用的 3 条 —— **刻意继续走 `String.range(of:)`**（见本节开头边界 ①）。
    private static let finalPatterns = [
        "(?i)(?:the\\s+)?final\\s+season", "最终季", "完结篇",
    ]

    /// 篇章关键词（11 条）。
    private static let arcKeywords = [
        "游郭篇", "无限列车篇", "锻刀村篇", "柱训练篇", "怀玉·玉折", "怀玉玉折",
        "涩谷事变", "死灭洄游", "after story", "afterstory", "代号白",
    ]

    /// 全角字符转半角。
    public static func normalizeFullWidth(_ str: String) -> String {
        var result = ""
        for scalar in str.unicodeScalars {
            if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
                if let converted = UnicodeScalar(scalar.value - 0xFEE0) {
                    result.append(Character(converted))
                    continue
                }
            } else if scalar.value == 0x3000 {
                result.append(" ")
                continue
            }
            result.append(Character(scalar))
        }
        return result
    }

    /// 中文季数转换为阿拉伯数字形式。
    public static func replaceChineseSeasonNumbers(_ str: String) -> String {
        var s = str
        let chineseDigits = Self.chineseDigitReplacements
        for (cn, ar) in chineseDigits {
            s = s.replacingOccurrences(of: cn, with: ar)
        }
        return s
    }

    /// 罗马数字转换。
    public static func replaceRomanNumerals(_ str: String) -> String {
        var s = str
        let unicodeRomans = Self.unicodeRomanReplacements
        for (r, n) in unicodeRomans {
            s = s.replacingOccurrences(of: r, with: n)
        }

        // ASCII 罗马数字（词边界或后缀）
        for (regex, template) in Self.asciiRomanReplacements {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: template)
        }
        return s
    }

    /// 提取标题的纯净化主名称（剥除季数、副标题、括号、标点符号及空格）。
    public static func cleanBaseString(_ str: String) -> String {
        var s = normalizeFullWidth(str)
        s = replaceChineseSeasonNumbers(s)
        s = replaceRomanNumerals(s)

        // 去除篇章括号内容（如 ～到了异世界就拿出真本事～, (2024), 【第2季】）
        // 但保留核心汉字与假名/字母
        // 剥离表与编译好的正则都是静态量（见类型开头的「静态编译的正则」）。
        for regex in Self.stripRegexes {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: " ")
        }

        // 去除标点符号与特殊字符
        var cleaned = ""
        for char in s.lowercased() {
            if char.isLetter || char.isNumber {
                cleaned.append(char)
            }
        }
        return cleaned
    }

    /// 解析标题为结构化元数据。
    public static func parse(
        title: String,
        explicitSeason: Int? = nil,
        explicitSeasonName: String? = nil,
        year: Int? = nil
    ) -> AnimeTitleInfo {
        let normalized = normalizeFullWidth(title)
        let converted = replaceRomanNumerals(replaceChineseSeasonNumbers(normalized))

        var detectedSeason: Int? = explicitSeason
        var detectedPart: Int? = nil
        var isFinal = false
        var subtitle: String? = nil

        // 1. 最终季识别
        for p in Self.finalPatterns {
            if converted.range(of: p, options: .regularExpression) != nil {
                isFinal = true
                break
            }
        }

        // 2. 季数识别（若未显式指定）
        if detectedSeason == nil {
            // 前 5 条正则按优先级依次尝试（第 N 季 / Season N / Nth Season / S N /
            // 结尾裸数字），命中第一条即停 —— 与原先的 `else if` 链等价。
            //
            // ⚠️ `usedRegex` 这个标志**必须保留**，不能写成「命中就拿值、否则走后面的
            // 兜底」：原实现里只要某条正则**完整绑定成功**（正则命中且捕获组能转成
            // Range），后面的 `else if` 全被跳过 —— 哪怕 `Int(converted[range])` 返回
            // nil。这不是假想情形：`NSRegularExpression` 的 `\\d` 等于 `\\p{Nd}`，
            // 「第٣季」（阿拉伯-印度数字）会命中、而 `Int("٣")` 是 nil，于是
            // season 保持 nil 且**不会**再去看 S/T/续/完。
            //
            // golden 语料里有「第٣季 续 ⟹ season=nil」（**不是** 2）钉着这条 —— 这句
            // 声明原先也是假的（独立审查指出语料根本没覆盖），补完已实测：把本标志改回
            // `if detectedSeason == nil`，golden 立刻报红。
            var usedSeasonRegex = false
            for regex in Self.seasonRegexes {
                guard let match = regex.firstMatch(
                        in: converted, range: NSRange(converted.startIndex..., in: converted)),
                      let range = Range(match.range(at: 1), in: converted)
                else { continue }
                detectedSeason = Int(converted[range])
                usedSeasonRegex = true
                break
            }
            if !usedSeasonRegex {
            // 特殊单字母续作（超电磁炮S -> 2, 超电磁炮T -> 3）。只认「结尾
            // S/T 的前一个字符是 CJK 或分隔符」——Arknights 这类以拉丁字母
            // 结尾的标题不能被误判成第二季（整季误绑）。
            if AnimeTitleParser.trailingSeasonLetter(converted) == "S" || converted.contains(" S ") {
                subtitle = "s"
                detectedSeason = 2
            } else if AnimeTitleParser.trailingSeasonLetter(converted) == "T" || converted.contains(" T ") {
                subtitle = "t"
                detectedSeason = 3
            } else if converted.hasSuffix("续") {
                detectedSeason = 2
            } else if converted.hasSuffix("完") {
                isFinal = true
            }
            }
        }

        // 3. Part / Cour 识别（前 2 条正则按优先级；同样用标志保留原 `else if` 语义）
        var usedPartRegex = false
        for regex in Self.partRegexes {
            guard let match = regex.firstMatch(
                    in: converted, range: NSRange(converted.startIndex..., in: converted)),
                  let range = Range(match.range(at: 1), in: converted)
            else { continue }
            detectedPart = Int(converted[range])
            usedPartRegex = true
            break
        }
        if usedPartRegex {
            // 已由正则判定，跳过中文「前半 / 后半」兜底
        } else if converted.contains("前半") || converted.contains("前篇") {
            detectedPart = 1
        } else if converted.contains("后半") || converted.contains("后篇") {
            detectedPart = 2
        }

        // 4. 副标题 / 篇章识别
        let lower = converted.lowercased()
        for kw in Self.arcKeywords {
            if lower.contains(kw) {
                subtitle = kw
                break
            }
        }

        // 如果显式传入了 seasonName（如 "游郭篇"），进一步覆盖
        if let explicitSeasonName, !explicitSeasonName.isEmpty {
            let cleanSeasonName = cleanBaseString(explicitSeasonName)
            if !cleanSeasonName.isEmpty, subtitle == nil {
                subtitle = cleanSeasonName
            }
        }

        let cleanBase = cleanBaseString(title)

        return AnimeTitleInfo(
            rawTitle: title,
            cleanBaseName: cleanBase,
            season: detectedSeason,
            part: detectedPart,
            isFinal: isFinal,
            subtitle: subtitle,
            year: year
        )
    }
}

extension Notification.Name {
    /// Bangumi 关联变更（详情页头部的 Bangumi 站点图标据此刷新）。
    /// object 是发生变更的 Jellyfin 条目 id。
    static let bangumiLinkDidChange = Notification.Name("OcPlayer.bangumiLinkDidChange")
}

/// Jellyfin 条目 ↔ Bangumi 条目的智能关联匹配器。
@MainActor
public enum BangumiMatcher {

    /// 取某个 Jellyfin 条目关联的 Bangumi subject ID（nil = 未关联）。
    public static func linkedSubjectID(forJellyfinItemID itemID: MediaItem.ID) -> Int? {
        BangumiStore.shared.bangumiSubjectID(forJellyfinItemID: itemID)
    }

    /// 设置关联映射。
    ///
    /// 全仓关联的**唯一写入口**，变更广播就挂在这里：将来新增调用点自动带上广播，
    /// 不必各自记得发一次通知（详情页头部的站点图标靠它即时出现 / 消失）。
    public static func setLinkedSubjectID(_ subjectID: Int?, forJellyfinItemID itemID: MediaItem.ID) {
        BangumiStore.shared.setBangumiSubjectID(subjectID, forJellyfinItemID: itemID)
        NotificationCenter.default.post(name: .bangumiLinkDidChange, object: itemID)
    }

    /// 详情页共用的关联解析链：选中的季 → 剧集 → 条目自身；第 1 季 / 单季再回落到剧集。
    ///
    /// 这条链原来内联在 `BangumiChapterSection.load()` 里，详情页头部的站点图标是
    /// 第二个读点——收敛到这里，详情页只有一处读法，行为与原来逐字一致。
    ///
    /// **播放结束的自动标记不走这里**（`AppModel+Playback`）：那条链拿的是分集条目自己的
    /// `seasonID`，且没有「第 1 季才回落」这一档，语义不同（它要落的是这一集所属的那一季）。
    public static func linkedSubjectID(for item: MediaItem, selectedSeason: MediaItem?) -> Int? {
        let primary = selectedSeason?.id ?? item.seriesID ?? item.id
        if let linked = linkedSubjectID(forJellyfinItemID: primary) { return linked }
        // 只有第 1 季 / 单季才回落到剧集：其它季各自关联不同 subject，回落会串季。
        guard selectedSeason == nil || selectedSeason?.seasonNumber == 1 else { return nil }
        let fallback = item.seriesID ?? item.id
        guard fallback != primary else { return nil }
        return linkedSubjectID(forJellyfinItemID: fallback)
    }

    /// 持久化「条目 ↔ subject」关联的统一入口：主键 +「第 1 季 / 单季回落 series」
    /// 双写——与 `linkedSubjectID(for:selectedSeason:)` 的读取链正好镜像。自动匹配
    /// 与手动选择都走这里，回落规则只有一份（曾散在三处各抄一遍）。
    public static func persistLink(_ subjectID: Int, for item: MediaItem, season: MediaItem?) {
        let linkItemID = season?.id ?? item.seriesID ?? item.id
        setLinkedSubjectID(subjectID, forJellyfinItemID: linkItemID)
        if season == nil || season?.seasonNumber == 1 {
            let fallbackID = item.seriesID ?? item.id
            if fallbackID != linkItemID {
                setLinkedSubjectID(subjectID, forJellyfinItemID: fallbackID)
            }
        }
    }

    /// 自动匹配：返回命中的 subject（未命中 nil）。命中即持久化关联。
    public static func autoMatch(
        for item: MediaItem,
        season: MediaItem? = nil
    ) async throws -> BangumiSlimSubjectDTO? {
        guard let result = try await searchAndPick(for: item, season: season) else { return nil }
        persistLink(result.id, for: item, season: season)
        return result
    }

    /// 手动搜索（关联选择器用）。
    public static func search(_ keyword: String) async throws -> [BangumiSlimSubjectDTO] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // 先尝试按动画类型搜索
        let animePage = try await BangumiSubjectService.search(
            keyword: trimmed, filter: .anime, limit: 30, offset: 0)
        var results = animePage.data

        // 若动画无结果，回退到全类型
        if results.isEmpty {
            let allPage = try await BangumiSubjectService.search(
                keyword: trimmed, filter: nil, limit: 30, offset: 0)
            results = allPage.data
        }

        // 排序：动画绝对优先，其次真人剧，最后按 Bangumi 原始次序
        return results.sorted { lhs, rhs in
            typeRank(lhs.type) > typeRank(rhs.type)
        }
    }

    // MARK: - 私有匹配算法

    public nonisolated static func typeRank(_ type: BangumiSubjectType) -> Int {
        switch type {
        case .anime: return 3
        case .real: return 2
        default: return 1
        }
    }

    /// 一次关键词检索。抽成参数只为**可测性**：失败路径（断网 / 服务端异常）在
    /// 生产里无法稳定复现，而「全部失败时还要不要再发一轮」正是要靠用例钉住的判断。
    /// 生产调用一律走默认值，行为与内联时逐字相同。
    public typealias SubjectSearch = @Sendable (String, BangumiSubjectType?) async throws
        -> BangumiPagedDTO<BangumiSlimSubjectDTO>

    /// 综合检索并根据打分器选出最佳条目。
        // `@escaping`：下面并发搜索要把它交给 `withTaskGroup` 的 `addTask`。
    public static func searchAndPick(
        for item: MediaItem,
        season: MediaItem? = nil,
        search: @escaping SubjectSearch = { keyword, filter in
            try await BangumiSubjectService.search(
                keyword: keyword, filter: filter, limit: 30, offset: 0)
        }
    ) async throws -> BangumiSlimSubjectDTO? {
        let seriesName = item.seriesName ?? item.name
        let seasonNumber = season?.seasonNumber ?? item.seasonNumber
        let seasonName = season?.name ?? item.seasonName

        let queryTitle: String
        if let sName = seasonName, !sName.isEmpty, season != nil {
            queryTitle = "\(seriesName) \(sName)"
        } else if let sNum = seasonNumber, sNum > 1 {
            queryTitle = "\(seriesName) 第\(sNum)季"
        } else {
            queryTitle = seriesName
        }

        let queryInfo = AnimeTitleParser.parse(
            title: queryTitle,
            explicitSeason: seasonNumber,
            explicitSeasonName: seasonName,
            year: item.year
        )

        // 1. 构造搜索关键词（优先精准季度词，失败回退基础名）
        var keywordsToTry: [String] = []
        let cleanBase = queryInfo.cleanBaseName.isEmpty ? seriesName : queryInfo.cleanBaseName

        if let s = queryInfo.season, s > 1 {
            keywordsToTry.append("\(cleanBase) 第\(s)季")
            keywordsToTry.append("\(cleanBase) Season \(s)")
            keywordsToTry.append("\(cleanBase)")
        } else if queryInfo.isFinal {
            keywordsToTry.append("\(cleanBase) 最终季")
            keywordsToTry.append("\(cleanBase) Final Season")
            keywordsToTry.append("\(cleanBase)")
        } else if let sub = queryInfo.subtitle, !sub.isEmpty {
            keywordsToTry.append("\(cleanBase) \(sub)")
            keywordsToTry.append("\(cleanBase)")
        } else {
            keywordsToTry.append(cleanBase)
            keywordsToTry.append(seriesName)
        }

        var candidates: [BangumiSlimSubjectDTO] = []
        var seenIDs = Set<Int>()
        var lastError: (any Error)?
        /// 第一轮里**真的到达了服务端**的请求数。见下面第二轮的守卫。
        var succeededSearches = 0

        let trimmedKeywords = keywordsToTry
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 合并一批搜索结果（按关键词原顺序去重，保证打分确定性）。
        func merge(_ page: BangumiPagedDTO<BangumiSlimSubjectDTO>) {
            for item in page.data where !seenIDs.contains(item.id) {
                candidates.append(item)
                seenIDs.insert(item.id)
            }
        }

        // 2. 并行按动画类型过滤搜索（原先 3 发串行，且 try? 把网络错误全吞掉，
        //    断网时静默返回 nil 被 UI 解读成「没找到」）。并行省两轮往返；
        //    高分提前返回改为收集完再判（并行本身已把请求都发出去了）。
        let animePages = await withTaskGroup(
            of: Result<BangumiPagedDTO<BangumiSlimSubjectDTO>, Error>.self
        ) { group in
            for kw in trimmedKeywords {
                group.addTask {
                    do { return .success(try await search(kw, .anime)) }
                    catch { return .failure(error) }
                }
            }
            var results: [Result<BangumiPagedDTO<BangumiSlimSubjectDTO>, Error>] = []
            for await result in group { results.append(result) }
            return results
        }
        for result in animePages {
            switch result {
            case .success(let page):
                succeededSearches += 1
                merge(page)
            case .failure(let error): lastError = error
            }
        }
        // 先算一次：下面「放开类型过滤」那一轮只在**候选为空**的罕见分支才执行，所以
        // 绝大多数调用里候选集不会再变——原先在末尾无条件再算一遍，入参、`enumerated()`
        // 位次、`queryInfo` 全都没变，结果逐字相同（`pickBestCandidate` 是纯函数）。
        // 而每个候选每次打分要 `parse` 两遍标题，单次 `parse` 又是 37–43 次现编译正则 +
        // 100 次整串替换——这一遍重算正好落在「标题不完全相等」这个最常见的模糊匹配分支上。
        var best = pickBestCandidate(from: candidates, query: queryInfo)
        if let best, best.score >= 2000 {
            return best.candidate
        }

        // 3. 若仍无候选条目（可能为三次元真人剧），放开类型过滤
        //
        // **但只有「至少有一个请求真的到达了服务端」才值得再发一轮**：第二轮用的是
        // 同一批关键词、只把 filter 换成 nil，网关全挂 / 断网时它必然也全失败，唯一
        // 效果是把等待翻倍（每轮 ≈ 关键词数 × 10 s 超时）。
        //
        // 判据取 `succeededSearches > 0` 而不是 `lastError == nil`：部分成功 + 部分
        // 失败时 `lastError` 也非空，而那一轮放开类型过滤仍可能命中真人剧 —— 用后者
        // 会把这种情形一起挡掉（`testPartialFailureStillAllowsTypeFilterRound` 守这条）。
        if candidates.isEmpty, succeededSearches > 0 {
            let allPages = await withTaskGroup(
                of: Result<BangumiPagedDTO<BangumiSlimSubjectDTO>, Error>.self
            ) { group in
                for kw in trimmedKeywords {
                    group.addTask {
                        do { return .success(try await search(kw, nil)) }
                        catch { return .failure(error) }
                    }
                }
                var results: [Result<BangumiPagedDTO<BangumiSlimSubjectDTO>, Error>] = []
                for await result in group { results.append(result) }
                return results
            }
            for result in allPages {
                switch result {
                case .success(let page): merge(page)
                case .failure(let error): lastError = error
                }
            }
            // 候选集变了，只有这一条路径需要重算。
            best = pickBestCandidate(from: candidates, query: queryInfo)
        }

        // 关键词全发失败（断网 / 服务端异常）且一个候选都没有：抛出最后一个
        // 错误让 UI 显示失败，而不是误导成「没找到」。
        if candidates.isEmpty, let lastError {
            throw lastError
        }

        guard let best else { return nil }

        // 置信度阈值：必须达到 1200 分（保证类型为动画/真人 + 标题基本匹配 + 季度无冲突）
        guard best.score >= 1200 else {
            return nil
        }

        return best.candidate
    }

    /// 在候选集中计算各项得分并选出最高分者。
    public nonisolated static func pickBestCandidate(
        from candidates: [BangumiSlimSubjectDTO],
        query: AnimeTitleInfo
    ) -> (candidate: BangumiSlimSubjectDTO, score: Int)? {
        var best: (candidate: BangumiSlimSubjectDTO, score: Int)? = nil

        for (index, cand) in candidates.enumerated() {
            let s = scoreCandidate(cand, query: query, rankIndex: index)
            if let current = best {
                if s > current.score {
                    best = (cand, s)
                }
            } else {
                best = (cand, s)
            }
        }

        return best
    }

    /// 多维度候选者打分核心算法。
    public nonisolated static func scoreCandidate(
        _ candidate: BangumiSlimSubjectDTO,
        query: AnimeTitleInfo,
        rankIndex: Int = 0
    ) -> Int {
        var score = 0

        // 1. 类型评分（动画绝对优先）
        switch candidate.type {
        case .anime:
            score += 1000
        case .real:
            score += 500
        case .book, .game, .music, .none:
            score -= 1000
        }

        // 解析候选条目的中日双语标题元数据
        let candCNInfo = AnimeTitleParser.parse(title: candidate.nameCN)
        let candJPInfo = AnimeTitleParser.parse(title: candidate.name)

        let candSeason = candCNInfo.season ?? candJPInfo.season
        let candPart = candCNInfo.part ?? candJPInfo.part
        let candIsFinal = candCNInfo.isFinal || candJPInfo.isFinal
        let candSubtitle = candCNInfo.subtitle ?? candJPInfo.subtitle

        // 2. 季度严格一致性
        let targetSeason = query.season
        let targetIsFinal = query.isFinal

        if targetIsFinal {
            if candIsFinal {
                score += 1000
            } else {
                score -= 1000
            }
        } else if candIsFinal {
            // 目标不是最终季，但候选是最终季
            score -= 1200
        }

        if let ts = targetSeason, ts > 1 {
            if candSeason == ts {
                score += 1000 // 精准匹配第 N 季
            } else if candSeason == nil || candSeason == 1 {
                score -= 1500 // 目标要第 N 季，候选却是第 1 季
            } else {
                score -= 2500 // 目标要第 N 季，候选是不同的第 M 季
            }
        } else {
            // 目标是第 1 季或未注季数
            if candSeason == nil || candSeason == 1 {
                score += 500
            } else {
                score -= 1800 // 目标是第 1 季，候选却是第 2/3/4 季
            }
        }

        // 3. Part / Cour 一致性
        if let tp = query.part {
            if candPart == tp {
                score += 500
            } else if candPart != nil {
                score -= 1000
            }
        } else if candPart != nil {
            score -= 200
        }

        // 4. 副标题 / 篇章一致性
        if let tsub = query.subtitle, !tsub.isEmpty {
            let matchCN = candCNInfo.rawTitle.lowercased().contains(tsub.lowercased())
            let matchJP = candJPInfo.rawTitle.lowercased().contains(tsub.lowercased())
            if matchCN || matchJP || candSubtitle?.lowercased() == tsub.lowercased() {
                score += 800
            } else if candSubtitle != nil {
                score -= 1200
            }
        } else if candSubtitle != nil {
            score -= 300 // 目标无特定篇章，候选为特定篇章时略微降权
        }

        // 5. 主标题相似度
        let qBase = query.cleanBaseName
        let cCNBase = candCNInfo.cleanBaseName
        let cJPBase = candJPInfo.cleanBaseName

        if !qBase.isEmpty {
            if qBase == cCNBase || qBase == cJPBase {
                score += 1200 // 主名称完全一致
            } else {
                let matchCN = cCNBase.contains(qBase) || qBase.contains(cCNBase)
                let matchJP = cJPBase.contains(qBase) || qBase.contains(cJPBase)
                if matchCN || matchJP {
                    // 相似度按「实际命中的那门语言」分别算再取最优——原先用
                    // max(中文名长度, 日文名长度) 当基准，未命中语言的长度会
                    // 把比例拉偏（日文长标题拖低中文命中的得分）。
                    func similarity(_ a: String, _ b: String) -> Double {
                        let longer = max(a.count, b.count)
                        guard longer > 0 else { return 0.5 }
                        return Double(min(a.count, b.count)) / Double(longer)
                    }
                    let ratio = max(similarity(qBase, cCNBase), similarity(qBase, cJPBase))
                    score += Int(ratio * 600)
                } else {
                    // 主标题完全无关
                    score -= 1500
                }
            }
        }

        // 6. Bangumi 搜索位次微调加分
        score += max(30 - rankIndex, 0)

        return score
    }
}

extension AnimeTitleParser {
    /// 标题结尾的「单字母续作记号」（超电磁炮S/T）：末字符是 S/T 且前一个字符
    /// 是 CJK 或分隔符时返回大写字母；末字符前是拉丁字母（Arknights、GOSICK
    /// 这类以字母结尾的标题）返回 nil，不算续作记号。
    static func trailingSeasonLetter(_ title: String) -> String? {
        guard let last = title.last, last == "S" || last == "s" || last == "T" || last == "t" else {
            return nil
        }
        let beforeLast = title.index(before: title.endIndex)
        guard let previous = title[..<beforeLast].last else { return nil }
        let isCJK = previous.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)     // CJK 统一表意文字
            || (0x3040...0x30FF).contains(scalar.value)  // 平假名 / 片假名
        }
        let isSeparator = " -_.·[(".contains(previous)
        guard isCJK || isSeparator else { return nil }
        return String(last).uppercased()
    }
}
