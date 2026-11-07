import CoreModel
import JellyfinKit
import XCTest
@testable import OcPlayer

@MainActor
final class MyViewingStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }
    private func record(_ id: String, kind: MediaItem.Kind = .episode, date: Date, seconds: Double? = 1440,
                        genres: [String] = []) -> ServerViewingRecord {
        .init(item: MediaItem(id: id, name: id, kind: kind, runtimeSeconds: seconds, genres: genres), watchedAt: date)
    }

    func testTotalsSeparateMoviesEpisodesAndMissingRuntime() {
        let values = [record("a", date: date(7)), record("b", kind: .movie, date: date(7), seconds: 7200),
                      record("c", date: date(7), seconds: nil)]
        let total = MyViewingTotals(records: values)
        XCTAssertEqual(total.movies, 1)
        XCTAssertEqual(total.episodes, 2)
        XCTAssertEqual(total.estimatedSeconds, 8640)
        XCTAssertEqual(total.unknownRuntime, 1)
    }

    func testDailyBoundaryUsesLocalTimezoneInsteadOfUTC() {
        let early = record("a", date: date(7, hour: 1))
        let late = record("b", date: date(6, hour: 23))
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), syncedAt: date(7), records: [early, late])
        let stats = MyViewingStatistics(history: history, now: date(7), calendar: calendar)
        XCTAssertEqual(stats.records(on: date(7)).map(\.id), ["a"])
        XCTAssertEqual(stats.records(on: date(6)).map(\.id), ["b"])
    }

    func testMonthBoundariesAndCalendarDayCount() {
        let values = [record("a", date: date(1, hour: 0)), record("b", date: date(30, hour: 23)),
                      record("c", date: calendar.date(byAdding: .month, value: 1, to: date(1))!)]
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), syncedAt: date(30), records: values)
        let stats = MyViewingStatistics(history: history, now: date(30), calendar: calendar)
        XCTAssertEqual(stats.records(inMonth: date(7)).map(\.id), ["a", "b"])
        XCTAssertEqual(stats.monthDays(date(7)).count, 30)
    }

    func testHeatmapDistinguishesBeforeImportFutureAndCoveredZero() {
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: calendar.startOfDay(for: date(1)), syncedAt: date(7))
        let stats = MyViewingStatistics(history: history, now: date(7), calendar: calendar)
        let days = stats.heatmapWeeks.flatMap { $0 }
        XCTAssertEqual(days.count, 105)
        XCTAssertEqual(Set(days.map(\.id)).count, 105)
        XCTAssertEqual(days.filter(\.isCovered).count, 7)
        XCTAssertFalse(days.last!.isCovered) // Sunday 8th is in the future.
        XCTAssertEqual(days.first!.totals.episodes, 0)
        XCTAssertFalse(days.first!.isCovered)
    }

    func testGenreDistributionDoesNotMultiplyRuntimeForMultipleLabels() {
        let values = [record("a", date: date(7), seconds: 3600, genres: ["动画", "喜剧", "动画"]),
                      record("b", date: date(7), seconds: 1800), record("c", date: date(7), seconds: nil, genres: ["喜剧"])]
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), records: values)
        let stats = MyViewingStatistics(history: history, calendar: calendar)
        let genres = stats.genreDistribution
        XCTAssertEqual(genres.reduce(0) { $0 + $1.seconds }, 5400)
        XCTAssertEqual(genres.first { $0.name == "动画" }?.seconds, 1800)
        XCTAssertEqual(genres.first { $0.name == "未分类" }?.seconds, 1800)
    }

    func testTopTitlesGroupBySeriesIDWithoutMergingSameNamesAcrossSeries() {
        var first = record("a", date: date(7))
        first.item.seriesID = "series-1"
        first.item.seriesName = "同名剧"
        var second = record("b", date: date(7))
        second.item.seriesID = "series-1"
        second.item.seriesName = "同名剧"
        var third = record("c", date: date(7))
        third.item.seriesID = "series-2"
        third.item.seriesName = "同名剧"
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), records: [first, second, third])
        let titles = MyViewingStatistics(history: history, calendar: calendar).topTitles(inMonth: date(7))
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles[0].seconds, 2880)
        XCTAssertEqual(titles[1].seconds, 1440)
        XCTAssertNotEqual(titles[0].id, titles[1].id)
    }

    func testTrendsDoNotInventComparisonBeforeImportBoundary() {
        let values = [record("a", date: date(7), genres: ["动画", "喜剧"])]
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), syncedAt: date(7), records: values)
        let trends = MyViewingStatistics(history: history, now: date(7), calendar: calendar).genreTrends
        XCTAssertEqual(trends.count, 2)
        XCTAssertEqual(trends.first?.samples.count, 7)
        XCTAssertNil(trends.first?.previousSeconds)
        XCTAssertEqual(trends.reduce(0) { $0 + $1.seconds }, 1440)
    }

    private func fragment(_ id: String, itemID: String = "a", day: Int = 7, seconds: Double,
                          source: String = "s") -> AppPlaybackRecord {
        .init(id: id, sourceID: source,
              item: MediaItem(id: itemID, name: itemID, kind: .episode, runtimeSeconds: 1440, genres: ["动画"]),
              day: calendar.startOfDay(for: date(day)), watchedAt: date(day), seconds: seconds)
    }

    func testPartialPlaybackCountsActualMinutesWithoutCountingCompletedEpisode() {
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1))
        let stats = MyViewingStatistics(history: history, localRecords: [fragment("one", seconds: 180)], now: date(7), calendar: calendar)
        XCTAssertEqual(stats.total.actualSeconds, 180)
        XCTAssertEqual(stats.total.estimatedSeconds, 0)
        XCTAssertEqual(stats.total.episodes, 0)
        XCTAssertEqual(stats.total.playbackFragments, 1)
        XCTAssertEqual(stats.topTitles(inMonth: date(7)).first?.seconds, 180)
        XCTAssertEqual(stats.genreDistribution.first?.seconds, 180)
        XCTAssertTrue(stats.heatmapWeeks.flatMap { $0 }.first { calendar.isDate($0.date, inSameDayAs: date(7)) }!.isCovered)
    }

    func testServerCompletionAndMultipleAppSessionsDoNotDuplicateRuntime() {
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), syncedAt: date(7), records: [record("a", date: date(7))])
        let stats = MyViewingStatistics(history: history,
                                        localRecords: [fragment("one", seconds: 180), fragment("two", seconds: 120)],
                                        now: date(7), calendar: calendar)
        XCTAssertEqual(stats.total.seconds, 300)
        XCTAssertEqual(stats.total.episodes, 1)
        XCTAssertEqual(stats.total.estimatedSeconds, 0)
        XCTAssertEqual(stats.records(on: date(7)).count, 1)
    }

    func testResumingAcrossDaysKeepsActualTimeOnEachDate() {
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1), syncedAt: date(7), records: [record("a", date: date(7))])
        let stats = MyViewingStatistics(history: history,
                                        localRecords: [fragment("one", day: 6, seconds: 600), fragment("two", seconds: 600)],
                                        now: date(7), calendar: calendar)
        XCTAssertEqual(stats.totals(on: date(6)).seconds, 600)
        XCTAssertEqual(stats.totals(on: date(7)).seconds, 600)
        XCTAssertEqual(stats.total.seconds, 1200)
        XCTAssertEqual(stats.total.episodes, 1)
    }

    func testOtherAccountsAreExcludedButLocalFilesRemainVisible() {
        let history = ServerViewingHistory(sourceID: "s", recordedFrom: date(1))
        let stats = MyViewingStatistics(history: history,
                                        localRecords: [fragment("other", seconds: 600, source: "another-account"),
                                                       fragment("local", seconds: 60, source: AppPlaybackHistoryStore.localSourceID)],
                                        now: date(7), calendar: calendar)
        XCTAssertEqual(stats.total.actualSeconds, 60)
        XCTAssertEqual(stats.entries.count, 1)
        XCTAssertTrue(stats.entries[0].isLocalFile)
    }
}
