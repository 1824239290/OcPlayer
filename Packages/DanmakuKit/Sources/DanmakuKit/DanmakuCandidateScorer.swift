import Foundation

/// 弹幕候选打分器：用于在弹弹play返回模糊候选（isMatched == false）
/// 或搜索结果（searchEpisodes）时，自动挑选出置信度最高且无歧义的分集。
public enum DanmakuCandidateScorer {

    /// 目标匹配基准。
    public struct TargetContext: Sendable {
        public let animeTitle: String?
        public let episodeNumber: Int?
        public let seasonNumber: Int?
        public let isFinal: Bool

        public init(
            animeTitle: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            isFinal: Bool = false
        ) {
            self.animeTitle = animeTitle
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.isFinal = isFinal
        }
    }

    /// 评分后的候选分集。
    public struct ScoredMatch: Sendable {
        public let match: DanmakuEpisodeMatch
        public let score: Int

        public init(match: DanmakuEpisodeMatch, score: Int) {
            self.match = match
            self.score = score
        }
    }

    /// 合格的最低置信度阈值。保证集数相符且动画标题/季度不冲突。
    public static let confidenceThreshold = 1200

    /// 从 `MatchResponse.Match` 列表中选出最佳项。
    public static func pickBestMatch(
        from candidates: [MatchResponse.Match],
        target: TargetContext
    ) -> ScoredMatch? {
        guard !candidates.isEmpty else { return nil }
        var best: ScoredMatch? = nil

        for (index, cand) in candidates.enumerated() {
            let score = scoreCandidate(
                animeTitle: cand.animeTitle,
                episodeTitle: cand.episodeTitle,
                target: target,
                rankIndex: index
            )
            let match = DanmakuEpisodeMatch(
                episodeID: cand.episodeId,
                shiftSeconds: cand.shift ?? 0,
                animeTitle: cand.animeTitle,
                episodeTitle: cand.episodeTitle
            )
            let scored = ScoredMatch(match: match, score: score)
            if let current = best {
                if scored.score > current.score {
                    best = scored
                }
            } else {
                best = scored
            }
        }

        guard let best, best.score >= confidenceThreshold else {
            return nil
        }
        return best
    }

    /// 从 `SearchEpisodesResponse.AnimeWithEpisodes` 列表中选出最佳分集。
    public static func pickBestEpisode(
        from animes: [AnimeWithEpisodes],
        target: TargetContext
    ) -> ScoredMatch? {
        var best: ScoredMatch? = nil
        var globalIndex = 0

        for anime in animes {
            for ep in anime.episodes {
                let score = scoreCandidate(
                    animeTitle: anime.animeTitle,
                    episodeTitle: ep.episodeTitle,
                    target: target,
                    rankIndex: globalIndex
                )
                globalIndex += 1
                let match = DanmakuEpisodeMatch(
                    episodeID: ep.episodeId,
                    shiftSeconds: 0,
                    animeTitle: anime.animeTitle,
                    episodeTitle: ep.episodeTitle
                )
                let scored = ScoredMatch(match: match, score: score)
                if let current = best {
                    if scored.score > current.score {
                        best = scored
                    }
                } else {
                    best = scored
                }
            }
        }

        guard let best, best.score >= confidenceThreshold else {
            return nil
        }
        return best
    }

    /// 核心候选打分算法。
    public static func scoreCandidate(
        animeTitle: String?,
        episodeTitle: String?,
        target: TargetContext,
        rankIndex: Int = 0
    ) -> Int {
        var score = 0

        let candAnimeParsed = DanmakuFilenameParser.parse(animeTitle ?? "")
        let candEpNum = extractEpisodeNumber(from: episodeTitle)

        // 1. 集数一致性（权重最高：不能把第 1 集的弹幕套在第 2 集上）
        if let targetEp = target.episodeNumber {
            if let candEp = candEpNum {
                if candEp == targetEp {
                    score += 2000
                } else {
                    score -= 3000 // 集数明确冲突，严重扣分
                }
            } else if let epTitle = episodeTitle {
                // 如果未能解析出纯数字，检查是否包含该数字
                let normalizedEpTitle = DanmakuFilenameParser.normalizeFullWidth(epTitle)
                if normalizedEpTitle.contains("\(targetEp)") {
                    score += 600
                } else {
                    score -= 800
                }
            } else {
                score -= 500
            }
        } else {
            // 没有指定集数时（例如单集剧场版），第 1 集或单集予以加分
            if candEpNum == 1 || candEpNum == nil {
                score += 800
            }
        }

        // 2. 季度一致性
        let candSeason = candAnimeParsed.seasonNumber
        let candIsFinal = candAnimeParsed.isFinal

        if target.isFinal {
            if candIsFinal {
                score += 1500
            } else {
                score -= 1500
            }
        } else if candIsFinal {
            score -= 1500
        }

        if let targetSeason = target.seasonNumber, targetSeason > 1 {
            if candSeason == targetSeason {
                score += 1500
            } else if candSeason == nil || candSeason == 1 {
                score -= 2000 // 目标是第 N 季，候选是第 1 季
            } else {
                score -= 3000 // 目标是第 N 季，候选是其他季
            }
        } else if target.seasonNumber == 1 || target.seasonNumber == nil {
            if candSeason == nil || candSeason == 1 {
                score += 500
            } else {
                score -= 2000 // 目标是第 1 季，候选是后续季
            }
        }

        // 3. 动画主标题相似度
        if let targetTitle = target.animeTitle, !targetTitle.isEmpty {
            let targetClean = cleanTitleForComparison(targetTitle)
            let candClean = cleanTitleForComparison(candAnimeParsed.title.isEmpty ? (animeTitle ?? "") : candAnimeParsed.title)

            if targetClean == candClean {
                score += 1500 // 标题完全一致
            } else if targetClean.contains(candClean) || candClean.contains(targetClean) {
                let minLen = min(targetClean.count, candClean.count)
                let maxLen = max(targetClean.count, candClean.count)
                let ratio = maxLen > 0 ? Double(minLen) / Double(maxLen) : 0.0
                score += Int(800.0 * ratio) + 400
            } else {
                // 字符重叠比率
                let overlap = characterOverlap(targetClean, candClean)
                if overlap > 0.5 {
                    score += Int(600.0 * overlap)
                } else {
                    score -= 500
                }
            }
        } else {
            // 没有目标标题（如仅依靠 hash），给予基准分
            score += 500
        }

        // 4. 网关排序微调（排序靠前者略有优势）
        let rankBonus = max(0, 50 - rankIndex)
        score += rankBonus

        return score
    }

    /// 从分集标题中提取集数（例如 "第01话 冒险的结束" -> 1, "02" -> 2, "第3集" -> 3）
    public static func extractEpisodeNumber(from episodeTitle: String?) -> Int? {
        guard let title = episodeTitle, !title.isEmpty else { return nil }
        let normalized = DanmakuFilenameParser.normalizeFullWidth(title)

        // 优先 "第 N 话/集/回"
        if let regex = try? NSRegularExpression(pattern: "(?i)第\\s*(\\d+)\\s*[话話集回期]"),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let range = Range(match.range(at: 1), in: normalized),
           let num = Int(normalized[range]) {
            return num
        }

        // 中文数字 "第十二话"
        if let regex = try? NSRegularExpression(pattern: "(?i)第\\s*([一二两三四五六七八九十]+)\\s*[话話集回期]"),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let range = Range(match.range(at: 1), in: normalized),
           let num = DanmakuFilenameParser.parseChineseNumber(String(normalized[range])) {
            return num
        }

        // 开头独立数字（如 "01 冒险的结束" 或 "01" 或 "1"）
        if let regex = try? NSRegularExpression(pattern: "^(?:EP|E)?\\s*(\\d{1,4})(?:\\b|\\s|$)"),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let range = Range(match.range(at: 1), in: normalized),
           let num = Int(normalized[range]) {
            return num
        }

        // 通用文件名提取器回退
        return DanmakuFilenameParser.parse(title).episodeNumber
    }

    private static func cleanTitleForComparison(_ title: String) -> String {
        let normalized = DanmakuFilenameParser.normalizeFullWidth(title).lowercased()
        var cleaned = ""
        for ch in normalized {
            if ch.isLetter || ch.isNumber {
                cleaned.append(ch)
            }
        }
        return cleaned
    }

    private static func characterOverlap(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        return Double(intersection * 2) / Double(setA.count + setB.count)
    }
}
