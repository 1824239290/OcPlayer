import CoreModel
import CryptoKit
import DiagnosticsKit
import Foundation
import JellyfinKit
import PlaybackKit

/// One session's cumulative real viewing time on one local calendar day.
/// This archive never writes a server/Bangumi completed flag or stores a stream URL/token.
struct AppPlaybackRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceID: String
    var item: MediaItem
    var day: Date
    var watchedAt: Date
    var seconds: Double
}

actor AppPlaybackHistoryStore {
    static let shared = AppPlaybackHistoryStore()
    static let localSourceID = "local"
    static let changed = Notification.Name("OcPlayer.AppPlaybackHistoryChanged")
    private let directory: URL

    init(directory: URL = OcPlayerStorage.directory("ViewingHistory")) {
        self.directory = directory
    }

    private func url(_ sourceID: String) -> URL {
        let digest = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "app-\(digest).json")
    }

    func read(sourceID: String) throws -> [AppPlaybackRecord] {
        let path = url(sourceID)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let records = try JSONDecoder().decode([AppPlaybackRecord].self, from: Data(contentsOf: path))
        guard records.allSatisfy({ $0.sourceID == sourceID && $0.seconds.isFinite && $0.seconds > 0 }) else {
            throw ServerViewingHistoryError.invalidArchive
        }
        return records
    }

    /// Cumulative upserts survive repeated/out-of-order checkpoints without double counting.
    func save(_ record: AppPlaybackRecord) throws {
        guard record.seconds.isFinite, record.seconds > 0 else { return }
        var records = try read(sourceID: record.sourceID)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            guard record.seconds >= records[index].seconds else { return }
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.watchedAt > $1.watchedAt }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url(record.sourceID), options: .atomic)
    }
}

@MainActor
final class AppPlaybackRecorder {
    private let store: AppPlaybackHistoryStore
    private let calendar: Calendar
    private var clock = PlaybackWatchClock()
    private var sourceID = ""
    private var item: MediaItem?
    private var sessionID = UUID()
    private var records: [Date: AppPlaybackRecord] = [:]
    private var lastSaveTime = 0.0
    private var savedSeconds: [Date: Double] = [:]
    private(set) var pendingWrite: Task<Void, Never>?

    init(store: AppPlaybackHistoryStore = .shared, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    func start(sourceID: String, item: MediaItem) {
        finish()
        self.sourceID = sourceID
        self.item = item
        sessionID = UUID()
        records = [:]
        savedSeconds = [:]
        clock.reset()
        lastSaveTime = ProcessInfo.processInfo.systemUptime
    }

    func sample(position: Double, playing: Bool, buffering: Bool, rate: Double,
                time: Double = ProcessInfo.processInfo.systemUptime, date: Date = Date()) {
        guard let item else { return }
        let seconds = clock.sample(position: position, playing: playing, buffering: buffering, rate: rate, time: time)
        if seconds > 0 {
            // Split midnight at local calendar boundaries, including 23/25-hour DST days.
            var start = date.addingTimeInterval(-seconds)
            while start < date {
                let day = calendar.startOfDay(for: start)
                let end = min(date, calendar.date(byAdding: .day, value: 1, to: day) ?? date)
                guard end > start else { break }
                var record = records[day] ?? AppPlaybackRecord(
                    id: "\(sessionID.uuidString):\(day.timeIntervalSince1970)", sourceID: sourceID,
                    item: item, day: day, watchedAt: end, seconds: 0)
                record.seconds += end.timeIntervalSince(start)
                record.watchedAt = calendar.isDate(end, inSameDayAs: day) ? end : end.addingTimeInterval(-0.00001)
                records[day] = record
                start = end
            }
        }
        if !playing || buffering || time - lastSaveTime >= 15 {
            checkpoint()
            lastSaveTime = time
        }
    }

    func discontinuity() { clock.reset() }

    @discardableResult
    func checkpoint() -> Task<Void, Never>? {
        let snapshot = Array(records.values)
        guard !snapshot.isEmpty else { return pendingWrite }
        let totals = records.mapValues(\.seconds)
        guard totals != savedSeconds else { return pendingWrite }
        savedSeconds = totals
        let previous = pendingWrite
        let store = store
        let session = sessionID
        pendingWrite = Task {
            await previous?.value
            do {
                for record in snapshot { try await store.save(record) }
                NotificationCenter.default.post(name: AppPlaybackHistoryStore.changed, object: nil)
            } catch {
                if self.sessionID == session { self.savedSeconds = [:] }
                PlaybackLog.error("App 播放时长保存失败: \(error)")
            }
        }
        return pendingWrite
    }

    @discardableResult
    func finish() -> Task<Void, Never>? {
        let task = checkpoint()
        item = nil
        records = [:]
        savedSeconds = [:]
        clock.reset()
        return task
    }

    static func localItem(for request: PlaybackRequest) -> MediaItem {
        // Hash the URI so local filenames/URLs cannot collide, without persisting credentials.
        var components = URLComponents(string: request.uri)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let identity = components?.string ?? request.uri
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let title: String
        if let titleURL = URL(string: request.title), titleURL.scheme != nil {
            title = titleURL.lastPathComponent.isEmpty ? (titleURL.host ?? "直连播放") : titleURL.lastPathComponent
        } else { title = request.title }
        return MediaItem(id: "local:\(digest)", name: title, kind: .other)
    }
}
