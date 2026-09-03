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
}
