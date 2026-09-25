import Foundation

/// 弹幕候选打分器：用于在弹弹play返回模糊候选（isMatched == false）
/// 或搜索结果（searchEpisodes / searchAnime）时，自动挑选出置信度最高且无歧义的分集。
public enum DanmakuCandidateScorer {

    /// 目标作品形态。剧场版与剧集互斥：同名剧场版/真人版不得抢走剧集的弹幕。
    public enum TargetKind: Sendable, Equatable {
        case episode
        case movie
    }

    /// 目标匹配基准。
    public struct TargetContext: Sendable {
        public let animeTitle: String?
        public let episodeNumber: Int?
        public let seasonNumber: Int?
        public let isFinal: Bool
        /// 目标是特典（season 0 / 文件名关键词命中）。命名空间不确定时按 `kinds` 顺序计分。
        public let special: DanmakuSpecialTarget?
        public let kind: TargetKind

        public init(
            animeTitle: String? = nil,
            episodeNumber: Int? = nil,
            seasonNumber: Int? = nil,
            isFinal: Bool = false,
            special: DanmakuSpecialTarget? = nil,
            kind: TargetKind = .episode
        ) {
            self.animeTitle = animeTitle
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.isFinal = isFinal
            self.special = special
            self.kind = kind
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
                typeDescription: cand.typeDescription,
                type: cand.type,
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
                    typeDescription: anime.typeDescription,
                    type: anime.type,
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
        typeDescription: String? = nil,
        type: String? = nil,
        target: TargetContext,
        rankIndex: Int = 0
    ) -> Int {
        var score = 0

        let candAnimeParsed = DanmakuFilenameParser.parse(animeTitle ?? "")

        // 1. 集数一致性（权重最高：不能把第 1 集的弹幕套在第 2 集上）
        score += episodeScore(target: target, candidateEpisodeTitle: episodeTitle)

        // 2. 季度一致性
        score += seasonScore(
            target: target,
            candidateAnimeTitle: animeTitle,
            candidateIsFinal: candAnimeParsed.isFinal
        )

        // 3. 动画主标题相似度
        score += titleScore(targetTitle: target.animeTitle, candidateTitle: animeTitle)

        // 4. 作品类型（剧场版 vs 剧集互斥）
        score += typeScore(target: target, typeDescription: typeDescription, type: type)

        // 5. 网关排序微调（排序靠前者略有优势）
        score += rankBonus(rankIndex: rankIndex)

        return score
    }

    /// 集数一致性。正片与特典是两个命名空间，冲突时不再一票判死，
    /// 但要输给同命名空间正确命中的候选。
    private static func episodeScore(target: TargetContext, candidateEpisodeTitle: String?) -> Int {
        let candidate = DanmakuEpisodeToken.parse(candidateEpisodeTitle)

        if let special = target.special {
            switch candidate {
            case .special(let kind, let index) where index == special.index:
                // 序号对上了；命名空间按目标给的偏好顺序给分（Jellyfin season 0 分不出 S/C/O）。
                guard let rank = special.kinds.firstIndex(of: kind) else { return 300 }
                return rank == 0 ? 2000 : 1500
            case .special:
                return -800
            case .number(let value) where value == special.index:
                // 序号相同的正片候选：OVA/OAD 常被弹弹play 编成同作品的正片「第 N 话」，
                // 给一次机会（弱于真正的特典命中，强于其他正片候选）。
                return 600
            case .number:
                return -1500
            case nil:
                return -500
            }
        }

        if let targetEpisode = target.episodeNumber {
            switch candidate {
            case .number(let value) where value == targetEpisode:
                return 2000
            case .number:
                return -3000 // 正片集数明确冲突，严重扣分
            case .special:
                // 特典候选（S5 聖地巡礼 之类）不得被当成第 5 话，但也不一票判死。
                return -1500
            case nil:
                return -500
            }
        }

        // 没有指定集数时（例如单集剧场版），第 1 集或单集予以加分
        switch candidate {
        case .number(let value) where value == 1:
            return 800
        case .number:
            return 0
        case .special:
            return -500
        case nil:
            return 800
        }
    }

    /// 季度一致性。
    private static func seasonScore(
        target: TargetContext,
        candidateAnimeTitle: String?,
        candidateIsFinal: Bool
    ) -> Int {
        let candidate = DanmakuFilenameParser.parse(candidateAnimeTitle ?? "")
        let candSeason = candidate.seasonNumber
        var score = 0

        if target.isFinal {
            score += candidateIsFinal ? 1500 : -1500
        } else if candidateIsFinal {
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
        return score
    }

    /// 主标题相似度。
    private static func titleScore(targetTitle: String?, candidateTitle: String?) -> Int {
        guard let targetTitle, !targetTitle.isEmpty else {
            // 没有目标标题（如仅依靠 hash），给予基准分
            return 500
        }
        let targetClean = DanmakuFilenameParser.comparableTitle(targetTitle)
        let candidateClean = DanmakuFilenameParser.comparableTitle(candidateTitle ?? "")
        guard !candidateClean.isEmpty else { return -500 }

        if targetClean == candidateClean {
            return 1500 // 标题完全一致
        }
        if targetClean.contains(candidateClean) || candidateClean.contains(targetClean) {
            let minLen = min(targetClean.count, candidateClean.count)
            let maxLen = max(targetClean.count, candidateClean.count)
            let ratio = maxLen > 0 ? Double(minLen) / Double(maxLen) : 0.0
            return Int(800.0 * ratio) + 400
        }
        // 字符重叠比率
        let overlap = characterOverlap(targetClean, candidateClean)
        if overlap > 0.5 {
            return Int(600.0 * overlap)
        }
        return -500
    }

    /// 作品类型：剧场版/电影与剧集是**不同作品**，属身份约束而非偏好——不匹配直接判死，
    /// 任何集数/标题加分都压不过。实测：中二病 S00E29 特典曾被同 IP 剧场版的 S29 特典
    /// 以「序号命中 +2000 + 标题包含 +666」抵过阈值，本门槛堵的就是这类错配。
    private static func typeScore(
        target: TargetContext,
        typeDescription: String?,
        type: String?
    ) -> Int {
        let description = typeDescription ?? ""
        let isMovie = type == "movie" || description.contains("剧场版") || description.contains("电影")
        switch target.kind {
        case .movie:
            return isMovie ? 1200 : -10000
        case .episode:
            return isMovie ? -10000 : 0
        }
    }

    private static func rankBonus(rankIndex: Int) -> Int {
        max(0, 50 - rankIndex)
    }

    /// 从分集标题中提取集数（例如 "第01话 冒险的结束" -> 1, "02" -> 2, "第3集" -> 3）。
    /// 只认正片集数；特典（`S2`/`C1`）返回 nil，要判特典请用 `DanmakuEpisodeToken.parse`。
    public static func extractEpisodeNumber(from episodeTitle: String?) -> Int? {
        DanmakuEpisodeToken.parse(episodeTitle)?.numberValue
    }

    private static func characterOverlap(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        return Double(intersection * 2) / Double(setA.count + setB.count)
    }
}
