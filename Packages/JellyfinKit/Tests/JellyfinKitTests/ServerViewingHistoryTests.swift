import CoreModel
import Foundation
import XCTest
@testable import JellyfinKit

final class ServerViewingHistoryTests: XCTestCase {
    private actor PageGate {
        var continuation: CheckedContinuation<ServerPlayedItemsPage, Never>?
        var isWaiting: Bool { continuation != nil }
        func fetch() async -> ServerPlayedItemsPage {
            await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ page: ServerPlayedItemsPage) { continuation?.resume(returning: page); continuation = nil }
    }
    private let now = Date(timeIntervalSince1970: 1_793_996_400)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func row(_ id: String, at date: Date?, played: Bool = true, kind: MediaItem.Kind = .episode) -> ServerPlayedItem {
        ServerPlayedItem(item: MediaItem(id: id, name: id, kind: kind, runtimeSeconds: 1440,
                                        playState: .init(played: played, percentage: 1, positionSeconds: 0)),
                         lastPlayedAt: date)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTests-" + UUID().uuidString)
    }

    func testFirstImportCoversThirtyLocalCalendarDays() async throws {
        let store = ServerViewingHistoryStore(directory: directory())
        let archive = try await store.read(sourceID: "a", now: now, calendar: calendar)
        XCTAssertEqual(archive.recordedFrom, calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)))
        XCTAssertNil(archive.syncedAt)
        XCTAssertTrue(archive.records.isEmpty)
    }

    func testPaginationKeepsNewestPerItemAndContinuesShortPageWhenTotalIsKnown() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let first = row("a", at: now)
        let second = row("a", at: now.addingTimeInterval(-60))
        let third = row("b", at: now.addingTimeInterval(-120))
        let archive = try await store.synchronize(sourceID: "a", now: now, calendar: calendar, pageSize: 5) { start, _ in
            switch start {
            case 0: return ServerPlayedItemsPage(items: [first], totalRecordCount: 3)
            case 1: return ServerPlayedItemsPage(items: [second, third], totalRecordCount: 3)
            default: XCTFail("Unexpected page \(start)"); return ServerPlayedItemsPage(items: [], totalRecordCount: 3)
            }
        }
        XCTAssertEqual(archive.records.map(\.id), ["a", "b"])
        XCTAssertEqual(archive.records.first?.watchedAt, now)
        let restored = try await ServerViewingHistoryStore(directory: path).read(sourceID: "a", now: now)
        XCTAssertEqual(restored, archive)
    }

    func testMissingDateUnplayedParentAndFutureItemsDoNotBecomeTodayHistory() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let rows = [row("dated", at: now), row("undated", at: nil), row("not-played", at: now, played: false),
                    row("series", at: now, kind: .series), row("future", at: now.addingTimeInterval(86_400))]
        let archive = try await store.synchronize(sourceID: "a", now: now) { _, _ in
            ServerPlayedItemsPage(items: rows, totalRecordCount: rows.count)
        }
        XCTAssertEqual(archive.records.map(\.id), ["dated"])
        XCTAssertEqual(archive.undatedItemCount, 1)
    }

    func testCompleteBoundaryPageIsProcessedBeforeStoppingAndOlderItemsExcluded() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let boundary = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        let rows = [row("boundary", at: boundary), row("old", at: boundary.addingTimeInterval(-1))]
        let archive = try await store.synchronize(sourceID: "a", now: now, calendar: calendar, pageSize: 2) { start, _ in
            XCTAssertEqual(start, 0)
            return ServerPlayedItemsPage(items: rows, totalRecordCount: 100)
        }
        XCTAssertEqual(archive.records.map(\.id), ["boundary"])
    }

    func testRepeatedSyncDoesNotDoubleCountAndRemoteUnmarkIsReconciled() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let rows = [row("a", at: now), row("b", at: now)]
        let first = try await store.synchronize(sourceID: "a", now: now) { _, _ in
            ServerPlayedItemsPage(items: rows, totalRecordCount: 2)
        }
        let second = try await store.synchronize(sourceID: "a", now: now.addingTimeInterval(60)) { _, _ in
            ServerPlayedItemsPage(items: rows, totalRecordCount: 2)
        }
        XCTAssertEqual(first.records, second.records)
        let remaining = [rows[0]]
        let third = try await store.synchronize(sourceID: "a", now: now.addingTimeInterval(120)) { _, _ in
            ServerPlayedItemsPage(items: remaining, totalRecordCount: 1)
        }
        XCTAssertEqual(third.records.map(\.id), ["a"])
        XCTAssertEqual(third.recordedFrom, first.recordedFrom)
    }

    func testRewatchUpdatesDateInsteadOfInventingAnotherSession() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let first = row("a", at: now.addingTimeInterval(-86_400))
        _ = try await store.synchronize(sourceID: "a", now: now) { _, _ in .init(items: [first], totalRecordCount: 1) }
        let latest = row("a", at: now)
        let result = try await store.synchronize(sourceID: "a", now: now) { _, _ in .init(items: [latest], totalRecordCount: 1) }
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.watchedAt, now)
    }

    func testPageFailureAndScanLimitPreservePriorArchive() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let rows = [row("a", at: now)]
        let original = try await store.synchronize(sourceID: "a", now: now) { _, _ in .init(items: rows, totalRecordCount: 1) }
        do {
            _ = try await store.synchronize(sourceID: "a", now: now, pageSize: 1) { start, _ in
                if start > 0 { throw URLError(.notConnectedToInternet) }
                return .init(items: rows, totalRecordCount: 100)
            }
            XCTFail("Expected failure")
        } catch { }
        do {
            _ = try await store.synchronize(sourceID: "a", now: now, pageSize: 1, maximumPages: 1) { _, _ in
                .init(items: rows, totalRecordCount: 100)
            }
            XCTFail("Expected scan limit")
        } catch { XCTAssertTrue(error is ServerViewingHistoryError) }
        let persisted = try await store.read(sourceID: "a", now: now)
        XCTAssertEqual(persisted, original)
    }

    func testAccountsAndServersUseSeparateFilesAndAddressChangesKeepIdentity() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let rows = [row("same-item-id", at: now)]
        _ = try await store.synchronize(sourceID: "a", now: now) { _, _ in .init(items: rows, totalRecordCount: 1) }
        let other = try await store.read(sourceID: "b", now: now)
        XCTAssertTrue(other.records.isEmpty)
        var profile = ServerProfile(id: "srv:u", serverName: "test", baseURL: URL(string: "https://one.local")!, userID: "u")
        let identity = ServerViewingHistory.sourceID(for: profile)
        profile.baseURL = URL(string: "https://two.local")!
        XCTAssertEqual(ServerViewingHistory.sourceID(for: profile), identity)
        profile.userID = "different"
        XCTAssertNotEqual(ServerViewingHistory.sourceID(for: profile), identity)
        profile.userID = "u"
        profile.kind = .emby
        XCTAssertNotEqual(ServerViewingHistory.sourceID(for: profile), identity)
    }

    func testUnknownRuntimeRemainsUnknown() {
        var item = row("a", at: now).item
        for value in [nil, Double.nan, Double.infinity, -1, 0] {
            item.runtimeSeconds = value
            XCTAssertNil(ServerViewingRecord(item: item, watchedAt: now).estimatedSeconds)
        }
    }

    func testLateSyncCannotOverwriteNewerArchive() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let gate = PageGate()
        let currentNow = now
        let old = Task {
            try await store.synchronize(sourceID: "a", now: currentNow) { _, _ in await gate.fetch() }
        }
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        let latestRows = [row("latest", at: now)]
        let newest = try await store.synchronize(sourceID: "a", now: now) { _, _ in .init(items: latestRows, totalRecordCount: 1) }
        await gate.finish(.init(items: [row("stale", at: now)], totalRecordCount: 1))
        do { _ = try await old.value; XCTFail("Expected superseded sync") } catch { XCTAssertTrue(error is CancellationError) }
        let persisted = try await store.read(sourceID: "a", now: now)
        XCTAssertEqual(persisted, newest)
    }

    func testCancellationDoesNotCreateArchive() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ServerViewingHistoryStore(directory: path)
        let gate = PageGate()
        let currentNow = now
        let task = Task {
            try await store.synchronize(sourceID: "a", now: currentNow) { _, _ in await gate.fetch() }
        }
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await gate.finish(.init(items: [row("a", at: now)], totalRecordCount: 1))
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
