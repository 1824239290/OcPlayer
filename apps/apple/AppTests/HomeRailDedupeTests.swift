import CoreModel
@testable import OcPlayer
import XCTest

/// 首页「继续观看」×「接下来看」去重：半集会被 Resume 与 NextUp 同时返回。
final class HomeRailDedupeTests: XCTestCase {
    private func episode(_ id: String, series: String) -> MediaItem {
        MediaItem(id: id, name: "\(series) 的一集", kind: .episode, seriesID: series, seriesName: series)
    }

    func testHalfWatchedEpisodeRemovedFromNextUp() {
        let resume = [episode("e3", series: "剧A")]
        let nextUp = [episode("e3", series: "剧A"), episode("e5", series: "剧B")]

        let result = AppModel.deduplicatedNextUp(nextUp, resume: resume)

        XCTAssertEqual(result.map(\.id), ["e5"])
    }

    func testNoOverlapKeepsNextUpIntact() {
        let resume = [episode("e3", series: "剧A")]
        let nextUp = [episode("e5", series: "剧B"), episode("e7", series: "剧C")]

        let result = AppModel.deduplicatedNextUp(nextUp, resume: resume)

        XCTAssertEqual(result.map(\.id), ["e5", "e7"])
    }

    func testEmptyResumeKeepsNextUpIntact() {
        let nextUp = [episode("e5", series: "剧B")]

        XCTAssertEqual(AppModel.deduplicatedNextUp(nextUp, resume: []).map(\.id), ["e5"])
    }

    func testEmptyNextUpStaysEmpty() {
        let resume = [episode("e3", series: "剧A")]

        XCTAssertTrue(AppModel.deduplicatedNextUp([], resume: resume).isEmpty)
    }

    func testSameIDDifferentKindStillDeduplicated() {
        // 条目 id 在服务端唯一，id 相同即同一条目，与 kind 无关。
        let resume = [MediaItem(id: "e3", name: "同一条目", kind: .movie)]
        let nextUp = [MediaItem(id: "e3", name: "同一条目", kind: .episode)]

        XCTAssertTrue(AppModel.deduplicatedNextUp(nextUp, resume: resume).isEmpty)
    }

    func testDuplicatesWithinNextUpSurviveWhenNotInResume() {
        // 去重只管 resume 交集，不改动 nextUp 自身的顺序与内容。
        let resume = [episode("e3", series: "剧A")]
        let nextUp = [episode("e5", series: "剧B"), episode("e5", series: "剧B")]

        let result = AppModel.deduplicatedNextUp(nextUp, resume: resume)

        XCTAssertEqual(result.count, 2)
    }
}
