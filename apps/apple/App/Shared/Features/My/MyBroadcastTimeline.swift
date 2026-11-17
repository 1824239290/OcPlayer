import BangumiKit
import CoreModel
import DiagnosticsKit
import Foundation

/// Public schedule data; never receives media-server credentials.
struct MyBroadcastRecord: Codable, Equatable, Sendable {
    struct Site: Codable, Equatable, Sendable {
        var site: String
        var id: String?
    }
    var title: String
    var titleTranslate: [String: [String]]?
    var type: String
    var begin: String?
    var broadcast: String?
    var end: String?
    var sites: [Site]

    var subjectID: Int? { sites.first { $0.site == "bangumi" }?.id.flatMap(Int.init) }
    var titles: [String] { [title] + (titleTranslate?.values.flatMap { $0 } ?? []) }
    var tmdbSeason: Int? {
        for site in sites where site.site == "tmdb" {
            let parts = (site.id ?? "").split(separator: "/")
            if parts.count == 4, parts[0] == "tv", parts[2] == "season" { return Int(parts[3]) }
        }
        return nil
    }
    var schedule: MyBroadcastSchedule? {
        if let broadcast, !broadcast.isEmpty { return MyBroadcastSchedule(broadcast, end: end) }
        // bangumi-data documents begin as the compatibility fallback for missing broadcast.
        guard let begin, !begin.isEmpty else { return nil }
        return MyBroadcastSchedule("R/\(begin)/P7D", end: end)
    }
    func isUpdating(at now: Date) -> Bool {
        guard type == "tv" || type == "web" else { return false }
        if let begin = MyBroadcastSchedule.date(begin), begin > now { return false }
        if let end = MyBroadcastSchedule.date(end), end < now { return false }
        if let broadcast, broadcast.hasSuffix("/P0D") { return false }
        return true
    }
}

struct MyBroadcastSchedule: Equatable, Sendable {
    var anchor: Date
    var days: Int?
    var months: Int?
    var end: Date?

    init?(_ value: String, end: String?) {
        let parts = value.split(separator: "/")
        guard parts.count == 3, parts[0] == "R", let date = Self.date(String(parts[1])) else { return nil }
        anchor = date
        self.end = Self.date(end)
        switch parts[2] {
        case "P1D": days = 1
        case "P7D": days = 7
        case "P1M": months = 1
        default: return nil
        }
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Source recurrence is in UTC; render occurrences in the user's calendar/time zone.
    func occurrence(on day: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard let finish = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        var candidate: Date
        if let days {
            let interval = Double(days) * 86_400
            let steps = max(0, ceil(start.timeIntervalSince(anchor) / interval))
            candidate = anchor.addingTimeInterval(steps * interval)
        } else {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let steps = max(0, utc.dateComponents([.month], from: anchor, to: start).month ?? 0)
            guard let date = utc.date(byAdding: .month, value: steps, to: anchor) else { return nil }
            candidate = date
            if candidate < start {
                guard let next = utc.date(byAdding: .month, value: steps + 1, to: anchor) else { return nil }
                candidate = next
            }
        }
        guard candidate >= start, candidate < finish, end.map({ candidate <= $0 }) ?? true else { return nil }
        return candidate
    }
}

struct MyBroadcastEntry: Equatable, Identifiable, Sendable {
    var subject: BangumiSubjectDTO
    var mediaID: String
    var weekday: Int
    var schedule: MyBroadcastSchedule?
    var id: Int { subject.id }
}

struct MyBroadcastOccurrence: Identifiable {
    var entry: MyBroadcastEntry
    var date: Date?
    var id: Int { entry.id }
    func subtitle(calendar: Calendar) -> String {
        guard let date else { return "更新时间待定" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: date)) 更新"
    }
}

enum MyBroadcastTimeline {
    static func build(watching: [BangumiSubjectDTO], calendar: [BangumiCalendarDayDTO],
                      records: [MyBroadcastRecord], library: [MediaItem],
                      links: [String: Int], now: Date) -> [MyBroadcastEntry] {
        let onAir = Dictionary(calendar.flatMap { day in day.items.map { ($0.id, day.id) } },
                               uniquingKeysWith: { first, _ in first })
        let data = Dictionary(records.compactMap { record in record.subjectID.map { ($0, record) } },
                              uniquingKeysWith: { _, last in last })
        var seen = Set<Int>()
        return watching.compactMap { subject in
            guard seen.insert(subject.id).inserted, let weekday = onAir[subject.id] else { return nil }
            let record = data[subject.id]
            if let record, !record.isUpdating(at: now) { return nil }
            guard let media = match(subject: subject, record: record, library: library, links: links) else { return nil }
            return MyBroadcastEntry(subject: subject, mediaID: media.id, weekday: weekday,
                                    schedule: record?.schedule)
        }
    }

    static func occurrences(_ entries: [MyBroadcastEntry], weekday: Int, now: Date,
                            calendar: Calendar = .current) -> [MyBroadcastOccurrence] {
        let today = calendar.startOfDay(for: now)
        let currentWeekday = (calendar.component(.weekday, from: today) + 5) % 7 + 1
        guard let day = calendar.date(byAdding: .day, value: weekday - currentWeekday, to: today) else { return [] }
        return entries.compactMap { entry in
            if let schedule = entry.schedule {
                guard schedule.end.map({ $0 >= now }) ?? true,
                      let date = schedule.occurrence(on: day, calendar: calendar) else { return nil }
                return MyBroadcastOccurrence(entry: entry, date: date)
            }
            return entry.weekday == weekday ? MyBroadcastOccurrence(entry: entry, date: nil) : nil
        }.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            return $0.id < $1.id
        }
    }

    /// Existing explicit links and external IDs take priority; title fallback is exact,
    /// preserving season/part words so that another season cannot establish availability.
    static func match(subject: BangumiSubjectDTO, record: MyBroadcastRecord?,
                      library: [MediaItem], links: [String: Int]) -> MediaItem? {
        let available = library.filter {
            guard ($0.kind == .series || $0.kind == .season), ($0.childCount.map { $0 > 0 } ?? true) else { return false }
            // A series container alone cannot prove a later season is in the library.
            if let season = record?.tmdbSeason, season > 1 {
                return $0.kind == .season && $0.seasonNumber == season
            }
            return true
        }
        if let linked = available.first(where: { links[$0.id] == subject.id }) { return linked }
        let titles = Set(([subject.name, subject.nameCN] + (record?.titles ?? [])).map(normalize).filter { !$0.isEmpty })
        for item in available where links[item.id] == nil {
            if let record {
                if let mal = item.malID, record.sites.contains(where: { $0.site == "mal" && $0.id == mal }) { return item }
                if let anilist = item.anilistID, record.sites.contains(where: { $0.site == "aniList" && $0.id == anilist }) { return item }
                for site in record.sites where site.site == "tmdb" {
                    let parts = (site.id ?? "").split(separator: "/")
                    guard parts.count >= 2, parts[0] == "tv" else { continue }
                    let parent = library.first { $0.id == item.seriesID }
                    // TMDB assigns seasons their own numeric IDs. A tv/.../season/... URL
                    // contains the parent show's ID, not that season's ProviderIds.Tmdb.
                    let showID = item.kind == .season ? parent?.tmdbID : item.tmdbID
                    guard showID == String(parts[1]) else { continue }
                    if parts.count == 2, item.kind == .series { return item }
                    if parts.count == 4, parts[2] == "season", item.kind == .season,
                       item.seasonNumber == Int(parts[3]) { return item }
                }
            }
            if [item.name, item.originalTitle ?? ""].contains(where: { titles.contains(normalize($0)) }) { return item }
        }
        return nil
    }

    private static func normalize(_ raw: String) -> String {
        let simplified = raw.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? raw
        let folded = simplified.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                                        locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// One shared public download, cached six hours on disk; offline refresh retains the last dataset.
actor MyBroadcastDataStore {
    static let shared = MyBroadcastDataStore()
    static let sourceURL = URL(string: "https://unpkg.com/bangumi-data@0.3/dist/data.json")!
    private struct Dataset: Codable { var items: [MyBroadcastRecord] }
    private struct Snapshot: Codable { var fetchedAt: Date; var items: [MyBroadcastRecord] }
    private var snapshot: Snapshot?
    private var inFlight: Task<[MyBroadcastRecord], Error>?
    private let directory: URL
    private let session: URLSession
    init(directory: URL = OcPlayerStorage.defaultRoot.appending(path: "BroadcastSchedule"), session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    func load(now: Date = Date()) async throws -> [MyBroadcastRecord] {
        if snapshot == nil, let data = try? Data(contentsOf: directory.appending(path: "bangumi-data.json")) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        if let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < 6 * 3_600 { return snapshot.items }
        if let inFlight {
            do { return try await inFlight.value }
            catch {
                if let snapshot { return snapshot.items }
                throw error
            }
        }
        let session = session
        let task = Task {
            var request = URLRequest(url: Self.sourceURL)
            request.timeoutInterval = 25
            request.setValue("OcPlayer/0.3.0 (broadcast schedule)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let items = try JSONDecoder().decode(Dataset.self, from: data).items
            guard !items.isEmpty else { throw URLError(.cannotParseResponse) }
            return items
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            let items = try await task.value
            let result = Snapshot(fetchedAt: now, items: items)
            snapshot = result
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: directory.appending(path: "bangumi-data.json"), options: .atomic)
            }
            return items
        } catch {
            if let snapshot { return snapshot.items }
            throw error
        }
    }
}
