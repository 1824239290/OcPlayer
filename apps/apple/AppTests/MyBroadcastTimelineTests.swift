import BangumiKit
import CoreModel
import Foundation
import XCTest
@testable import OcPlayer

final class MyBroadcastTimelineTests: XCTestCase {
    private var now: Date { MyBroadcastSchedule.date("2026-11-07T10:00:00Z")! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func subject(_ id: Int, _ name: String = "测试番剧") -> BangumiSubjectDTO {
        .init(id: id, nameCN: name, type: .anime)
    }
    private func record(_ id: Int, title: String = "测试番剧", broadcast: String = "R/2026-10-03T15:00:00Z/P7D",
                        end: String? = nil, type: String = "tv", extraSites: [MyBroadcastRecord.Site] = []) -> MyBroadcastRecord {
        .init(title: title, type: type, begin: "2026-10-03T15:00:00Z", broadcast: broadcast, end: end,
              sites: [.init(site: "bangumi", id: String(id))] + extraSites)
    }
    private func days(_ ids: [Int], weekday: Int = 6) -> [BangumiCalendarDayDTO] {
        [.init(weekday: .init(en: "", cn: "", ja: "", id: weekday), items: ids.map { .init(id: $0) })]
    }
    private func media(_ id: String = "local", _ name: String = "测试番剧") -> MediaItem {
        .init(id: id, name: name, kind: .series, childCount: 1)
    }

    func testIntersectionRequiresWatchingOnAirAndLibraryAvailability() {
        let entries = MyBroadcastTimeline.build(watching: [subject(1), subject(2), subject(3, "不在库")],
                                               calendar: days([1, 3, 4]), records: [record(1), record(2), record(3, title: "不在库"), record(4)],
                                               library: [media()], links: [:], now: now)
        XCTAssertEqual(entries.map(\.id), [1])
    }

    func testEndedFutureAndOneShotProgramsAreExcluded() {
        var future = record(2)
        future.begin = "2027-01-01T00:00:00Z"
        let entries = MyBroadcastTimeline.build(watching: (1...5).map { subject($0) }, calendar: days(Array(1...5)),
                                               records: [record(1, end: "2026-11-01T00:00:00Z"), future,
                                                         record(3, broadcast: "R/2026-10-03T15:00:00Z/P0D"),
                                                         record(4, type: "movie"), record(5)],
                                               library: [media()], links: [:], now: now)
        XCTAssertEqual(entries.map(\.id), [5])
    }

    func testUnknownTimeRetainsOnlyConfirmedOnAirIntersection() {
        let entries = MyBroadcastTimeline.build(watching: [subject(1)], calendar: days([1]), records: [],
                                               library: [media()], links: [:], now: now)
        let occurrences = MyBroadcastTimeline.occurrences(entries, weekday: 6, now: now, calendar: calendar)
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertNil(occurrences.first?.date)
        XCTAssertEqual(occurrences.first?.subtitle(calendar: calendar), "更新时间待定")
    }

    func testLocalTimeOrderingPlacesUnknownLast() {
        let entries = MyBroadcastTimeline.build(watching: [subject(1), subject(2), subject(3)], calendar: days([1, 2, 3]),
                                               records: [record(1, broadcast: "R/2026-10-03T15:00:00Z/P7D"),
                                                         record(2, broadcast: "R/2026-10-03T12:00:00Z/P7D")],
                                               library: [media()], links: [:], now: now)
        let occurrences = MyBroadcastTimeline.occurrences(entries, weekday: 6, now: now, calendar: calendar)
        XCTAssertEqual(occurrences.map(\.id), [2, 1, 3])
        XCTAssertEqual(occurrences.first?.subtitle(calendar: calendar), "20:00 更新")
    }

    func testJapaneseMidnightMovesToCorrectLocalWeekday() {
        let schedule = MyBroadcastSchedule("R/2026-10-04T00:30:00+09:00/P7D", end: nil)!
        let entry = MyBroadcastEntry(subject: subject(1), mediaID: "local", weekday: 7, schedule: schedule)
        let saturday = MyBroadcastTimeline.occurrences([entry], weekday: 6, now: now, calendar: calendar)
        XCTAssertEqual(saturday.first?.subtitle(calendar: calendar), "23:30 更新")
        XCTAssertTrue(MyBroadcastTimeline.occurrences([entry], weekday: 7, now: now, calendar: calendar).isEmpty)
    }

    func testDailyMonthlyAndEndBoundaries() {
        let daily = MyBroadcastSchedule("R/2026-10-03T12:00:00Z/P1D", end: nil)!
        XCTAssertNotNil(daily.occurrence(on: now, calendar: calendar))
        let monthly = MyBroadcastSchedule("R/2026-10-07T12:00:00Z/P1M", end: nil)!
        XCTAssertNotNil(monthly.occurrence(on: now, calendar: calendar))
        XCTAssertNil(monthly.occurrence(on: now.addingTimeInterval(86_400), calendar: calendar))
        let ended = MyBroadcastSchedule("R/2026-10-03T15:00:00Z/P7D", end: "2026-11-07T14:00:00Z")!
        XCTAssertNil(ended.occurrence(on: now, calendar: calendar))
        XCTAssertNil(MyBroadcastSchedule("R/2026-10-03T15:00:00Z/P0D", end: nil))
        XCTAssertNil(MyBroadcastSchedule("invalid", end: nil))
    }

    func testExplicitLinkOverridesTitleButConflictingLinkDoesNotFallback() {
        XCTAssertEqual(MyBroadcastTimeline.match(subject: subject(1), record: nil, library: [media("local", "别名")],
                                                 links: ["local": 1])?.id, "local")
        XCTAssertNil(MyBroadcastTimeline.match(subject: subject(1), record: nil, library: [media()], links: ["local": 2]))
    }

    func testTmdbSeasonRequiresThatSeasonToExist() {
        let rec = record(1, extraSites: [.init(site: "tmdb", id: "tv/123/season/2")])
        let parent = MediaItem(id: "series", name: "测试番剧", kind: .series, childCount: 1, tmdbID: "123")
        let first = MediaItem(id: "s1", name: "Season 1", kind: .season, seriesID: "series", seasonNumber: 1, childCount: 12)
        let second = MediaItem(id: "s2", name: "Season 2", kind: .season, seriesID: "series", seasonNumber: 2,
                               childCount: 1, tmdbID: "98765")
        XCTAssertNil(MyBroadcastTimeline.match(subject: subject(1), record: rec, library: [parent, first], links: [:]))
        XCTAssertEqual(MyBroadcastTimeline.match(subject: subject(1), record: rec, library: [parent, first, second], links: [:])?.id, "s2")
    }

    func testAliasesMatchExactlyWithoutStrippingSeasonNames() {
        let rec = MyBroadcastRecord(title: "日本語の作品", titleTranslate: ["zh-Hant": ["測試番劇"]], type: "tv", sites: [])
        XCTAssertNotNil(MyBroadcastTimeline.match(subject: subject(1, "日本語の作品"), record: rec, library: [media()], links: [:]))
        XCTAssertNil(MyBroadcastTimeline.match(subject: subject(1, "测试番剧 第二季"), record: nil, library: [media()], links: [:]))
        XCTAssertNil(MyBroadcastTimeline.match(subject: subject(1), record: nil,
                                               library: [.init(id: "empty", name: "测试番剧", kind: .series, childCount: 0)], links: [:]))
    }

    func testAllMatchingProgramsRemainVisibleBeyondTwelveAndDuplicatesCollapse() {
        let subjects = (1...20).map { subject($0) }
        let entries = MyBroadcastTimeline.build(watching: subjects + [subject(1)], calendar: days(Array(1...20)),
                                               records: [], library: [media()], links: [:], now: now)
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(MyBroadcastTimeline.occurrences(entries, weekday: 6, now: now, calendar: calendar).count, 20)
    }
}

@MainActor
final class MyBroadcastDataStoreTests: XCTestCase {
    func testPublicDataDownloadIsCachedAndSurvivesOfflineRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); MockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let bytes = Data(#"{"items":[{"title":"作品","type":"tv","begin":"2026-10-03T15:00:00Z","broadcast":"R/2026-10-03T15:00:00Z/P7D","end":"","sites":[{"site":"bangumi","id":"42"}]}]}"#.utf8)
        MockURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, bytes)
        }
        let store = MyBroadcastDataStore(directory: directory, session: session)
        let now = Date()
        let first = try await store.load(now: now)
        XCTAssertEqual(first.first?.subjectID, 42)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let cached = try await store.load(now: now.addingTimeInterval(60))
        XCTAssertEqual(cached, first)
        let relaunched = MyBroadcastDataStore(directory: directory, session: session)
        let offline = try await relaunched.load(now: now.addingTimeInterval(7 * 3_600))
        XCTAssertEqual(offline, first)
        MockURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.1)
            throw URLError(.notConnectedToInternet)
        }
        async let a = relaunched.load(now: now.addingTimeInterval(8 * 3_600))
        async let b = relaunched.load(now: now.addingTimeInterval(8 * 3_600))
        let concurrent = try await (a, b)
        XCTAssertEqual(concurrent.0, first)
        XCTAssertEqual(concurrent.1, first)
    }
}
