import Foundation
import OSLog

/// The severity written to both the system log and the JSONL file.
public enum DiagnosticLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

/// A JSON-compatible structured value. Literal conformances keep call sites concise.
public enum DiagnosticValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case double(Double)
    case boolean(Bool)
    case null

    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: UInt64) { self = .unsignedInteger(value) }
    public init(_ value: Double) { self = .double(value.isFinite ? value : 0) }
    public init(_ value: Bool) { self = .boolean(value) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    fileprivate var logDescription: String {
        switch self {
        case .string(let value): return String(reflecting: value)
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .double(let value): return String(value)
        case .boolean(let value): return String(value)
        case .null: return "null"
        }
    }
}

extension DiagnosticValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension DiagnosticValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension DiagnosticValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value.isFinite ? value : 0) }
}

extension DiagnosticValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

extension DiagnosticValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

/// Suppress repeated records for a time window while preserving a count of what was dropped.
public struct DiagnosticThrottle: Hashable, Sendable {
    public let key: String
    public let interval: TimeInterval

    public init(key: String, interval: TimeInterval) {
        self.key = key
        self.interval = interval.isFinite ? max(0, interval) : 0
    }
}

/// A small, process-wide diagnostic logger. File writes happen on a private serial queue;
/// callers only pay sanitization, OSLog submission, and queueing on the hot path.
public final class DiagnosticLogger: @unchecked Sendable {
    private static let defaultBackend = DiagnosticBackend(
        directory: DiagnosticBackend.defaultDirectory,
        maxFileBytes: 2 * 1024 * 1024,
        retainedArchives: 3,
        maxFileAge: 30 * 24 * 60 * 60,
        maintenanceInterval: 24 * 60 * 60
    )

    private let subsystem: String
    private let category: String
    private let osLogger: Logger
    private let backend: DiagnosticBackend
    private let clock: @Sendable () -> Date
    private let throttleLock = NSLock()
    private var throttles: [String: ThrottleState] = [:]

    private struct ThrottleState: Sendable {
        var lastEmission: Date
        var suppressed: UInt64
        var level: DiagnosticLevel
    }

    public convenience init(subsystem: String = "dev.jumusu.OcPlayer", category: String) {
        self.init(subsystem: subsystem, category: category,
                  backend: Self.defaultBackend, now: Date.init)
    }

    /// Internal initializer used by tests and by host applications that need an isolated sink.
    convenience init(subsystem: String,
         category: String,
         directory: URL,
         maxFileBytes: Int,
         retainedArchives: Int = 3,
         maxFileAge: TimeInterval = 30 * 24 * 60 * 60,
         maintenanceInterval: TimeInterval = 24 * 60 * 60,
         now: @escaping @Sendable () -> Date = Date.init,
         emitToOSLog: Bool = false) {
        self.init(subsystem: subsystem, category: category,
                  backend: DiagnosticBackend(directory: directory,
                                             maxFileBytes: maxFileBytes,
                                             retainedArchives: retainedArchives,
                                             maxFileAge: maxFileAge,
                                             maintenanceInterval: maintenanceInterval,
                                             now: now,
                                             emitToOSLog: emitToOSLog),
                  now: now)
    }

    private init(subsystem: String,
                 category: String,
                 backend: DiagnosticBackend,
                 now: @escaping @Sendable () -> Date) {
        self.subsystem = subsystem
        self.category = category
        self.backend = backend
        self.clock = now
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    public var fileURL: URL { backend.fileURL }

    public func log(level: DiagnosticLevel,
                    _ message: @autoclosure () -> String,
                    fields: [String: DiagnosticValue] = [:],
                    throttle: DiagnosticThrottle? = nil) {
        let now = clock()
        let safeMessage = DiagnosticRedactor.redact(message())
        let safeFields = DiagnosticRedactor.redact(fields)
        let suppressed = takeThrottleDecision(throttle, level: level, now: now)
        guard let suppressed else { return }
        submit(level: level, message: safeMessage, fields: safeFields,
               suppressed: suppressed, date: now)
    }

    public func debug(_ message: @autoclosure () -> String,
                      fields: [String: DiagnosticValue] = [:],
                      throttle: DiagnosticThrottle? = nil) {
        log(level: .debug, message(), fields: fields, throttle: throttle)
    }

    public func info(_ message: @autoclosure () -> String,
                     fields: [String: DiagnosticValue] = [:],
                     throttle: DiagnosticThrottle? = nil) {
        log(level: .info, message(), fields: fields, throttle: throttle)
    }

    public func notice(_ message: @autoclosure () -> String,
                       fields: [String: DiagnosticValue] = [:],
                       throttle: DiagnosticThrottle? = nil) {
        log(level: .notice, message(), fields: fields, throttle: throttle)
    }

    public func warning(_ message: @autoclosure () -> String,
                        fields: [String: DiagnosticValue] = [:],
                        throttle: DiagnosticThrottle? = nil) {
        log(level: .warning, message(), fields: fields, throttle: throttle)
    }

    public func error(_ message: @autoclosure () -> String,
                      fields: [String: DiagnosticValue] = [:],
                      throttle: DiagnosticThrottle? = nil) {
        log(level: .error, message(), fields: fields, throttle: throttle)
    }

    public func critical(_ message: @autoclosure () -> String,
                         fields: [String: DiagnosticValue] = [:],
                         throttle: DiagnosticThrottle? = nil) {
        log(level: .critical, message(), fields: fields, throttle: throttle)
    }

    /// Wait until all queued JSONL writes have completed and the current file is synchronized.
    public func flush() {
        emitPendingSuppressionSummaries()
        backend.flush()
    }

    /// Export all retained archives followed by the current JSONL file.
    public func exportData() throws -> Data {
        emitPendingSuppressionSummaries()
        return try backend.exportData()
    }

    /// Read back the most recent entries from the current JSONL file.
    /// Archives are intentionally excluded: rotated files are already aggregated
    /// by `exportData()`, and the live file alone is enough for the settings UI.
    public func readRecords(limit: Int = 200) throws -> [DiagnosticEntry] {
        try backend.readEntries(limit: limit)
    }

    /// Current file size and record count. `nil` when the file has not been created yet.
    public func summary() -> DiagnosticSummary? {
        backend.summary()
    }

    public func clear() throws {
        throttleLock.lock()
        throttles.removeAll(keepingCapacity: true)
        throttleLock.unlock()
        try backend.clear()
    }

    /// Remove retained files older than the configured retention window.
    /// The backend also performs this check automatically at most once per day
    /// while writing; this explicit hook is useful for app-level maintenance timers.
    public func performMaintenance() {
        backend.performMaintenance()
    }

    private func submit(level: DiagnosticLevel,
                        message: String,
                        fields: [String: DiagnosticValue],
                        suppressed: UInt64,
                        date: Date) {
        var record = DiagnosticEntry(timestamp: date,
                                     level: level.rawValue,
                                     subsystem: DiagnosticRedactor.redact(subsystem),
                                     category: DiagnosticRedactor.redact(category),
                                     message: message,
                                     fields: fields)
        if suppressed > 0 { record.suppressed = suppressed }

        var suffix = ""
        if !fields.isEmpty {
            let values = fields.keys.sorted().compactMap { key -> String? in
                guard let value = fields[key] else { return nil }
                return "\(key)=\(value.logDescription)"
            }
            suffix += " fields={\(values.joined(separator: ","))}"
        }
        if suppressed > 0 { suffix += " suppressed=\(suppressed)" }
        osLogger.log(level: level.osLogType,
                     "\(message, privacy: .public)\(suffix, privacy: .public)")
        backend.append(record)
    }

    private func takeThrottleDecision(_ throttle: DiagnosticThrottle?,
                                      level: DiagnosticLevel,
                                      now: Date) -> UInt64? {
        guard let throttle, throttle.interval > 0 else { return 0 }
        throttleLock.lock()
        defer { throttleLock.unlock() }
        if var state = throttles[throttle.key] {
            let elapsed = now.timeIntervalSince(state.lastEmission)
            if elapsed >= 0, elapsed < throttle.interval {
                state.suppressed = state.suppressed == .max ? .max : state.suppressed + 1
                state.level = level
                throttles[throttle.key] = state
                return nil
            }
            let count = state.suppressed
            state.lastEmission = now
            state.suppressed = 0
            state.level = level
            throttles[throttle.key] = state
            return count
        }
        throttles[throttle.key] = ThrottleState(lastEmission: now, suppressed: 0, level: level)
        return 0
    }

    private func emitPendingSuppressionSummaries() {
        let pending: [(String, UInt64, DiagnosticLevel)]
        let now = clock()
        throttleLock.lock()
        pending = throttles.compactMap { key, state in
            guard state.suppressed > 0 else { return nil }
            return (key, state.suppressed, state.level)
        }
        for key in throttles.keys {
            guard var state = throttles[key], state.suppressed > 0 else { continue }
            state.suppressed = 0
            state.lastEmission = now
            throttles[key] = state
        }
        throttleLock.unlock()

        for (key, count, level) in pending {
            submit(level: level,
                   message: "Suppressed repeated diagnostic events",
                   fields: ["throttle_key": .string(DiagnosticRedactor.redact(key))],
                   suppressed: count,
                   date: now)
        }
    }
}

/// One JSONL record, decodable from disk so the settings UI can surface
/// recent errors and the export path can be inspected.
public struct DiagnosticEntry: Codable, Sendable, Identifiable, Equatable {
    public let timestamp: Date
    public let level: String
    public let subsystem: String
    public let category: String
    public let message: String
    public let fields: [String: DiagnosticValue]
    public var suppressed: UInt64?

    public init(timestamp: Date, level: String, subsystem: String, category: String,
                message: String, fields: [String: DiagnosticValue], suppressed: UInt64? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.fields = fields
        self.suppressed = suppressed
    }

    public var id: String { "\(timestamp.timeIntervalSince1970)-\(category)-\(message)" }

    public var diagnosticLevel: DiagnosticLevel? { DiagnosticLevel(rawValue: level) }
}

/// Size / count of the current JSONL file, for the diagnostics UI.
public struct DiagnosticSummary: Sendable, Equatable {
    public let fileSizeBytes: Int64
    public let recordCount: Int

    public init(fileSizeBytes: Int64, recordCount: Int) {
        self.fileSizeBytes = fileSizeBytes
        self.recordCount = recordCount
    }
}

private final class DiagnosticBackend: @unchecked Sendable {
    static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/OcPlayer", isDirectory: true)
    }()

    let fileURL: URL
    private let directory: URL
    private let maxFileBytes: Int
    private let retainedArchives: Int
    private let maxFileAge: TimeInterval
    private let maintenanceInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "dev.jumusu.DiagnosticsKit.file-sink")
    private let encoder: JSONEncoder
    private let sinkLogger: Logger
    private var handle: FileHandle?
    private var currentBytes = 0
    private var lastMaintenanceDate: Date?
    private let emitToOSLog: Bool

    init(directory: URL,
         maxFileBytes: Int,
         retainedArchives: Int,
         maxFileAge: TimeInterval = 30 * 24 * 60 * 60,
         maintenanceInterval: TimeInterval = 24 * 60 * 60,
         now: @escaping @Sendable () -> Date = Date.init,
         emitToOSLog: Bool = true) {
        self.directory = directory
        self.maxFileBytes = max(1, maxFileBytes)
        self.retainedArchives = max(0, retainedArchives)
        self.maxFileAge = maxFileAge.isFinite ? max(0, maxFileAge) : 0
        self.maintenanceInterval = maintenanceInterval.isFinite ? max(0, maintenanceInterval) : 0
        self.now = now
        self.fileURL = directory.appendingPathComponent("diagnostics.jsonl")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.sinkLogger = Logger(subsystem: "dev.jumusu.OcPlayer", category: "DiagnosticsKit.FileSink")
        self.emitToOSLog = emitToOSLog
    }

    func append(_ record: DiagnosticEntry) {
        queue.async { [self] in
            do {
                var data = try encoder.encode(record) + Data([0x0A])
                if data.count > maxFileBytes {
                    let replacement = DiagnosticEntry(
                        timestamp: record.timestamp,
                        level: DiagnosticLevel.warning.rawValue,
                        subsystem: record.subsystem,
                        category: record.category,
                        message: "Diagnostic entry omitted because it exceeded the file size limit",
                        fields: ["encoded_bytes": .integer(Int64(data.count))]
                    )
                    data = try encoder.encode(replacement) + Data([0x0A])
                    guard data.count <= maxFileBytes else { return }
                }
                try write(data)
            } catch {
                report(error)
            }
        }
    }

    /// Snapshot the live file: newest entries first, capped at `limit`.
    ///
    /// 只解码文件**尾部**的 `limit` 行：日志单文件上限 2 MB，为了留下最后 40 条
    /// 而把几千行全解一遍纯属白烧——设置页打开时调用方还在等这个结果。
    func readEntries(limit: Int) throws -> [DiagnosticEntry] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }
        return try queue.sync {
            try handle?.synchronize()
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            else { return [] }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return Self.lastLines(in: data, count: limit).compactMap { line in
                try? decoder.decode(DiagnosticEntry.self, from: line)
            }
            .reversed()
        }
    }

    /// 从尾部倒着找换行，最多取回 `count` 行；返回顺序仍是文件顺序。
    /// 每行都拷成独立 `Data`，不把 mmap 切片传给解码器。
    private static func lastLines(in data: Data, count: Int) -> [Data] {
        var lines: [Data] = []
        lines.reserveCapacity(count)
        var end = data.endIndex
        while end > data.startIndex, lines.count < count {
            var start = end
            while start > data.startIndex, data[data.index(before: start)] != 0x0A {
                start = data.index(before: start)
            }
            if start < end {
                lines.append(Data(data[start..<end]))
            }
            // 越过这一行前面的那个换行符。
            end = start > data.startIndex ? data.index(before: start) : data.startIndex
        }
        return lines.reversed()
    }

    func summary() -> DiagnosticSummary? {
        queue.sync {
            try? handle?.synchronize()
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            else { return nil }
            // 逐字节数换行：`filter{}.count` 会先物化出一个几万元素的字节数组。
            var recordCount = 0
            data.withUnsafeBytes { buffer in
                for byte in buffer where byte == 0x0A { recordCount += 1 }
            }
            return DiagnosticSummary(fileSizeBytes: size, recordCount: recordCount)
        }
    }

    func flush() {
        queue.sync {
            do { try handle?.synchronize() }
            catch { report(error) }
        }
    }

    func performMaintenance() {
        queue.sync {
            do { try removeExpiredFiles(referenceDate: now(), force: true) }
            catch { report(error) }
        }
    }

    func exportData() throws -> Data {
        try queue.sync {
            try handle?.synchronize()
            var output = Data()
            let urls = Array(retainedArchiveURLs.reversed()) + [fileURL]
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                output.append(try Data(contentsOf: url))
            }
            return output
        }
    }

    func clear() throws {
        try queue.sync {
            try handle?.close()
            handle = nil
            currentBytes = 0
            let urls = [fileURL] + retainedArchiveURLs
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func write(_ data: Data) throws {
        try ensureDirectory()
        try removeExpiredFiles(referenceDate: now(), force: false)
        if handle == nil {
            currentBytes = fileSize(at: fileURL)
        }
        if currentBytes > maxFileBytes {
            try handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: fileURL)
            currentBytes = 0
        }
        if currentBytes > 0, currentBytes + data.count > maxFileBytes {
            try rotate()
        }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: fileURL)
            try handle?.seekToEnd()
            currentBytes = fileSize(at: fileURL)
        }
        try handle?.write(contentsOf: data)
        currentBytes += data.count
    }

    private func rotate() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        guard retainedArchives > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            currentBytes = 0
            return
        }
        for index in stride(from: retainedArchives, through: 1, by: -1) {
            let source = index == 1 ? fileURL : archiveURL(index - 1)
            let destination = archiveURL(index)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        currentBytes = 0
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeExpiredFiles(referenceDate: Date, force: Bool) throws {
        if !force, let lastMaintenanceDate,
           referenceDate.timeIntervalSince(lastMaintenanceDate) < maintenanceInterval {
            return
        }
        lastMaintenanceDate = referenceDate

        let cutoff = referenceDate.addingTimeInterval(-maxFileAge)
        let urls = [fileURL] + retainedArchiveURLs
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            let isExpired = maxFileAge == 0
                || values.contentModificationDate.map { $0 < cutoff } == true
            let isOversized = fileSize(at: url) > maxFileBytes
            guard isExpired || isOversized else { continue }
            if url == fileURL {
                try handle?.close()
                handle = nil
                currentBytes = 0
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func archiveURL(_ index: Int) -> URL {
        fileURL.appendingPathExtension(String(index))
    }

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private var retainedArchiveURLs: [URL] {
        guard retainedArchives > 0 else { return [] }
        return (1...retainedArchives).map(archiveURL)
    }

    private func report(_ error: Error) {
        guard emitToOSLog else { return }
        sinkLogger.error("JSONL sink failure: \(String(describing: error), privacy: .private)")
    }
}
