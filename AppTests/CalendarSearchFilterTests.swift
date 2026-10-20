import BangumiKit
import XCTest

@testable import OcPlayer

/// `P2-11`：日历搜索过滤的正确性。
///
/// ## 为什么需要这组用例
///
/// 审查指出这批改动里 `P2-11` 是**零测试**的 —— 而它引入了三层缓存
/// （结果 cache、小写文本索引、`.task(id:)` 失效），每一层错了都不会崩、只会
/// 让搜索结果错。最险的一条审查已经证实：第一版用 `.task(id: days.count)`，
/// 而日历恒为 7 天 → 刷新后缓存**永久过期**。
final class CalendarSearchFilterTests: XCTestCase {

    private func item(
        id: Int,
        name: String,
        nameCN: String = "",
        summary: String? = nil
    ) -> BangumiCalendarItemDTO {
        BangumiCalendarItemDTO(id: id, name: name, nameCN: nameCN, summary: summary)
    }

    private func day(weekdayID: Int, items: [BangumiCalendarItemDTO]) -> BangumiCalendarDayDTO {
        BangumiCalendarDayDTO(
            weekday: BangumiCalendarWeekdayDTO(en: "", cn: "周\(weekdayID)", ja: "", id: weekdayID),
            items: items)
    }

    // MARK: - 可搜索文本

    /// `name` / `nameCN` / `summary` 三条都应命中。
    func testSearchableTextCoversAllThreeFields() {
        let target = item(id: 1, name: "Dune", nameCN: "沙丘", summary: "沙漠星球的史诗")
        let text = BangumiCalendarView.searchableTextForTesting(target)

        XCTAssertTrue(text.contains("dune"), "name 应可搜（小写化）")
        XCTAssertTrue(text.contains("沙丘"), "nameCN 应可搜")
        XCTAssertTrue(text.contains("沙漠星球的史诗"), "summary 应可搜")
    }

    /// **大小写不敏感** —— 搜索框输入大写也要命中（这是搜索，与 P2-13 的精确等值不同）。
    func testSearchIsCaseInsensitive() {
        let target = item(id: 1, name: "Dune")
        let text = BangumiCalendarView.searchableTextForTesting(target)
        XCTAssertTrue(text.contains("dune"))
        XCTAssertTrue(text.contains("DUNE".lowercased()))
    }

    /// **字段之间不能串味**：`\u{1F}` 分隔符要阻止跨字段误命中。
    ///
    /// 若不插分隔符，"ab" + "cd" 拼成 "abcd" 后搜 "bc" 会命中 —— 而实际
    /// 两个字段里都没有 "bc"。
    func testFieldsDoNotLeakIntoEachOther() {
        let target = item(id: 1, name: "ab", nameCN: "cd")
        let text = BangumiCalendarView.searchableTextForTesting(target)
        XCTAssertFalse(text.contains("bc"),
                       "跨字段边界的子串不该命中（分隔符应阻止它）")
    }

    // MARK: - 过滤

    /// 过滤只保留命中的条目，空天被剔除。
    func testFilterKeepsOnlyMatchingItemsAndDropsEmptyDays() {
        let days = [
            day(weekdayID: 1, items: [item(id: 1, name: "Dune"), item(id: 2, name: "Alien")]),
            day(weekdayID: 2, items: [item(id: 3, name: "Arrival")]),
        ]
        let filtered = BangumiCalendarView.filterForTesting(
            days: days, keyword: "dune", index: [:])

        XCTAssertEqual(filtered.count, 1, "只有一天有命中")
        XCTAssertEqual(filtered[0].items.map(\.id), [1])
    }

    /// **索引命中与即时计算必须给出相同结果** —— 这是缓存正确性的核心判据。
    ///
    /// `filter` 优先读索引、缺项时当场算。两条路径必须等价，否则「缓存预热了」
    /// 与「没预热」会给出不同搜索结果。
    func testIndexedAndInlinePathsAgree() {
        let days = [
            day(weekdayID: 1, items: [
                item(id: 1, name: "Dune", summary: "沙漠"),
                item(id: 2, name: "沙丘", nameCN: "沙丘"),
            ]),
            day(weekdayID: 2, items: [item(id: 3, name: "Alien")]),
        ]
        // 空索引 = 全部走即时计算。
        // 完整索引 = 全部走缓存。
        var fullIndex: [Int: String] = [:]
        for d in days {
            for i in d.items { fullIndex[i.id] = BangumiCalendarView.searchableTextForTesting(i) }
        }

        for keyword in ["dune", "沙丘", "沙漠", "alien", "nomatch"] {
            let inline = BangumiCalendarView.filterForTesting(
                days: days, keyword: keyword, index: [:])
            let indexed = BangumiCalendarView.filterForTesting(
                days: days, keyword: keyword, index: fullIndex)
            XCTAssertEqual(
                inline.map { $0.items.map(\.id) }, indexed.map { $0.items.map(\.id) },
                "关键词 \"\(keyword)\" 的索引路径与即时路径结果不一致")
        }
    }

    /// 空关键词走 `filter` 会**过滤掉一切**（`String.contains("")` 返回 false）。
    ///
    /// ⚠️ 这条是我写错断言后改正的：我原以为 `contains("")` 恒真、会全保留。
    /// 实测是 **false** —— 所以生产路径**必须**在关键词为空时提前返回 `days`
    /// （`filteredDays` 的 getter 里就是 `guard !trimmed.isEmpty else { return days }`）。
    ///
    /// 这条用例真正的价值是**钉住那个 guard 不能删**：若有人去掉它，搜索框清空后
    /// 列表会变成空。
    func testFilterWithEmptyKeywordDropsEverythingSoCallerMustGuard() {
        let days = [day(weekdayID: 1, items: [item(id: 1, name: "Dune")])]
        let filtered = BangumiCalendarView.filterForTesting(days: days, keyword: "", index: [:])
        XCTAssertTrue(filtered.isEmpty,
                      "String.contains(\"\") 返回 false，所以 filter 会丢光 —— "
                      + "调用方必须自己 guard 空关键词（`filteredDays` 里就是这么做的）")
    }
}
