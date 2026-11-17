import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 「每三十集一个分区」的纯分段策略。
///
/// 这一层只有两件事要钉死：**切点**（每 size 条一段、保序不丢格）与**标签**
/// （段内首尾实际集号；整段无编号才退回位置号）。两者都是详情页直接渲染的东西，
/// 错一格就会让用户按着标签去找一部并不存在的集。
final class EpisodeChunkTests: XCTestCase {

    // MARK: - 夹具

    private func local(_ number: Int?) -> EpisodeSlot {
        .local(makeItem(
            id: "ep-\(number.map(String.init) ?? UUID().uuidString)",
            name: "第 \(number ?? 0) 集",
            kind: .episode,
            episodeNumber: number))
    }

    private func placeholder(_ number: Int, aired: Bool = true) -> EpisodeSlot {
        .placeholder(EpisodePlaceholder(
            number: number,
            seasonNumber: 1,
            reason: aired ? .notInLibrary : .notAired))
    }

    private func locals(_ numbers: ClosedRange<Int>) -> [EpisodeSlot] {
        numbers.map { local($0) }
    }

    private func ids(_ slots: [EpisodeSlot]) -> [String] { slots.map(\.id) }

    // MARK: - 切点

    func testEmptyTrackProducesNoChunks() {
        // 空轨道不该造出一个空段——空段会让分区条上多出一颗点不动的胶囊。
        XCTAssertTrue(EpisodeChunker.chunk([]).isEmpty)
    }

    /// 30 集（含）以内只有一段：详情页因此不显示分区条，普通季的观感与改动前一致。
    func testOneChunkAtOrBelowSize() {
        XCTAssertEqual(EpisodeChunker.chunk(locals(1...30)).count, 1)
        XCTAssertEqual(EpisodeChunker.chunk(locals(1...12)).count, 1)
        XCTAssertEqual(EpisodeChunker.chunk(locals(1...30))[0].rangeLabel, "1-30")
    }

    /// 61 集 = 30 + 30 + 1：尾段只剩一集，标签只写一个号（「61」而不是「61-61」）。
    func testBoundariesAndSingleEpisodeTailLabel() {
        let chunks = EpisodeChunker.chunk(locals(1...61))

        XCTAssertEqual(chunks.map(\.rangeLabel), ["1-30", "31-60", "61"])
        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(chunks.map { $0.slots.count }, [30, 30, 1])
    }

    /// 换 size（含非法值）时行为稳定：≤0 不该切出空段，空轨道恒为空。
    func testCustomSizeAndNonPositiveSize() {
        let chunks = EpisodeChunker.chunk(locals(1...25), size: 10)
        XCTAssertEqual(chunks.map(\.rangeLabel), ["1-10", "11-20", "21-25"])
        XCTAssertTrue(EpisodeChunker.chunk(locals(1...25), size: 0).isEmpty)
        XCTAssertTrue(EpisodeChunker.chunk(locals(1...25), size: -3).isEmpty)
    }

    /// 保序、不丢格：分区只是换个看法，轨道的顺序与内容必须逐位一致
    /// （详情页拿 `flatMap(\.slots)` 之外的任何东西渲染都是错的）。
    func testChunksCoverEverySlotInOrder() {
        let slots = locals(1...61)
        XCTAssertEqual(ids(EpisodeChunker.chunk(slots).flatMap(\.slots)), ids(slots))
    }

    // MARK: - 标签

    /// 占位（未播出 / 未入库）也是轨道里的一格，集号同样进标签——它们正是长番
    /// 「库里还没收全」时最需要被分区导航看见的部分。
    func testPlaceholderNumbersCountTowardLabel() {
        let slots = locals(1...28) + [placeholder(29), placeholder(30, aired: false)] + locals(31...40)
        let chunks = EpisodeChunker.chunk(slots)

        XCTAssertEqual(chunks.map(\.rangeLabel), ["1-30", "31-40"])
        XCTAssertEqual(chunks[0].slots.count, 30)
        XCTAssertEqual(chunks[0].lastNumber, 30)
    }

    /// 段内一个集号都没有（服务端没给 `IndexNumber`）时退回**轨道位置号**：
    /// 标签仍是可读的「61-62」，而不是「0-0」或空白。
    func testUnnumberedTailFallsBackToTrackPositions() {
        let slots = locals(1...60) + [local(nil), local(nil)]
        let chunks = EpisodeChunker.chunk(slots)

        XCTAssertEqual(chunks.map(\.rangeLabel), ["1-30", "31-60", "61-62"])
        XCTAssertEqual(chunks[2].firstNumber, 61)
        XCTAssertEqual(chunks[2].lastNumber, 62)
    }

    /// 段内**部分**条目没编号：标签仍按实际存在的首尾集号走（不因为首格缺号就整段退回位置号）。
    func testPartlyUnnumberedChunkKeepsRealNumberBounds() {
        let slots = locals(1...30) + [local(nil), local(32)]
        let chunks = EpisodeChunker.chunk(slots)

        XCTAssertEqual(chunks[1].firstNumber, 32)
        XCTAssertEqual(chunks[1].lastNumber, 32)
        XCTAssertEqual(chunks[1].rangeLabel, "32")
    }

    /// 输入乱序时的兜底：`EpisodeSlotBuilder` 本来就会按集号排，但真被乱序喂进来时
/// 标签也必须写成「31-60」，而不是倒挂的「60-31」（`numbers.min()/max()` 而非 first/last）。
    func testLabelBoundsAreOrderIndependent() {
        let chunk = EpisodeChunker.chunk([local(60), local(31), local(45)])[0]

        XCTAssertEqual(chunk.rangeLabel, "31-60")
        XCTAssertEqual(chunk.accessibilityLabel, "第 31 到 60 集")
    }

    /// VoiceOver 文案与胶囊文案同源：单集段说「第 61 集」，区间段说「第 1 到 30 集」。
    func testAccessibilityLabelMatchesRange() {
        let chunks = EpisodeChunker.chunk(locals(1...61))

        XCTAssertEqual(chunks[0].accessibilityLabel, "第 1 到 30 集")
        XCTAssertEqual(chunks[2].accessibilityLabel, "第 61 集")
    }

    // MARK: - 分区浏览状态（视图只剩接线的那一半）

    /// 手点过的分区优先；但它一旦越界（换季那一帧新轨道还没到位）就必须被忽略，
    /// 退回跟随选中集——不能拿旧下标硬切新轨道。
    func testBrowsedChunkWinsAndOutOfRangeBrowsedChunkIsIgnored() {
        let chunks = EpisodeChunker.chunk(locals(1...95)) // 0…3 共四段

        XCTAssertEqual(
            EpisodeChunkNavigation(browsedIndex: 2)
                .activeIndex(in: chunks, selectedEpisodeID: "ep-1", ascending: true),
            2)
        XCTAssertEqual(
            EpisodeChunkNavigation(browsedIndex: 9)
                .activeIndex(in: chunks, selectedEpisodeID: "ep-1", ascending: true),
            0,
            "越界的手点分区要忽略，跟随选中集（ep-1 在第 0 段）")
    }

    /// 跟随选中集：本地条目与**占位**都要能定位——长番当前集常常正是库里还没有的那一集。
    func testFollowsSelectionIncludingPlaceholders() {
        let chunks = EpisodeChunker.chunk(locals(1...30) + [placeholder(31)] + locals(32...95))
        let nav = EpisodeChunkNavigation()

        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: "ep-35", ascending: true), 1)
        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: "placeholder.s1.e31", ascending: true), 1)
        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: "ep-64", ascending: true), 2)
    }

    /// 还没有选中集时落在**第一个展示出来的**分区：正序是第 0 段，倒序是最后一段。
    /// 空轨道返回 0（视图此时整块走空态，不会用到）。
    func testNoSelectionFallsBackToFirstDisplayedChunk() {
        let chunks = EpisodeChunker.chunk(locals(1...61))
        let nav = EpisodeChunkNavigation()

        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: nil, ascending: true), 0)
        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: nil, ascending: false), 2)
        XCTAssertEqual(nav.activeIndex(in: [], selectedEpisodeID: nil, ascending: true), 0)
    }

    /// 倒序时段序整体反：标签区间不动，只是从最后一段开始显示。
    func testDisplayedChunksFollowSortDirection() {
        let chunks = EpisodeChunker.chunk(locals(1...61))
        let nav = EpisodeChunkNavigation()

        XCTAssertEqual(nav.displayedChunks(chunks, ascending: true).map(\.index), [0, 1, 2])
        XCTAssertEqual(nav.displayedChunks(chunks, ascending: false).map(\.index), [2, 1, 0])
        XCTAssertEqual(nav.displayedChunks(chunks, ascending: false).map(\.rangeLabel),
                       ["61", "31-60", "1-30"])
    }

    /// 轨道只渲染当前分区的格子；倒序时段内也反；区间号越界（换季那一帧）返回空。
    func testRailSlotsRespectSortAndBounds() {
        let chunks = EpisodeChunker.chunk(locals(1...35))
        let nav = EpisodeChunkNavigation()

        XCTAssertEqual(
            nav.railSlots(in: chunks, activeIndex: 1, ascending: true).map(\.id),
            (31...35).map { "ep-\($0)" })
        XCTAssertEqual(
            nav.railSlots(in: chunks, activeIndex: 1, ascending: false).map(\.id),
            (31...35).reversed().map { "ep-\($0)" })
        XCTAssertTrue(nav.railSlots(in: chunks, activeIndex: 7, ascending: true).isEmpty)
    }

    /// `followSelection()` 清掉手点意图：段内点卡时调用它，`activeIndex` 前后同值
    /// （新选中集就在当前段里），但下一个选中集若落在别的段就能立刻跟上。
    func testFollowSelectionClearsBrowsedChunk() {
        let chunks = EpisodeChunker.chunk(locals(1...95))
        var nav = EpisodeChunkNavigation(browsedIndex: 2)

        nav.followSelection()
        XCTAssertNil(nav.browsedIndex)
        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: "ep-64", ascending: true), 2)
        XCTAssertEqual(nav.activeIndex(in: chunks, selectedEpisodeID: "ep-1", ascending: true), 0)
    }
}
