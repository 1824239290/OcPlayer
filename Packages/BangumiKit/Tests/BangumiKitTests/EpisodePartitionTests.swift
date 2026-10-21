import Foundation
import Testing
@testable import BangumiKit

/// `P2-09`：详情页的三个章节分类改为**一次扫完**。
///
/// ## 背景
///
/// 原先三个独立 computed property 各含一次 `episodes.filter`，而 `episodesSection`
/// 一次 body 里把它们读了 **3–7 次**（不是「8 次」——外层 OR 会短路）：
///
/// | sp 空 | other 空 | 读取次数 | 说明 |
/// |---|---|---|---|
/// | ✓ | ✓ | **3** | 外层 2 次（OR 不短路）+ switch 1 次，不进 Picker |
/// | ✓ | ✗ | **5** | 外层 2 次 + Picker 2 次 + switch 1 次 |
/// | ✗ | ✓ | **6** | 外层 1 次（短路）+ Picker 4 次 + switch 1 次 |
/// | ✗ | ✗ | **7** | 外层 1 次 + Picker 5 次 + switch 1 次 |
///
/// 1000 集时一次 body 要扫 3000–7000 个元素、建同样多份临时数组（DTO 384 B），
/// 而 `body` 会因 `updatingEpisodeID` / `isLoading` 变化反复重算。
///
/// ## 这组测试守什么
///
/// 1. **逐条等价**：新分区 == 旧的三个 `filter` 表达式（**比整个元素，不是只比 id**）；
/// 2. **tab → 列表的映射**：`episodes(for:)` 必须接对（视图只转调它，接错编译器不报）；
/// 3. **顺序保持**：分类内部保持原数组顺序（夹具让 other 段**逆 rawValue**，
///    这样「整体按 type 排序」这类变异也能被抓住）；
/// 4. **七种 case 全覆盖**。
@Suite("Episode 分类分区")
struct EpisodePartitionTests {

    private func episode(
        _ id: Int, _ type: BangumiEpisodeType, name: String? = nil, sort: Float? = nil
    ) -> BangumiEpisodeDTO {
        BangumiEpisodeDTO(
            id: id, subjectID: 1, type: type, sort: sort ?? Float(id),
            name: name ?? "ep\(id)", nameCN: "第\(id)话",
            duration: "24m", airdate: "2026-01-01", comment: 0, disc: 0
        )
    }

    /// 旧的三个 filter（oracle，逐字复刻）。
    private func oracle(_ episodes: [BangumiEpisodeDTO]) -> (
        main: [BangumiEpisodeDTO], sp: [BangumiEpisodeDTO], other: [BangumiEpisodeDTO]
    ) {
        (
            episodes.filter { $0.type == .main },
            episodes.filter { $0.type == .sp },
            episodes.filter { $0.type != .main && $0.type != .sp }
        )
    }

    @Test("七种 case 全部正确分流")
    func allSevenCasesRouted() {
        let types = BangumiEpisodeType.allCases
        // 绊线：`expectedOther` 是动态算的，所以将来新增 case 时只有这条会提醒。
        #expect(types.count == 7, "BangumiEpisodeType 应有 7 个 case；新增了要重新确认分流规则")

        let episodes = types.enumerated().map { episode($0.offset, $0.element) }
        let parts = episodes.partitionedByEpisodeType()

        #expect(parts.main.map(\.type) == [.main])
        #expect(parts.sp.map(\.type) == [.sp])
        let expectedOther = types.filter { $0 != .main && $0 != .sp }
        #expect(parts.other.map(\.type) == expectedOther)
        #expect(parts.totalCount == episodes.count, "三条加总必须等于原数（不能漏条目）")
    }

    /// **比整个元素**（DTO 是 `Hashable`）。
    ///
    /// 只比 `.id` 的话，「拷贝后改字段」这类变异测不出来 —— 审查实测过。
    @Test("与旧的三个 filter 逐条等价（含全部字段）")
    func matchesLegacyFilters() {
        var rng = SeededGenerator(seed: 0x5EED_9ABC)
        let types = BangumiEpisodeType.allCases
        for _ in 0..<50 {
            let count = Int(rng.next() % 40)
            let episodes = (0..<count).map { index -> BangumiEpisodeDTO in
                let type = types[Int(rng.next() % UInt64(types.count))]
                return episode(index, type, name: "name-\(rng.next() % 100)")
            }
            let parts = episodes.partitionedByEpisodeType()
            let want = oracle(episodes)
            #expect(parts.main == want.main, "本篇元素不一致")
            #expect(parts.sp == want.sp, "SP 元素不一致")
            #expect(parts.other == want.other, "其他元素不一致")
        }
    }

    /// **tab → 列表的映射必须接对。**
    ///
    /// 视图只调 `parts.episodes(for: selectedEpisodeTab)`。这条守住映射本身 ——
    /// 若实现里把 `case .sp: main` 写错，这是唯一会红的地方
    /// （视图里接错类型相同，编译器不报）。
    @Test("tab → 列表的映射正确")
    func tabMappingIsCorrect() {
        let episodes: [BangumiEpisodeDTO] = [
            episode(1, .main), episode(2, .sp), episode(3, .op),
            episode(4, .main), episode(5, .ed), episode(6, .sp),
        ]
        let parts = episodes.partitionedByEpisodeType()

        #expect(parts.episodes(for: .main).map(\.id) == [1, 4])
        #expect(parts.episodes(for: .sp).map(\.id) == [2, 6])
        #expect(parts.episodes(for: .other).map(\.id) == [3, 5])

        // count / isEmpty 也要与 lists 一致（Picker 标题用的就是它们）。
        for tab in EpisodeTab.allCases {
            #expect(parts.count(for: tab) == parts.episodes(for: tab).count)
            #expect(parts.isEmpty(for: tab) == parts.episodes(for: tab).isEmpty)
        }
        #expect(EpisodeTab.main.title(count: 12) == "本篇 (12)")
        #expect(EpisodeTab.sp.title(count: 0) == "SP (0)")
    }

    /// **分类内部保持原数组顺序。**
    ///
    /// 夹具刻意让 other 段**逆 rawValue**（先 `.other`(6) 再 `.op`(2)）：
    /// 若实现改成「整体按 type 排序再分流」，这条会红。
    /// （上一版夹具在每类内部本来就是升序，那个变异可以存活 —— 审查实测指出。）
    @Test("每个分类内部保持原数组顺序")
    func preservesOrderWithinCategory() {
        let episodes: [BangumiEpisodeDTO] = [
            episode(1, .main), episode(2, .sp), episode(3, .other),
            episode(4, .main), episode(5, .op), episode(6, .sp),
            episode(7, .main), episode(8, .trailer), episode(9, .mad),
            episode(10, .ed), episode(11, .main),
        ]
        let parts = episodes.partitionedByEpisodeType()
        #expect(parts.main.map(\.id) == [1, 4, 7, 11])
        #expect(parts.sp.map(\.id) == [2, 6])
        // 顺序 = 出现顺序，**不是** rawValue 顺序（.other=6, .op=2, .trailer=4, .mad=5, .ed=3）。
        #expect(parts.other.map(\.id) == [3, 5, 8, 9, 10])
    }

    @Test("空数组与单一分类")
    func edgeCases() {
        let empty = [BangumiEpisodeDTO]().partitionedByEpisodeType()
        #expect(empty.main.isEmpty && empty.sp.isEmpty && empty.other.isEmpty)
        #expect(empty.totalCount == 0)

        let onlyMain = (0..<5).map { episode($0, .main) }
        let parts = onlyMain.partitionedByEpisodeType()
        #expect(parts.main.count == 5)
        #expect(parts.sp.isEmpty)
        #expect(parts.other.isEmpty)
        #expect(parts.episodes(for: .main).count == 5)
    }

    @Test("大输入（1000 集）结果与顺序都对")
    func largeInput() {
        let types = BangumiEpisodeType.allCases
        let episodes = (0..<1000).map { episode($0, types[$0 % types.count]) }
        let parts = episodes.partitionedByEpisodeType()
        let want = oracle(episodes)
        #expect(parts.main == want.main)
        #expect(parts.sp == want.sp)
        #expect(parts.other == want.other)
        #expect(parts.totalCount == 1000)
    }
}

/// 固定种子 LCG：用例必须可复现。
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
