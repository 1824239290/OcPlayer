import CoreModel
import CryptoKit
import DiagnosticsKit
import Foundation

/// A dated, completed item snapshot, not an individual playback session.
public struct ServerViewingRecord: Codable, Equatable, Identifiable, Sendable {
    public var item: MediaItem
    public var watchedAt: Date
    public var id: String { item.id }

    public init(item: MediaItem, watchedAt: Date) {
        self.item = item
        self.watchedAt = watchedAt
    }

    public var estimatedSeconds: Double? {
        guard let seconds = item.runtimeSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

/// Dates may be absent on manually marked or older server items. Never synthesize one.
public struct ServerPlayedItem: Equatable, Sendable {
    public var item: MediaItem
    public var lastPlayedAt: Date?

    public init(item: MediaItem, lastPlayedAt: Date?) {
        self.item = item
        self.lastPlayedAt = lastPlayedAt
    }
}

public struct ServerPlayedItemsPage: Equatable, Sendable {
    public var items: [ServerPlayedItem]
    public var totalRecordCount: Int?

    public init(items: [ServerPlayedItem], totalRecordCount: Int?) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }
}

public struct ServerViewingHistory: Codable, Equatable, Sendable {
    public var version = 1
    public var sourceID: String
    /// Initial import covers 30 calendar days. This boundary stays fixed on later syncs.
    public var recordedFrom: Date
    public var syncedAt: Date?
    /// One latest completed snapshot per film/episode; repeated fetches never add sessions.
    public var records: [ServerViewingRecord]
    public var undatedItemCount: Int

    public init(sourceID: String, recordedFrom: Date, syncedAt: Date? = nil,
                records: [ServerViewingRecord] = [], undatedItemCount: Int = 0) {
        self.sourceID = sourceID
        self.recordedFrom = recordedFrom
        self.syncedAt = syncedAt
        self.records = records
        self.undatedItemCount = undatedItemCount
    }

    public static func sourceID(for profile: ServerProfile) -> String {
        // An address change or token rotation must not create another history.
        "\(profile.kind.rawValue):\(profile.resolvedServerID ?? profile.id):\(profile.userID)"
    }
}

public enum ServerViewingHistoryError: LocalizedError {
    case unsupported, scanLimit, invalidArchive

    public var errorDescription: String? {
        switch self {
        case .unsupported: "此来源尚不支持服务器观看记录。"
        case .scanLimit: "观看记录过多，本次未完成同步；已保留上次记录。"
        case .invalidArchive: "本地观看记录无法读取，原文件已保留。"
        }
    }
}

/// Actor-owned I/O and atomic publication: a cancelled/partial scan cannot erase the archive.
public actor ServerViewingHistoryStore {
    public static let shared = ServerViewingHistoryStore()
    private let directory: URL
    private var generations: [String: UInt64] = [:]

    public init(directory: URL = OcPlayerStorage.directory("ViewingHistory")) {
        self.directory = directory
    }

    public func read(sourceID: String, now: Date = Date(), calendar: Calendar = .current) throws -> ServerViewingHistory {
        let url = archiveURL(sourceID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return ServerViewingHistory(sourceID: sourceID, recordedFrom: start)
        }
        let result = try JSONDecoder().decode(ServerViewingHistory.self, from: Data(contentsOf: url))
        guard result.version == 1, result.sourceID == sourceID else { throw ServerViewingHistoryError.invalidArchive }
        return result
    }

    public func synchronize(server: any MediaServer, now: Date = Date(), calendar: Calendar = .current) async throws -> ServerViewingHistory {
        let sourceID = ServerViewingHistory.sourceID(for: server.profile)
        let start = try read(sourceID: sourceID, now: now, calendar: calendar).recordedFrom
        let reader = ServerHistoryPageReader(server: server, since: start, now: now)
        return try await synchronize(sourceID: sourceID, now: now, calendar: calendar) { start, limit in
            try await reader.page(start: start, limit: limit)
        }
    }

    /// The injected page reader also allows pagination/cancellation tests without real accounts.
    public func synchronize(
        sourceID: String, now: Date, calendar: Calendar = .current,
        pageSize: Int = 200, maximumPages: Int = 100,
        fetchPage: @Sendable (Int, Int) async throws -> ServerPlayedItemsPage
    ) async throws -> ServerViewingHistory {
        generations[sourceID, default: 0] &+= 1
        let generation = generations[sourceID]!
        var archive = try read(sourceID: sourceID, now: now, calendar: calendar)
        var records: [String: ServerViewingRecord] = [:]
        var undated = 0
        var start = 0
        var finished = false
        let limit = max(pageSize, 1)
        for _ in 0..<max(maximumPages, 1) {
            try Task.checkCancellation()
            let page = try await fetchPage(start, limit)
            try Task.checkCancellation()
            guard generations[sourceID] == generation else { throw CancellationError() }
            var crossedBoundary = false
            for row in page.items {
                guard row.item.kind == .movie || row.item.kind == .episode,
                      !row.item.id.isEmpty, row.item.playState?.played == true else { continue }
                guard let date = row.lastPlayedAt else { undated += 1; continue }
                guard date >= archive.recordedFrom else { crossedBoundary = true; continue }
                // Clock skew is tolerated briefly; distant-future dates are not history.
                guard date <= now.addingTimeInterval(300) else { continue }
                if let prior = records[row.item.id], prior.watchedAt >= date { continue }
                records[row.item.id] = ServerViewingRecord(item: row.item, watchedAt: date)
            }
            start += page.items.count
            // Both implementations request DatePlayed descending. Scan the entire boundary page.
            let reachedEnd = page.totalRecordCount.map { start >= $0 } ?? (page.items.count < limit)
            if page.items.isEmpty || reachedEnd || crossedBoundary { finished = true; break }
        }
        guard finished else { throw ServerViewingHistoryError.scanLimit }
        try Task.checkCancellation()
        guard generations[sourceID] == generation else { throw CancellationError() }
        archive.records = records.values.sorted {
            $0.watchedAt == $1.watchedAt ? $0.id < $1.id : $0.watchedAt > $1.watchedAt
        }
        archive.undatedItemCount = undated
        archive.syncedAt = now
        // A full reconciliation also removes items whose completed flag was cleared remotely.
        let data = try JSONEncoder().encode(archive)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: archiveURL(sourceID), options: .atomic)
        return archive
    }

    private func archiveURL(_ sourceID: String) -> URL {
        let key = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
}

/// Episode DTOs often omit genres. Resolve their own SeriesId in this same server/account.
/// Cache each parent once per sync and bound optional lookups; failed metadata never loses history.
actor ServerHistoryPageReader {
    let server: any MediaServer
    let since: Date
    let now: Date
    private var parentGenres: [String: [String]] = [:]
    private let maximumParentLookups: Int
    private let enrichmentStartedAt = ContinuousClock.now

    init(server: any MediaServer, since: Date, now: Date, maximumParentLookups: Int = 50) {
        self.server = server
        self.since = since
        self.now = now
        self.maximumParentLookups = maximumParentLookups
    }

    func page(start: Int, limit: Int) async throws -> ServerPlayedItemsPage {
        var page = try await server.playedItemsPage(startIndex: start, limit: limit)
        for index in page.items.indices {
            let row = page.items[index]
            guard row.item.kind == .episode, row.item.genres.isEmpty, row.item.playState?.played == true,
                  let date = row.lastPlayedAt, date >= since, date <= now.addingTimeInterval(300),
                  let seriesID = row.item.seriesID, !seriesID.isEmpty else { continue }
            try Task.checkCancellation()
            if parentGenres[seriesID] == nil, parentGenres.count < maximumParentLookups,
               enrichmentStartedAt.duration(to: .now) < .seconds(5) {
                do {
                    parentGenres[seriesID] = try await lookupGenres(seriesID: seriesID)
                } catch {
                    if CancellationClassifier.isCancellation(error) { throw error }
                    parentGenres[seriesID] = []
                }
            }
            page.items[index].item.genres = parentGenres[seriesID] ?? []
        }
        return page
    }

    private func lookupGenres(seriesID: String) async throws -> [String] {
        let server = server
        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                let parent = try await server.item(seriesID)
                return parent.kind == .series ? parent.genres : []
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }
}
