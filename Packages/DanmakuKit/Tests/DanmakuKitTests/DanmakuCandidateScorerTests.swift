import XCTest
@testable import DanmakuKit

final class DanmakuCandidateScorerTests: XCTestCase {

    func testEpisodeExtraction() {
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "第1话 冒险的结束"), 1)
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "第02话"), 2)
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "第3集"), 3)
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "04 某某"), 4)
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "05"), 5)
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "EP06"), 6)
        XCTAssertEqual(DanmakuCandidateScorer.extractEpisodeNumber(from: "第十二话"), 12)
    }

    func testEpisodeMatchAndMismatchScoring() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "葬送的芙莉莲",
            episodeNumber: 2,
            seasonNumber: 1
        )

        // 精准命中：集数一致，标题一致
        let scoreHit = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "葬送的芙莉莲",
            episodeTitle: "第2话 没用的魔法",
            target: target
        )
        XCTAssertGreaterThanOrEqual(scoreHit, DanmakuCandidateScorer.confidenceThreshold)

        // 集数冲突：目标第2集，候选第3集
        let scoreConflict = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "葬送的芙莉莲",
            episodeTitle: "第3话",
            target: target
        )
        XCTAssertLessThan(scoreConflict, DanmakuCandidateScorer.confidenceThreshold)
    }

    func testSeasonConsistencyScoring() {
        let targetS2 = DanmakuCandidateScorer.TargetContext(
            animeTitle: "进击的巨人",
            episodeNumber: 1,
            seasonNumber: 2
        )

        // 目标第二季，候选为第二季第一集
        let scoreS2 = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "进击的巨人 第二季",
            episodeTitle: "第1话",
            target: targetS2
        )
        XCTAssertGreaterThanOrEqual(scoreS2, DanmakuCandidateScorer.confidenceThreshold)

        // 目标第二季，候选为第一季
        let scoreS1 = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "进击的巨人",
            episodeTitle: "第1话",
            target: targetS2
        )
        XCTAssertLessThan(scoreS1, scoreS2)
    }

    func testPickBestCandidateFromMatches() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "葬送的芙莉莲",
            episodeNumber: 2
        )

        let candidates = [
            MatchResponse.Match(
                episodeId: 101,
                animeId: 1,
                animeTitle: "葬送的芙莉莲",
                episodeTitle: "第1话",
                type: nil,
                typeDescription: nil,
                shift: 0,
                fileName: nil,
                fileSize: nil,
                hash: nil
            ),
            MatchResponse.Match(
                episodeId: 102,
                animeId: 1,
                animeTitle: "葬送的芙莉莲",
                episodeTitle: "第2话",
                type: nil,
                typeDescription: nil,
                shift: 0,
                fileName: nil,
                fileSize: nil,
                hash: nil
            ),
        ]

        let best = DanmakuCandidateScorer.pickBestMatch(from: candidates, target: target)
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.match.episodeID, 102)
    }

    func testPickBestEpisodeFromSearchResults() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "进击的巨人",
            episodeNumber: 3,
            seasonNumber: 2
        )

        let animes = [
            AnimeWithEpisodes(
                animeId: 1,
                animeTitle: "进击的巨人",
                type: "tvseries",
                typeDescription: "动画",
                episodes: [
                    Episode(episodeId: 1, episodeTitle: "第1话"),
                    Episode(episodeId: 2, episodeTitle: "第2话"),
                    Episode(episodeId: 3, episodeTitle: "第3话")
                ]
            ),
            AnimeWithEpisodes(
                animeId: 2,
                animeTitle: "进击的巨人 第二季",
                type: "tvseries",
                typeDescription: "动画",
                episodes: [
                    Episode(episodeId: 201, episodeTitle: "第1话"),
                    Episode(episodeId: 202, episodeTitle: "第2话"),
                    Episode(episodeId: 203, episodeTitle: "第3话")
                ]
            )
        ]

        let best = DanmakuCandidateScorer.pickBestEpisode(from: animes, target: target)
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.match.episodeID, 203)
        XCTAssertEqual(best?.match.animeTitle, "进击的巨人 第二季")
    }

    // MARK: 特典命名空间（S/C/O）

    /// 回归：特典候选（`S5 聖地巡礼`）不得被当成第 5 话——它的序号 5 与正片集号
    /// 无关，曾经靠「标题里含 5」的宽松兜底命中。
    func testSpecialCandidateDoesNotMatchPlainEpisode() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "败犬女主太多了！",
            episodeNumber: 5,
            seasonNumber: 1
        )
        let special = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "败犬女主太多了！",
            episodeTitle: "S5 聖地巡礼企画『負けヒロインに会いに来た!』#4",
            target: target
        )
        XCTAssertLessThan(special, DanmakuCandidateScorer.confidenceThreshold)

        // 正片候选仍然稳过阈值，特典抢不走它。
        let episode = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "败犬女主太多了！",
            episodeTitle: "第5话 朝云千早使人迷惑",
            target: target
        )
        XCTAssertGreaterThanOrEqual(episode, DanmakuCandidateScorer.confidenceThreshold)
        XCTAssertGreaterThan(episode, special)
    }

    /// 特典目标：序号相同即命中，命名空间按偏好顺序给分（Jellyfin season 0 分不出 S/C/O）。
    func testSpecialTargetPrefersPreferredNamespace() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "来玩游戏吧",
            episodeNumber: 2,
            seasonNumber: 0,
            special: DanmakuSpecialTarget(index: 2, kinds: DanmakuSpecialKind.fallbackOrder)
        )
        let special = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "来玩游戏吧", episodeTitle: "S2 アームストロング", target: target)
        let extra = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "来玩游戏吧", episodeTitle: "C2 Ending", target: target)
        let wrongIndex = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "来玩游戏吧", episodeTitle: "S3 某某", target: target)

        XCTAssertGreaterThanOrEqual(special, DanmakuCandidateScorer.confidenceThreshold)
        XCTAssertGreaterThanOrEqual(extra, DanmakuCandidateScorer.confidenceThreshold)
        XCTAssertGreaterThan(special, extra, "首选命名空间应高于兜底命名空间")
        XCTAssertLessThan(wrongIndex, DanmakuCandidateScorer.confidenceThreshold, "序号不符不通过")
    }

    /// 命名空间由文件名关键词确定时（NCOP → C），首选就是它。
    func testSpecialTargetWithKnownNamespace() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "碧蓝之海",
            episodeNumber: 1,
            seasonNumber: 0,
            special: DanmakuSpecialTarget(index: 1, kinds: [.extra])
        )
        let extra = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "碧蓝之海", episodeTitle: "C1 Opening", target: target)
        let other = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "碧蓝之海", episodeTitle: "O1 Warning", target: target)
        XCTAssertGreaterThanOrEqual(extra, DanmakuCandidateScorer.confidenceThreshold)
        XCTAssertGreaterThan(extra, other)
    }

    /// OVA/OAD 常被弹弹play 编成同作品的正片「第 N 话」：season 0 的特典目标遇到同序号的
    /// 正片候选仍应可通过，但排在真正的特典候选之后。
    func testSpecialTargetAcceptsSameIndexNumberedEpisodeAsFallback() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "来玩游戏吧",
            episodeNumber: 1,
            seasonNumber: 0,
            special: DanmakuSpecialTarget(index: 1, kinds: [.special])
        )
        let numbered = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "来玩游戏吧 OVA", episodeTitle: "第1话 OAD", target: target)
        let otherNumber = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "来玩游戏吧 OVA", episodeTitle: "第2话", target: target)
        let special = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "来玩游戏吧", episodeTitle: "S1 特典影像", target: target)

        XCTAssertGreaterThanOrEqual(numbered, DanmakuCandidateScorer.confidenceThreshold)
        XCTAssertLessThan(otherNumber, DanmakuCandidateScorer.confidenceThreshold)
        XCTAssertGreaterThan(special, numbered, "真正的特典候选优先于同序号正片")
    }

    /// 回归（用户实报）：中二病 S00E29 特典曾被同 IP 剧场版的 S29 特典抢走——
    /// 序号命中 +2000、标题包含 +666，旧软惩罚 -1500 压不住。类型不匹配必须直接判死。
    func testTypeGateRejectsMovieCandidateForSpecialTarget() {
        let target = DanmakuCandidateScorer.TargetContext(
            animeTitle: "中二病也要谈恋爱!",
            episodeNumber: 29,
            seasonNumber: 0,
            special: DanmakuSpecialTarget(index: 29, kinds: DanmakuSpecialKind.fallbackOrder))
        let score = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "剧场版 中二病也要谈恋爱！ -Take On Me- ",
            episodeTitle: "S29 映画公開記念! 暗黒謝肉祭!",
            typeDescription: "剧场版", type: "movie",
            target: target)
        XCTAssertLessThan(score, DanmakuCandidateScorer.confidenceThreshold,
                          "剧场版候选必须出局，纵使序号与标题都沾边")
    }

    // MARK: 作品类型

    func testMovieAndEpisodeAreMutuallyExclusive() {
        let episodeTarget = DanmakuCandidateScorer.TargetContext(
            animeTitle: "某作品", episodeNumber: 1, seasonNumber: 1)
        let movieTarget = DanmakuCandidateScorer.TargetContext(
            animeTitle: "某作品", kind: .movie)

        let movieCandidate = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "某作品", episodeTitle: "剧场版", typeDescription: "剧场版", target: episodeTarget)
        XCTAssertLessThan(movieCandidate, DanmakuCandidateScorer.confidenceThreshold)

        let tvCandidateForMovie = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "某作品", episodeTitle: "第1话", typeDescription: "TV动画", target: movieTarget)
        let movieForMovie = DanmakuCandidateScorer.scoreCandidate(
            animeTitle: "某作品", episodeTitle: "剧场版", typeDescription: "剧场版", target: movieTarget)
        XCTAssertGreaterThan(movieForMovie, tvCandidateForMovie)
    }
}
