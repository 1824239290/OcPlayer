import BangumiKit
import CoreModel
import Foundation
import MetadataKit
import XCTest

@testable import OcPlayer

/// Bangumi 章节 → 占位候选的映射。
///
/// 这一层只做形状转换（改字段名、丢对不上的编号），策略在 `MetadataKit.EpisodeSlotBuilder`。
/// 之所以值得单独测：三条过滤（只收本篇 / `sort` 必须是整数 / `sort ≥ 1`）各自都能悄悄
/// 放一批错号的假卡片进轨道，而 `sort` 是 `Float`——漏了整数判定，特别篇的 8.5 会变成
/// 第 8 集，和真实的一集撞号。
final class EpisodePlaceholderTests: XCTestCase {

    private func episode(
        id: Int = 1,
        sort: Float,
        type: BangumiEpisodeType = .main,
        name: String = "EP",
        nameCN: String = "",
        airdate: String = "2026-10-11",
        desc: String? = nil
    ) -> BangumiEpisodeDTO {
        BangumiEpisodeDTO(
            id: id, subjectID: 100, type: type, sort: sort,
            name: name, nameCN: nameCN, duration: "24m", airdate: airdate,
            comment: 0, disc: 0, desc: desc)
    }

    /// 只收本篇：SP / OP / ED 的编号与 Jellyfin 的分集号不同源。
    func testOnlyMainEpisodesBecomeCandidates() {
        let candidates = EpisodePlaceholderSource.bangumiCandidates(from: [
            episode(id: 1, sort: 1),
            episode(id: 2, sort: 2, type: .sp),
            episode(id: 3, sort: 3, type: .op),
            episode(id: 4, sort: 4, type: .other),
            episode(id: 5, sort: 5),
        ])

        XCTAssertEqual(candidates.map(\.number), [1, 5])
    }

    /// `sort` 是 `Float`：小数编号是特别篇（8.5），不是第 8 集；0 / 负数不是集号。
    func testNonIntegralAndNonPositiveSortsAreDropped() {
        let candidates = EpisodePlaceholderSource.bangumiCandidates(from: [
            episode(id: 1, sort: 8.5),
            episode(id: 2, sort: 0),
            episode(id: 3, sort: -1),
            episode(id: 4, sort: 8),
        ])

        XCTAssertEqual(candidates.map(\.number), [8])
    }

    /// 标题优先中文名（`nameCN` 为空才用 `name`），空白串等同于没给。
    func testChineseTitleWinsAndWhitespaceCountsAsEmpty() {
        let candidates = EpisodePlaceholderSource.bangumiCandidates(from: [
            episode(id: 1, sort: 1, name: "Romaji", nameCN: "中文名"),
            episode(id: 2, sort: 2, name: "Romaji"),
            episode(id: 3, sort: 3, name: "Romaji", nameCN: "   "),
        ])

        XCTAssertEqual(candidates.map(\.title), ["中文名", "Romaji", "Romaji"])
    }

    /// 播出日期：能解析就带上，空串是 **nil（未知）**——不能当成「未播出」。
    func testAirDateIsPassedThroughAndUnknownStaysNil() {
        let candidates = EpisodePlaceholderSource.bangumiCandidates(from: [
            episode(id: 1, sort: 1, airdate: "2026-10-11"),
            episode(id: 2, sort: 2, airdate: ""),
            episode(id: 3, sort: 3, airdate: "待定"),
        ])

        XCTAssertNotNil(candidates[0].airDate)
        XCTAssertNil(candidates[1].airDate)
        XCTAssertNil(candidates[2].airDate)
    }

    /// Bangumi 没有剧照、时长是「24m」字符串 → 两个字段都留空，不猜。
    func testStillAndRuntimeAreNotInvented() {
        let candidates = EpisodePlaceholderSource.bangumiCandidates(from: [
            episode(id: 1, sort: 1, desc: "简介"),
        ])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates[0].stillPath)
        XCTAssertNil(candidates[0].runtimeSeconds)
        XCTAssertEqual(candidates[0].overview, "简介")
    }

    /// 空章节列表 → 空候选（区块在未关联 / 未登录时递上来的就是它）。
    func testEmptyInputProducesNoCandidates() {
        XCTAssertTrue(EpisodePlaceholderSource.bangumiCandidates(from: []).isEmpty)
    }
}
