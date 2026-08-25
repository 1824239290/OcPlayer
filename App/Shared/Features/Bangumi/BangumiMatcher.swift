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
        let chineseDigits: [(String, String)] = [
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
        for (cn, ar) in chineseDigits {
            s = s.replacingOccurrences(of: cn, with: ar)
        }
        return s
    }

    /// 罗马数字转换。
    public static func replaceRomanNumerals(_ str: String) -> String {
        var s = str
        let unicodeRomans: [(String, String)] = [
            ("Ⅰ", " 1 "), ("Ⅱ", " 2 "), ("Ⅲ", " 3 "), ("Ⅳ", " 4 "), ("Ⅴ", " 5 "),
            ("Ⅵ", " 6 "), ("Ⅶ", " 7 "), ("Ⅷ", " 8 "), ("Ⅸ", " 9 "), ("Ⅹ", " 10 "),
        ]
        for (r, n) in unicodeRomans {
            s = s.replacingOccurrences(of: r, with: n)
        }

        // ASCII 罗马数字（词边界或后缀）
        let asciiRomans: [(String, String)] = [
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
        ]
        for (pattern, replacement) in asciiRomans {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: replacement)
            }
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
        let stripPatterns = [
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
        ]

        for p in stripPatterns {
            if let regex = try? NSRegularExpression(pattern: p) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
            }
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
        let finalPatterns = ["(?i)(?:the\\s+)?final\\s+season", "最终季", "完结篇"]
        for p in finalPatterns {
            if converted.range(of: p, options: .regularExpression) != nil {
                isFinal = true
                break
            }
        }

        // 2. 季数识别（若未显式指定）
        if detectedSeason == nil {
            // 第 N 季 / 第 N 期 / 第 N 部
            if let regex = try? NSRegularExpression(pattern: "第\\s*(\\d+)\\s*[季期部]"),
               let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
               let range = Range(match.range(at: 1), in: converted) {
                detectedSeason = Int(converted[range])
            }
            // Season N
            else if let regex = try? NSRegularExpression(pattern: "(?i)season\\s*(\\d+)"),
                    let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
                    let range = Range(match.range(at: 1), in: converted) {
                detectedSeason = Int(converted[range])
            }
            // Nst/nd/rd/th Season
            else if let regex = try? NSRegularExpression(pattern: "(?i)(\\d+)(?:st|nd|rd|th)\\s*season"),
                    let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
                    let range = Range(match.range(at: 1), in: converted) {
                detectedSeason = Int(converted[range])
            }
            // S2 / S3
            else if let regex = try? NSRegularExpression(pattern: "(?i)(?<=[\\s_\\-.\\[(])S(\\d+)(?=[\\s_\\-.\\])]|$)"),
                    let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
                    let range = Range(match.range(at: 1), in: converted) {
                detectedSeason = Int(converted[range])
            }
            // 结尾空格+数字（如 "进击的巨人 2", "吹响吧！上低音号 3", "约会大作战 4"）
            else if let regex = try? NSRegularExpression(pattern: "(?<=[\\p{Han}\\p{Hiragana}\\p{Katakana}a-zA-Z])\\s+(\\d{1,2})\\s*$"),
                    let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
                    let range = Range(match.range(at: 1), in: converted) {
                detectedSeason = Int(converted[range])
            }
            // 特殊单字母续作（超电磁炮S -> 2, 超电磁炮T -> 3）
            else if converted.hasSuffix("S") || converted.hasSuffix("s") || converted.contains(" S ") {
                subtitle = "s"
                detectedSeason = 2
            } else if converted.hasSuffix("T") || converted.hasSuffix("t") || converted.contains(" T ") {
                subtitle = "t"
                detectedSeason = 3
            } else if converted.hasSuffix("续") {
                detectedSeason = 2
            } else if converted.hasSuffix("完") {
                isFinal = true
            }
        }

        // 3. Part / Cour 识别
        if let regex = try? NSRegularExpression(pattern: "(?i)part\\s*(\\d+)"),
           let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
           let range = Range(match.range(at: 1), in: converted) {
            detectedPart = Int(converted[range])
        } else if let regex = try? NSRegularExpression(pattern: "第\\s*(\\d+)\\s*クール"),
                  let match = regex.firstMatch(in: converted, range: NSRange(converted.startIndex..., in: converted)),
                  let range = Range(match.range(at: 1), in: converted) {
            detectedPart = Int(converted[range])
        } else if converted.contains("前半") || converted.contains("前篇") {
            detectedPart = 1
        } else if converted.contains("后半") || converted.contains("后篇") {
            detectedPart = 2
        }

        // 4. 副标题 / 篇章识别
        let arcKeywords = [
            "游郭篇", "无限列车篇", "锻刀村篇", "柱训练篇", "怀玉·玉折", "怀玉玉折",
            "涩谷事变", "死灭洄游", "after story", "afterstory", "代号白",
        ]
        let lower = converted.lowercased()
        for kw in arcKeywords {
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

/// Jellyfin 条目 ↔ Bangumi 条目的智能关联匹配器。
@MainActor
public enum BangumiMatcher {

    /// 取某个 Jellyfin 条目关联的 Bangumi subject ID（nil = 未关联）。
    public static func linkedSubjectID(forJellyfinItemID itemID: MediaItem.ID) -> Int? {
        BangumiStore.shared.bangumiSubjectID(forJellyfinItemID: itemID)
    }

    /// 设置关联映射。
    public static func setLinkedSubjectID(_ subjectID: Int?, forJellyfinItemID itemID: MediaItem.ID) {
        BangumiStore.shared.setBangumiSubjectID(subjectID, forJellyfinItemID: itemID)
    }

    /// 自动匹配：返回命中的 subject（未命中 nil）。命中即持久化关联。
    public static func autoMatch(
        for item: MediaItem,
        season: MediaItem? = nil
    ) async throws -> BangumiSlimSubjectDTO? {
        guard let result = try await searchAndPick(for: item, season: season) else { return nil }

        // 决定持久化 ID：有季绑季，否则绑剧集或自身
        let linkItemID = season?.id ?? item.seriesID ?? item.id
        setLinkedSubjectID(result.id, forJellyfinItemID: linkItemID)

        // 若当前选中的是第 1 季或单季，顺便同步绑到 series ID 上，兼容旧读取逻辑
        if season == nil || season?.seasonNumber == 1 {
            let fallbackID = item.seriesID ?? item.id
            if fallbackID != linkItemID {
                setLinkedSubjectID(result.id, forJellyfinItemID: fallbackID)
            }
        }

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

    /// 综合检索并根据打分器选出最佳条目。
    public static func searchAndPick(
        for item: MediaItem,
        season: MediaItem? = nil
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

        // 2. 依次按动画类型过滤搜索，收集候选条目
        for kw in keywordsToTry {
            let trimmed = kw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let page = try? await BangumiSubjectService.search(keyword: trimmed, filter: .anime, limit: 30, offset: 0) {
                for item in page.data where !seenIDs.contains(item.id) {
                    candidates.append(item)
                    seenIDs.insert(item.id)
                }
            }
            if !candidates.isEmpty {
                // 如果已经有匹配度很高的条目，不必继续发大量请求
                if let best = pickBestCandidate(from: candidates, query: queryInfo), best.score >= 2000 {
                    return best.candidate
                }
            }
        }

        // 3. 若仍无候选条目（可能为三次元真人剧），放开类型过滤
        if candidates.isEmpty {
            for kw in keywordsToTry {
                let trimmed = kw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let page = try? await BangumiSubjectService.search(keyword: trimmed, filter: nil, limit: 30, offset: 0) {
                    for item in page.data where !seenIDs.contains(item.id) {
                        candidates.append(item)
                        seenIDs.insert(item.id)
                    }
                }
                if !candidates.isEmpty { break }
            }
        }

        guard !candidates.isEmpty else { return nil }

        // 4. 打分并选出最优候选
        guard let best = pickBestCandidate(from: candidates, query: queryInfo) else {
            return nil
        }

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
                    let lenMatch = max(cCNBase.count, cJPBase.count)
                    let ratio = lenMatch > 0 ? Double(min(qBase.count, lenMatch)) / Double(max(qBase.count, lenMatch)) : 0.5
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
