import CoreModel
import Foundation
import JellyfinKit

struct MyViewingEntry: Equatable, Identifiable {
    var id: String
    var item: MediaItem
    var watchedAt: Date
    var actualSeconds: Double?
    var isCompleted: Bool
    var isLocalFile = false
    var estimatedSeconds: Double? {
        guard actualSeconds == nil, let seconds = item.runtimeSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
    var seconds: Double? { actualSeconds ?? estimatedSeconds }

    init(_ record: ServerViewingRecord) {
        id = record.id
        item = record.item
        watchedAt = record.watchedAt
        isCompleted = true
    }

    init(_ record: AppPlaybackRecord, completed: Bool) {
        id = "app:\(record.sourceID):\(record.item.id):\(record.day.timeIntervalSince1970)"
        item = record.item
        watchedAt = record.watchedAt
        actualSeconds = record.seconds
        isCompleted = completed
        isLocalFile = record.sourceID == AppPlaybackHistoryStore.localSourceID
    }
}

struct MyViewingTotals: Equatable {
    var movies = 0
    var episodes = 0
    var estimatedSeconds = 0.0
    var unknownRuntime = 0
    var actualSeconds = 0.0
    var playbackFragments = 0
    var seconds: Double { actualSeconds + estimatedSeconds }

    init(records: [ServerViewingRecord] = []) {
        self.init(records: records.map(MyViewingEntry.init))
    }

    init(records: [MyViewingEntry]) {
        for record in records {
            if record.isCompleted {
                if record.item.kind == .movie { movies += 1 }
                if record.item.kind == .episode { episodes += 1 }
            } else { playbackFragments += 1 }
            if let seconds = record.actualSeconds { actualSeconds += seconds; continue }
            if let seconds = record.estimatedSeconds { estimatedSeconds += seconds }
            else { unknownRuntime += 1 }
        }
    }
}

struct MyViewingDay: Identifiable, Equatable {
    var date: Date
    var totals: MyViewingTotals
    var isCovered: Bool
    var id: Date { date }
}

struct MyViewingGenre: Identifiable, Equatable {
    var name: String
    var seconds: Double
    var id: String

    init(name: String, seconds: Double, id: String? = nil) {
        self.name = name
        self.seconds = seconds
        self.id = id ?? "genre:\(name)"
    }
}

struct MyViewingTitle: Identifiable, Equatable {
    var id: String
    var name: String
    var seconds: Double
}

struct MyViewingGenreSample: Identifiable, Equatable {
    var date: Date
    var seconds: Double
    var id: Date { date }
}

struct MyViewingGenreTrend: Identifiable, Equatable {
    var name: String
    var samples: [MyViewingGenreSample]
    var previousSeconds: Double?
    var id: String { name }
    var seconds: Double { samples.reduce(0) { $0 + $1.seconds } }
}

/// App wall time takes precedence over a completed runtime estimate for the same item/day.
struct MyViewingStatistics {
    let history: ServerViewingHistory
    let now: Date
    let calendar: Calendar
    let entries: [MyViewingEntry]
    private let groupedDays: [Date: [MyViewingEntry]]
    var recordedFrom: Date {
        min(history.recordedFrom, entries.map { calendar.startOfDay(for: $0.watchedAt) }.min() ?? history.recordedFrom)
    }

    init(history: ServerViewingHistory, localRecords: [AppPlaybackRecord] = [], now: Date = Date(), calendar: Calendar = .current) {
        self.history = history
        self.now = now
        self.calendar = calendar
        struct Key: Hashable { let source: String; let item: String; let day: Date }
        func key(_ item: String, _ date: Date, source: String) -> Key {
            Key(source: source, item: item, day: calendar.startOfDay(for: date))
        }
        let completed = Set(history.records.map { key($0.item.id, $0.watchedAt, source: history.sourceID) })
        let grouped = Dictionary(grouping: localRecords.filter {
            ($0.sourceID == history.sourceID || $0.sourceID == AppPlaybackHistoryStore.localSourceID)
                && $0.seconds.isFinite && $0.seconds > 0 && $0.watchedAt <= now.addingTimeInterval(300)
        }) { key($0.item.id, $0.watchedAt, source: $0.sourceID) }
        var merged = history.records.filter {
            grouped[key($0.item.id, $0.watchedAt, source: history.sourceID)] == nil
        }.map(MyViewingEntry.init)
        for (key, sessions) in grouped {
            guard let latest = sessions.max(by: { $0.watchedAt < $1.watchedAt }) else { continue }
            var entry = MyViewingEntry(latest, completed: completed.contains(key))
            entry.id = "app:\(key.source):\(key.item):\(key.day.timeIntervalSince1970)"
            entry.actualSeconds = sessions.reduce(0) { $0 + $1.seconds }
            // Server parent enrichment may supply the genre missing from a playback DTO.
            if entry.item.genres.isEmpty,
               let serverRecord = history.records.first(where: { $0.item.id == latest.item.id && latest.sourceID == history.sourceID }) {
                entry.item.genres = serverRecord.item.genres
            }
            merged.append(entry)
        }
        entries = merged
        groupedDays = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.watchedAt) }
    }

    var today: Date { calendar.startOfDay(for: now) }
    var total: MyViewingTotals { MyViewingTotals(records: entries) }

    func records(on day: Date) -> [MyViewingEntry] {
        groupedDays[calendar.startOfDay(for: day)] ?? []
    }

    func totals(on day: Date) -> MyViewingTotals { MyViewingTotals(records: records(on: day)) }

    func monthStart(containing date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    func records(inMonth month: Date) -> [MyViewingEntry] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        return entries.filter { $0.watchedAt >= interval.start && $0.watchedAt < interval.end }
    }

    func monthDays(_ month: Date) -> [MyViewingDay] {
        let start = monthStart(containing: month)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: start) }.map(day)
    }

    /// Fifteen Monday–Sunday columns. Unknown/pre-import and future dates remain distinguishable.
    var heatmapWeeks: [[MyViewingDay]] {
        let weekdayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -weekdayOffset, to: today) ?? today
        return (-14...0).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: monday) }.map(day)
        }
    }

    private func day(_ date: Date) -> MyViewingDay {
        MyViewingDay(date: date, totals: totals(on: date),
                     isCovered: date <= today && ((history.syncedAt != nil && date >= history.recordedFrom) || !records(on: date).isEmpty))
    }

    /// Multiple genre labels share a record's runtime, so the pie always sums to the total.
    func genres(in records: [MyViewingEntry]) -> [MyViewingGenre] {
        var values: [String: Double] = [:]
        for record in records {
            guard let seconds = record.seconds else { continue }
            let labels = Set(record.item.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if labels.isEmpty { values["未分类", default: 0] += seconds }
            else { for label in labels { values[label, default: 0] += seconds / Double(labels.count) } }
        }
        return values.map { MyViewingGenre(name: $0.key, seconds: $0.value) }.sorted {
            $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds
        }
    }

    var genreDistribution: [MyViewingGenre] {
        let all = genres(in: entries)
        guard all.count > 4 else { return all }
        var result = Array(all.prefix(3))
        // Reserved ID differs from a genuine server genre called “其他”.
        result.append(MyViewingGenre(name: "其余类型", seconds: all.dropFirst(3).reduce(0) { $0 + $1.seconds }, id: "remainder"))
        return result
    }

    func genreSeconds(_ name: String, on day: Date) -> Double {
        genres(in: records(on: day)).first { $0.name == name }?.seconds ?? 0
    }

    func topTitles(inMonth month: Date) -> [MyViewingTitle] {
        var titles: [String: MyViewingTitle] = [:]
        for record in records(inMonth: month) {
            guard let seconds = record.seconds else { continue }
            let item = record.item
            let id = item.kind == .episode ? "series:\(item.seriesID ?? "episode:\(item.id)")" : "movie:\(item.id)"
            var title = titles[id] ?? MyViewingTitle(id: id, name: item.seriesName ?? item.name, seconds: 0)
            title.seconds += seconds
            titles[id] = title
        }
        return Array(titles.values.sorted {
            $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds
        }.prefix(3))
    }

    var genreTrends: [MyViewingGenreTrend] {
        let dates = (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let recent = dates.flatMap { records(on: $0) }
        let previousDates = (-13 ... -7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let covered = previousDates.first.map { history.recordedFrom <= $0 && history.syncedAt != nil } ?? false
        return genres(in: recent).prefix(2).map { genre in
            MyViewingGenreTrend(name: genre.name,
                                samples: dates.map { MyViewingGenreSample(date: $0, seconds: genreSeconds(genre.name, on: $0)) },
                                previousSeconds: covered ? previousDates.reduce(0) { $0 + genreSeconds(genre.name, on: $1) } : nil)
        }
    }
}
