import CoreModel
import Foundation
import XCTest

@testable import MetadataKit

/// 选集轨道的占位策略：空洞补位、未播出 / 未入库、窗口与上限、编号锚点。
///
/// 这一层是纯函数，所以「哪一格该出现占位」的所有判断都能在这里钉死——App 侧只剩
/// 「把哪两个来源喂进来」这一句接线。
final class EpisodeSlotTests: XCTestCase {

    /// 固定的「现在」：2026-10-09。用注入的 now 而不是 `Date()`，否则「未播出」
    /// 的用例会随真实时间漂移。
    private var now: Date { makeDate("2026-10-09") }

    private func makeDate(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)!
    }

    private func candidate(_ number: Int, airDate: String? = nil, title: String? = nil,
                           still: String? = nil, runtime: Int? = nil) -> EpisodeCandidate {
        EpisodeCandidate(number: number, title: title, stillPath: still,
                         airDate: airDate.map(makeDate),
                         runtimeSeconds: runtime.map { Double($0) * 60 })
    }

    private func localEpisode(_ number: Int) -> MediaItem {
        makeItem(id: "ep-\(number)", name: "第 \(number) 集", kind: .episode, episodeNumber: number)
    }

    private func build(
        seasonNumber: Int? = 3,
        local: [MediaItem] = [],
        primary: [EpisodeCandidate] = [],
        fallback: [EpisodeCandidate] = []
    ) -> [EpisodeSlot] {
        EpisodeSlotBuilder.build(seasonNumber: seasonNumber, local: local,
                                 primary: primary, fallback: fallback, now: now)
    }

    /// 只取集号，方便断言顺序。
    private func numbers(_ slots: [EpisodeSlot]) -> [Int] {
        slots.compactMap { slot in
            switch slot {
            case .local(let item): item.episodeNumber
            case .placeholder(let placeholder): placeholder.number
            }
        }
    }

    // MARK: - 基本形态

    /// 库内 25、来源 25…36（26 已播、27 起未来）→ 26 标未入库，27…36 标未播出。
    /// 这是用户实测的那个场景（乱马 1/2 第三季）。
    func testFillsMissingTailWithAiredAndFutureLabels() {
        let local = [localEpisode(25)]
        let source = [candidate(25, airDate: "2026-09-27")]
            + (26...36).map { candidate($0, airDate: $0 == 26 ? "2026-10-04" : "2026-11-\($0 - 26)") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), Array(25...36))
        XCTAssertEqual(slots.first?.episode?.episodeNumber, 25, "库内那一集必须还是本地条目")
        XCTAssertEqual(slots.count { $0.placeholder != nil }, 11)
        XCTAssertEqual(slots[1].placeholder?.reason, .notInLibrary, "26 已播出但库里没有")
        XCTAssertEqual(slots[2].placeholder?.reason, .notAired, "27 还没播")
        XCTAssertEqual(slots.last?.placeholder?.seasonNumber, 3)
    }

    /// 库内 1/3/5 → 2、4 补在正确的集号位置上（空洞，不是简单追加到末尾）。
    func testFillsHolesInTheMiddleInPlace() {
        let local = [localEpisode(1), localEpisode(3), localEpisode(5)]
        let source = (1...5).map { candidate($0, airDate: "2020-01-0\($0)") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), [1, 2, 3, 4, 5])
        XCTAssertEqual(slots[1].placeholder?.reason, .notInLibrary)
        XCTAssertEqual(slots[3].placeholder?.reason, .notInLibrary)
        XCTAssertNil(slots[0].placeholder, "本地集不能被占位顶掉")
    }

    /// 集号在本地但来源没有（服务端比 TMDb 多一集，如特番）→ 本地那集必须保留。
    func testKeepsLocalEpisodesUnknownToTheSource() {
        let local = [localEpisode(1), localEpisode(99)]
        let source = (1...3).map { candidate($0, airDate: "2020-01-01") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), [1, 2, 3, 99])
    }

    // MARK: - 未播出 vs 未入库

    /// **日期未知 ≠ 未播出**：那是十年前的一集只是没刮到日期，标成「未播出」会让用户白等。
    func testUnknownAirDateIsNotInLibraryNotNotAired() {
        let slots = build(local: [localEpisode(1)],
                          primary: [candidate(1), candidate(2), candidate(3, airDate: "2026-11-01")])

        XCTAssertEqual(slots[1].placeholder?.reason, .notInLibrary)
        XCTAssertEqual(slots[2].placeholder?.reason, .notAired)
    }

    /// 今天零点播出的那集算**已播出**（与 `BangumiEpisodeDTO.aired` 的 `<=` 同口径）。
    func testEpisodeAiringTodayCountsAsAired() {
        let slots = build(local: [localEpisode(1)],
                          primary: [candidate(1), candidate(2, airDate: "2026-10-09")])

        XCTAssertEqual(slots[1].placeholder?.reason, .notInLibrary)
    }

    // MARK: - 窗口与上限

    /// 长番：库内只有第 1 集、来源 1…1000 全部已播出 → 只补窗口内的 2…25，
    /// 不是 999 张。
    func testLongRunningSeriesIsBoundedByForwardWindow() {
        let local = [localEpisode(1)]
        let source = (1...1000).map { candidate($0, airDate: "2010-01-01") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), Array(1...(1 + EpisodeSlotBuilder.forwardWindow)))
    }

    /// 窗口上界锚在**库内最大集号**上、下界锚在**库内最小集号**上，不是来源的首尾。
    /// 库内 100…103、来源 1…200 → 1…99（在首集之前）与 128…200（超出窗口）都不补。
    func testWindowIsAnchoredOnTheLocalSpan() {
        let local = (100...103).map(localEpisode)
        let source = (1...200).map { candidate($0, airDate: "2010-01-01") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), Array(100...(103 + EpisodeSlotBuilder.forwardWindow)))
    }

    /// 安全网：库内只有首尾两集时中间的洞有几百个，按集号截到上限。
    func testPlaceholderCapIsEnforced() {
        let local = [localEpisode(1), localEpisode(1000)]
        let source = (1...1000).map { candidate($0, airDate: "2010-01-01") }

        let slots = build(local: local, primary: source)

        let placeholders = slots.compactMap(\.placeholder).map(\.number)
        XCTAssertEqual(placeholders.count, EpisodeSlotBuilder.maxPlaceholders)
        XCTAssertEqual(placeholders.first, 2, "靠前的洞先留下")
        XCTAssertEqual(placeholders.last, 1 + EpisodeSlotBuilder.maxPlaceholders)
        XCTAssertEqual(numbers(slots).first, 1, "本地首集必须还在")
        XCTAssertEqual(numbers(slots).last, 1000, "本地末集必须还在")
    }

    /// 空库（有季但一集都没有）→ 补该季前 forwardWindow 集。
    func testEmptyLocalSeasonFillsFromTheStart() {
        let source = (1...40).map { candidate($0, airDate: "2010-01-01") }

        let slots = build(local: [], primary: source)

        XCTAssertEqual(numbers(slots), Array(1...EpisodeSlotBuilder.forwardWindow))
    }

    // MARK: - 编号锚点（宁可不显示，也不显示错号）

    /// 库内用季内相对集号（1…3）、来源用绝对集号（25…36）→ 没有交集 → 不补占位。
    func testMismatchedNumberingSuppressesPlaceholders() {
        let local = [localEpisode(1), localEpisode(2), localEpisode(3)]
        let source = (25...36).map { candidate($0, airDate: "2026-11-01") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), [1, 2, 3])
        XCTAssertTrue(slots.allSatisfy { $0.placeholder == nil })
    }

    /// 有交集才认（库内 25 与来源 25…36 同源）。
    func testOverlapMakesTheSourceTrusted() {
        let slots = build(local: [localEpisode(25)],
                          primary: (25...27).map { candidate($0, airDate: "2026-11-01") })

        XCTAssertEqual(numbers(slots), [25, 26, 27])
    }

    /// 库内有条目但一个集号都没有 → 无从判断编号，不补。
    func testLocalWithoutEpisodeNumbersSuppressesPlaceholders() {
        let local = [makeItem(id: "x", name: "无集号", kind: .episode)]
        let source = (1...5).map { candidate($0, airDate: "2026-11-01") }

        let slots = build(local: local, primary: source)

        XCTAssertEqual(slots.count, 1)
        XCTAssertNil(slots[0].placeholder)
    }

    /// 空库时没有可对照的事实，来源直接用。
    func testEmptyLocalTrustsTheSource() {
        let slots = build(local: [], primary: [candidate(1, airDate: "2026-11-01")])

        XCTAssertEqual(numbers(slots), [1])
    }

    // MARK: - 来源优先级

    /// TMDb 有数据时用 TMDb，Bangumi 只做兜底。
    func testPrimaryWinsOverFallback() {
        let slots = build(local: [localEpisode(1)],
                          primary: [candidate(1, title: "TMDb 标题"), candidate(2, title: "TMDb 的 2")],
                          fallback: [candidate(1), candidate(2, title: "Bangumi 的 2"),
                                     candidate(3, title: "Bangumi 的 3")])

        XCTAssertEqual(numbers(slots), [1, 2])
        XCTAssertEqual(slots[1].placeholder?.title, "TMDb 的 2")
    }

    /// TMDb 没数据时用 Bangumi 兜底。
    func testFallbackUsedWhenPrimaryIsEmpty() {
        let slots = build(local: [localEpisode(25)],
                          fallback: [candidate(25), candidate(26, title: "第 26 话")])

        XCTAssertEqual(numbers(slots), [25, 26])
        XCTAssertEqual(slots[1].placeholder?.title, "第 26 话")
    }

    /// TMDb 有数据但编号对不上（锚点不过）时，继续试 Bangumi 兜底——这正是
    /// 「TMDb 优先、Bangumi 兜底」比「只看 TMDb 有没有」更有价值的地方。
    func testFallbackRescuesAMismatchedPrimary() {
        let slots = build(local: [localEpisode(25)],
                          primary: (1...12).map { candidate($0, airDate: "2026-11-01") },
                          fallback: (25...27).map { candidate($0, airDate: "2026-11-01") })

        XCTAssertEqual(numbers(slots), [25, 26, 27])
    }

    /// 两个来源都没有 → 原样返回本地（与加占位之前的行为一字不差）。
    func testNoSourceReturnsLocalUnchanged() {
        let local = [localEpisode(3), localEpisode(1)]
        let slots = build(local: local, primary: [], fallback: [])

        XCTAssertEqual(slots.compactMap(\.episode).map(\.id), local.map(\.id), "顺序也要保持原样")
    }

    // MARK: - 特典 / 季号

    /// 特典（季号 0）与季号缺失都不补：TMDb 的 season 0 与 Jellyfin 从文件名派生的
    /// SP 编号本来就不同源。
    func testSpecialsSeasonIsNeverFilled() {
        let local = [localEpisode(1)]
        let source = [candidate(1), candidate(2, airDate: "2026-11-01")]

        XCTAssertEqual(numbers(build(seasonNumber: 0, local: local, primary: source)), [1])
        XCTAssertEqual(numbers(build(seasonNumber: nil, local: local, primary: source)), [1])
    }

    // MARK: - 去重与标识

    /// 来源里重复的集号只出一张卡；与本地同号的候选不会顶掉本地条目。
    func testDuplicateNumbersProduceOneSlotEach() {
        let local = [localEpisode(1), localEpisode(1)]
        let source = [candidate(1), candidate(1), candidate(2), candidate(2)]

        let slots = build(local: local, primary: source)

        XCTAssertEqual(numbers(slots), [1, 2])
        XCTAssertEqual(slots.count, 2)
    }

    /// 占位 id 必须与本地条目 id 不同形（否则 `scrollToID` 会滚到错的卡）。
    func testPlaceholderIDCannotCollideWithLocalIDs() {
        let slots = build(local: [localEpisode(1)],
                          primary: [candidate(1), candidate(2)])

        XCTAssertEqual(slots[0].id, "ep-1")
        XCTAssertEqual(slots[1].id, "placeholder.s3.e2")
        XCTAssertEqual(Set(slots.map(\.id)).count, slots.count)
    }

    /// 集号 ≤ 0 的候选一律丢弃（服务端/TMDb 的脏数据不该变成负号卡片）。
    func testNonPositiveNumbersAreDropped() {
        let slots = build(local: [localEpisode(1)],
                          primary: [candidate(1), candidate(0), candidate(-3), candidate(2)])

        XCTAssertEqual(numbers(slots), [1, 2])
    }

    // MARK: - 展示值

    /// 来源没标题时回落「第 N 集」；有标题就用它。
    func testPlaceholderDisplayTitleFallsBackToEpisodeNumber() {
        let slots = build(local: [localEpisode(1)],
                          primary: [candidate(1), candidate(2, title: "   "), candidate(3, title: "真标题")])

        XCTAssertEqual(slots[1].placeholder?.displayTitle, "第 2 集")
        XCTAssertEqual(slots[2].placeholder?.displayTitle, "真标题")
        XCTAssertEqual(slots[1].placeholder?.episodeLabel, "S3E2")
    }

    // MARK: - TMDb 季叠加层 → 候选

    private func seasonOverlay(episodes: [EpisodeEntry]) -> TMDbOverlay {
        let season = TMDbSeason(seasonNumber: 3, name: "第 3 季", overview: nil,
                                posterPath: nil, episodes: episodes)
        let link = TMDbLink(itemID: "series", entityKey: .tv(100),
                            source: .providerID, confidence: 1.0, linkedAt: Date())
        return TMDbOverlay(season: season, link: link, fetchedAt: Date(), isExpired: false)
    }

    func testEpisodeCandidatesMapAirDateStillAndRuntime() {
        let overlay = seasonOverlay(episodes: [
            EpisodeEntry(episodeNumber: 26, name: "第 26 话", overview: "简介",
                         stillPath: "/still26.jpg", airDate: "2026-10-11", runtime: 24),
        ])

        let candidates = overlay.episodeCandidates
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].number, 26)
        XCTAssertEqual(candidates[0].title, "第 26 话")
        XCTAssertEqual(candidates[0].stillPath, "/still26.jpg")
        XCTAssertEqual(candidates[0].runtimeSeconds, 24 * 60)
        XCTAssertEqual(candidates[0].airDate, makeDate("2026-10-11"))
    }

    /// 坏日期 / 空日期 → nil（日期未知），**不拿本地时钟顶替**。
    func testEpisodeCandidatesRejectUnparseableAirDates() {
        let overlay = seasonOverlay(episodes: [
            EpisodeEntry(episodeNumber: 1, airDate: ""),
            EpisodeEntry(episodeNumber: 2, airDate: "2026-13-45"),
            EpisodeEntry(episodeNumber: 3, airDate: "待定"),
        ])

        XCTAssertEqual(overlay.episodeCandidates.map(\.airDate), [nil, nil, nil])
    }

    /// 剧集级叠加层没有分集 → 候选为空（调用方不用再判叠加层类型）。
    func testEntityOverlayHasNoCandidates() {
        let entity = TMDbEntity(id: 603, mediaType: .movie, title: "某片")
        let link = TMDbLink(itemID: "i1", entityKey: .movie(603), source: .providerID,
                            confidence: 1.0, linkedAt: Date())
        let overlay = TMDbOverlay(entity: entity, link: link, fetchedAt: Date(), isExpired: false)

        XCTAssertTrue(overlay.episodeCandidates.isEmpty)
    }

    // MARK: - 偏好默认值

    /// 键从未写过（用户没拨过开关）→ 默认开；显式关掉要生效。
    func testShowPlaceholdersDefaultsToOn() throws {
        let suiteName = "EpisodeSlotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TMDbPreferences(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: TMDbPreferences.showPlaceholdersKey), "前提：键确实不存在")
        XCTAssertTrue(preferences.showPlaceholders, "键不存在时要回默认值 true，不能是 bool(forKey:) 的 false")

        preferences.showPlaceholders = false
        XCTAssertFalse(preferences.showPlaceholders)
        XCTAssertFalse(TMDbPreferences(defaults: defaults).showPlaceholders, "要落盘")
    }
}
