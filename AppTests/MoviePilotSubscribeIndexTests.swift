import MoviePilotKit
import XCTest

@testable import OcPlayer

/// `P2-13`：`MoviePilotHomeView.SubscribedIndex` 与旧的逐行 O(M) 扫描语义等价。
///
/// ## 为什么需要这组用例
///
/// 旧实现是「每行一次 `subscribes.contains { 4 个字段挨个比 }`」—— 正确但 O(R×M)。
/// 新实现建 4 个 `Set` 后每行 O(1)。**这类「扫描改索引」的重构最容易在边界上跑偏**：
/// - `nil` 与 `nil` 相等吗？（旧实现要求两侧都非 nil）
/// - 4 个字段是「任一相等」还是「全部相等」？
/// - 本地 id 优先吗？
///
/// 所以这里逐条钉住，并用**同一份数据同时跑新旧两种实现**对照。
final class MoviePilotSubscribeIndexTests: XCTestCase {

    // MARK: - 夹具

    private func media(
        id: String = "m-1",
        tmdb: Int? = nil,
        douban: String? = nil,
        bangumi: Int? = nil,
        title: String? = nil
    ) -> MPMediaInfo {
        var raw: [String: JSONValue] = ["media_id": .string(id)]
        if let tmdb { raw["tmdb_id"] = .number(Double(tmdb)) }
        if let douban { raw["douban_id"] = .string(douban) }
        if let bangumi { raw["bangumi_id"] = .number(Double(bangumi)) }
        if let title { raw["title"] = .string(title) }
        return MPMediaInfo(raw: raw)
    }

    private func subscribe(
        tmdb: Int? = nil,
        douban: String? = nil,
        bangumi: Int? = nil,
        name: String? = nil
    ) -> MPSubscribe {
        var raw: [String: JSONValue] = ["id": .string(UUID().uuidString)]
        if let tmdb { raw["tmdb_id"] = .number(Double(tmdb)) }
        if let douban { raw["douban_id"] = .string(douban) }
        if let bangumi { raw["bangumi_id"] = .number(Double(bangumi)) }
        if let name { raw["name"] = .string(name) }
        return MPSubscribe(raw: raw)
    }

    /// **旧实现**（逐行 O(M) 扫描）—— 用作对照基准，逐字照抄改动前的代码。
    private func legacyIsSubscribed(
        _ media: MPMediaInfo,
        subscribes: [MPSubscribe],
        localIDs: Set<String>
    ) -> Bool {
        if localIDs.contains(media.id) { return true }
        return subscribes.contains { sub in
            if let subTmdb = sub.tmdbId, let mediaTmdb = media.tmdbId, subTmdb == mediaTmdb {
                return true
            }
            if let subDouban = sub.doubanId, let mediaDouban = media.doubanId, subDouban == mediaDouban {
                return true
            }
            if let subBgm = sub.bangumiId, let mediaBgm = media.bangumiId, subBgm == mediaBgm {
                return true
            }
            if let subName = sub.name, let mediaTitle = media.title, subName == mediaTitle {
                return true
            }
            return false
        }
    }

    private func index(
        _ subscribes: [MPSubscribe],
        localIDs: Set<String> = []
    ) -> MoviePilotHomeView.SubscribedIndex {
        MoviePilotHomeView.SubscribedIndex(subscribes: subscribes, localIDs: localIDs)
    }

    // MARK: - 逐字段语义

    func testLocalIDHitCounts() {
        let idx = index([], localIDs: ["m-1"])
        XCTAssertTrue(idx.contains(media(id: "m-1")), "本地 id 命中即算已订阅")
        XCTAssertFalse(idx.contains(media(id: "m-2")))
    }

    func testTmdbMatch() {
        let idx = index([subscribe(tmdb: 603)])
        XCTAssertTrue(idx.contains(media(tmdb: 603)))
        XCTAssertFalse(idx.contains(media(tmdb: 604)))
    }

    func testDoubanMatch() {
        let idx = index([subscribe(douban: "1234567")])
        XCTAssertTrue(idx.contains(media(douban: "1234567")))
        XCTAssertFalse(idx.contains(media(douban: "7654321")))
    }

    func testBangumiMatch() {
        let idx = index([subscribe(bangumi: 400602)])
        XCTAssertTrue(idx.contains(media(bangumi: 400602)))
        XCTAssertFalse(idx.contains(media(bangumi: 400603)))
    }

    func testTitleMatch() {
        let idx = index([subscribe(name: "沙丘")])
        XCTAssertTrue(idx.contains(media(title: "沙丘")))
        XCTAssertFalse(idx.contains(media(title: "沙丘2")), "片名必须完全相同，不是包含")
    }

    /// **`nil` 与 `nil` 不算匹配。**
    ///
    /// 旧实现用 `if let ... , if let ... ==`，两侧都必须非 nil 才比较。
    /// 若索引把「缺失字段」当成某个默认值收进去，就会出现「所有无 tmdb 的媒体
    /// 都算已订阅」这种灾难性误判 —— 这条专门防它。
    func testNilFieldsNeverMatchEachOther() {
        let noIDSubscribe = subscribe()          // 四个字段全 nil
        let noIDMedia = media()                  // 四个字段全 nil
        let idx = index([noIDSubscribe])
        XCTAssertFalse(idx.contains(noIDMedia),
                       "两侧都缺字段时不该判为已订阅（旧实现要求两侧非 nil）")
    }

    /// 只差一个字段也要能命中（任一字段相等即可，不是「全部相等」）。
    func testAnySingleFieldMatchIsEnough() {
        let sub = subscribe(tmdb: 603, douban: "111", bangumi: 222, name: "沙丘")
        let idx = index([sub])
        // 每条媒体只带其中一个字段，且与订阅相同。
        XCTAssertTrue(idx.contains(media(tmdb: 603)), "仅 tmdb 相同就该命中")
        XCTAssertTrue(idx.contains(media(douban: "111")), "仅 douban 相同就该命中")
        XCTAssertTrue(idx.contains(media(bangumi: 222)), "仅 bangumi 相同就该命中")
        XCTAssertTrue(idx.contains(media(title: "沙丘")), "仅片名相同就该命中")
    }

    // MARK: - 与新实现逐条对照

    /// **穷举对照**：构造一批覆盖各种组合的订阅与媒体，逐个比较新旧实现。
    ///
    /// 这是本组用例的核心 —— 不依赖我手写的「应该是什么」，而是**用旧实现当 oracle**。
    func testMatchesLegacyImplementationOnMixedFixture() {
        let subscribes: [MPSubscribe] = [
            subscribe(tmdb: 1, name: "A"),
            subscribe(douban: "2", name: "B"),
            subscribe(bangumi: 3, name: "C"),
            subscribe(name: "D"),
            subscribe(),                                 // 全空
            subscribe(tmdb: 1, douban: "2", bangumi: 3, name: "A"),  // 与第一条重叠
        ]
        let medias: [MPMediaInfo] = [
            media(id: "x", tmdb: 1),
            media(id: "y", tmdb: 2),
            media(id: "z", douban: "2"),
            media(id: "w", bangumi: 3),
            media(id: "v", title: "D"),
            media(id: "u", title: "E"),
            media(id: "t"),                              // 全空
            media(id: "s", tmdb: 1, douban: "2", bangumi: 3, title: "A"),
        ]
        let localIDs: Set<String> = ["s"]

        let idx = index(subscribes, localIDs: localIDs)
        for media in medias {
            let legacy = legacyIsSubscribed(media, subscribes: subscribes, localIDs: localIDs)
            XCTAssertEqual(
                idx.contains(media), legacy,
                "媒体 \(media.id) 的新旧判定不一致（新=\(idx.contains(media)) 旧=\(legacy)）")
        }
    }

    /// **大小写必须区别对待**（旧实现是精确等值，不是 `lowercased` 比较）。
    ///
    /// 审查实测：把索引与查询都改成 `.lowercased()`，9 条用例**全绿** ——
    /// 因为 fixture 里没有「只差大小写」的样本。这条补上。
    func testTitleMatchIsCaseSensitive() {
        let idx = index([subscribe(name: "Dune")])
        XCTAssertFalse(idx.contains(media(title: "dune")),
                       "旧实现是精确等值，大小写不同不该命中")
        XCTAssertTrue(idx.contains(media(title: "Dune")))
    }

    /// 空串：两侧都是 `""` 时旧实现会命中（`if let` 对空串也为真）。
    ///
    /// 这条钉住「不要为过滤空串而引入额外判据」—— 那会偏离旧行为。
    func testEmptyStringTitleMatchesLikeLegacy() {
        let subscribes = [subscribe(name: "")]
        let idx = index(subscribes)
        let emptyTitleMedia = media(title: "")
        XCTAssertEqual(
            idx.contains(emptyTitleMedia),
            legacyIsSubscribed(emptyTitleMedia, subscribes: subscribes, localIDs: []),
            "空串判定必须与旧实现一致")
    }

    /// 订阅侧只有 `title` 字段（`name` 缺失）时，`MPSubscribe.name` 会回退到 `raw["title"]`。
    func testSubscribeNameFallsBackToTitleField() {
        var raw: [String: JSONValue] = ["id": .string(UUID().uuidString)]
        raw["title"] = .string("沙丘")
        let sub = MPSubscribe(raw: raw)
        let idx = index([sub])
        XCTAssertTrue(idx.contains(media(title: "沙丘")),
                      "订阅侧只有 title 时应回退到它（MPSubscribe.name 的实现）")
    }

    /// 重复订阅值不该影响布尔结果。
    func testDuplicateSubscribesDoNotChangeResult() {
        let subscribes = [subscribe(tmdb: 1), subscribe(tmdb: 1), subscribe(tmdb: 1)]
        XCTAssertTrue(index(subscribes).contains(media(tmdb: 1)))
        XCTAssertFalse(index(subscribes).contains(media(tmdb: 2)))
    }

    /// 空订阅表：任何媒体都不该判为已订阅（除本地 id）。
    func testEmptySubscribes() {
        let idx = index([])
        XCTAssertFalse(idx.contains(media(tmdb: 1)))
        XCTAssertFalse(idx.contains(media()))
        let withLocal = index([], localIDs: ["m-1"])
        XCTAssertTrue(withLocal.contains(media(id: "m-1")))
    }
}
