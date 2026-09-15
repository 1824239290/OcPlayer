import Foundation
import OSLog
import os

/// The severity written to both the system log and the JSONL file.
public enum DiagnosticLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    /// 严重度（声明顺序即从小到大），用于与最低落盘级别比较。
    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .critical: return 5
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.severity < rhs.severity
    }

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
        maxFileBytes: 20 * 1024 * 1024,
        maxRetainedFiles: 10,
        maxTotalBytes: 50 * 1024 * 1024,
        maxFileAge: 30 * 24 * 60 * 60,
        maintenanceInterval: 24 * 60 * 60
    )

    /// 进程级最低落盘级别（默认 `info`）。
    ///
    /// 低于它的记录在**消息求值、脱敏、节流判定之前**就返回：`@autoclosure` 的消息
    /// 因此不求值，热点日志在被过滤时零成本。App 启动与设置开关经
    /// `DiagnosticsSettings.apply()` 设置；`debug` 档用于排障（设置页「详细日志」）。
    private static let processMinimumLevel = OSAllocatedUnfairLock(initialState: DiagnosticLevel.info)

    public static var minimumLevel: DiagnosticLevel {
        processMinimumLevel.withLock { $0 }
    }

    public static func setMinimumLevel(_ level: DiagnosticLevel) {
        processMinimumLevel.withLock { $0 = level }
    }

    /// 进程级会话标识：一次启动一个，写进该进程产出的所有记录。
    /// 排障时要问「这几条是不是同一次运行」「弹幕注入与 seek 谁先」，靠它对时间线。
    /// 8 位十六进制：够 grep、也够区分，不需要全局唯一。
    public static let sessionID: String = String(
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()

    /// 记录序号：进程内单调递增，保证 `DiagnosticEntry.id` 唯一。
    private static let sequenceCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

    private static func nextSequence() -> UInt64 {
        sequenceCounter.withLock {
            $0 &+= 1
            return $0
        }
    }

    private let subsystem: String
    private let category: String
    private let osLogger: Logger
    private let backend: DiagnosticBackend
    private let clock: @Sendable () -> Date
    /// 实例级覆盖（隔离 sink 的测试用）；nil = 跟随进程级阈值。
    private let minimumLevelOverride: DiagnosticLevel?
    private let throttleLock = NSLock()
    private var throttles: [String: ThrottleState] = [:]

    private struct ThrottleState: Sendable {
        var lastEmission: Date
        var suppressed: UInt64
        var level: DiagnosticLevel
    }

    public convenience init(subsystem: String = "dev.jumusu.OcPlayer", category: String) {
        self.init(subsystem: subsystem, category: category,
                  backend: Self.defaultBackend, now: Date.init, minimumLevel: nil)
    }

    /// Internal initializer used by tests and by host applications that need an isolated sink.
    ///
    /// - Parameter minimumLevel: 实例级阈值覆盖；`nil`（默认）跟随进程级
    ///   `DiagnosticLogger.minimumLevel`。测试要观察 debug 级记录时传 `.debug`。
    convenience init(subsystem: String,
         category: String,
         directory: URL,
         maxFileBytes: Int,
         maxRetainedFiles: Int = 10,
         maxTotalBytes: Int = 50 * 1024 * 1024,
         maxFileAge: TimeInterval = 30 * 24 * 60 * 60,
         maintenanceInterval: TimeInterval = 24 * 60 * 60,
         now: @escaping @Sendable () -> Date = Date.init,
         emitToOSLog: Bool = false,
         minimumLevel: DiagnosticLevel? = nil,
         sessionID: String = DiagnosticLogger.sessionID) {
        self.init(subsystem: subsystem, category: category,
                  backend: DiagnosticBackend(directory: directory,
                                             maxFileBytes: maxFileBytes,
                                             maxRetainedFiles: maxRetainedFiles,
                                             maxTotalBytes: maxTotalBytes,
                                             maxFileAge: maxFileAge,
                                             maintenanceInterval: maintenanceInterval,
                                             now: now,
                                             emitToOSLog: emitToOSLog,
                                             sessionID: sessionID),
                  now: now,
                  minimumLevel: minimumLevel)
    }

    private init(subsystem: String,
                 category: String,
                 backend: DiagnosticBackend,
                 now: @escaping @Sendable () -> Date,
                 minimumLevel: DiagnosticLevel?) {
        self.subsystem = subsystem
        self.category = category
        self.backend = backend
        self.clock = now
        self.minimumLevelOverride = minimumLevel
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    public var fileURL: URL { backend.fileURL }

    /// 当前阈值下该级别是否会落盘。消息本身已是 `@autoclosure`（被过滤时天然不求值），
    /// 只有调用方还要为 `fields` 付构造成本时才需要先问一句。
    public func isEnabled(_ level: DiagnosticLevel) -> Bool {
        level >= (minimumLevelOverride ?? Self.minimumLevel)
    }

    public func log(level: DiagnosticLevel,
                    _ message: @autoclosure () -> String,
                    fields: [String: DiagnosticValue] = [:],
                    throttle: DiagnosticThrottle? = nil) {
        record(level: level, message: message, fields: fields, throttle: throttle)
    }

    public func debug(_ message: @autoclosure () -> String,
                      fields: [String: DiagnosticValue] = [:],
                      throttle: DiagnosticThrottle? = nil) {
        record(level: .debug, message: message, fields: fields, throttle: throttle)
    }

    public func info(_ message: @autoclosure () -> String,
                     fields: [String: DiagnosticValue] = [:],
                     throttle: DiagnosticThrottle? = nil) {
        record(level: .info, message: message, fields: fields, throttle: throttle)
    }

    public func notice(_ message: @autoclosure () -> String,
                       fields: [String: DiagnosticValue] = [:],
                       throttle: DiagnosticThrottle? = nil) {
        record(level: .notice, message: message, fields: fields, throttle: throttle)
    }

    public func warning(_ message: @autoclosure () -> String,
                        fields: [String: DiagnosticValue] = [:],
                        throttle: DiagnosticThrottle? = nil) {
        record(level: .warning, message: message, fields: fields, throttle: throttle)
    }

    public func error(_ message: @autoclosure () -> String,
                      fields: [String: DiagnosticValue] = [:],
                      throttle: DiagnosticThrottle? = nil) {
        record(level: .error, message: message, fields: fields, throttle: throttle)
    }

    public func critical(_ message: @autoclosure () -> String,
                         fields: [String: DiagnosticValue] = [:],
                         throttle: DiagnosticThrottle? = nil) {
        record(level: .critical, message: message, fields: fields, throttle: throttle)
    }

    /// 所有级别的唯一落点，顺序即成本顺序：
    /// ① 判级别（被过滤时消息**不求值**、节流状态**不受污染**）→ ② 判节流 →
    /// ③ 求值消息并脱敏 → ④ 落两个出口。
    private func record(level: DiagnosticLevel,
                        message: () -> String,
                        fields: [String: DiagnosticValue],
                        throttle: DiagnosticThrottle?) {
        guard isEnabled(level) else { return }
        let now = clock()
        let suppressed = takeThrottleDecision(throttle, level: level, now: now)
        guard let suppressed else { return }
        let safeMessage = DiagnosticRedactor.redact(message())
        let safeFields = DiagnosticRedactor.redact(fields)
        submit(level: level, message: safeMessage, fields: safeFields,
               suppressed: suppressed, date: now)
    }

    /// Wait until all queued JSONL writes have completed and the current file is synchronized.
    public func flush() {
        emitPendingSuppressionSummaries()
        backend.flush()
    }

    /// 有界等待版 flush（进程终止路径用）：`timeout` 内没落完就返回 false，
    /// 别为了最后几条日志把退出流程吊住。
    @discardableResult
    public func flush(timeout: TimeInterval) -> Bool {
        emitPendingSuppressionSummaries()
        return backend.flush(timeout: timeout)
    }

    /// Export all retained archives followed by the current JSONL file.
    public func exportData() throws -> Data {
        emitPendingSuppressionSummaries()
        return try backend.exportData()
    }

    /// 导出为**单个文本文件**：头部说明行 + 全部保留记录（归档在前、当前文件在后）。
    ///
    /// 单文件而非 zip：iOS 起不了 `ditto` 进程，双端行为一致，GitHub issue 也能直接附件。
    /// `headerLines` 由宿主提供（版本 / 平台 / 设备这类宿主知识），本包不猜。
    public func exportText(headerLines: [String]) throws -> String {
        emitPendingSuppressionSummaries()
        let body = String(decoding: try backend.exportData(), as: UTF8.self)
        return headerLines.joined(separator: "\n") + "\n\n" + body
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
                                     fields: fields,
                                     session: Self.sessionID,
                                     sequence: Self.nextSequence())
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
    /// 进程级会话标识（一次启动一个）：跨模块对齐「同一次运行」的记录。
    /// 旧文件里没有这个字段，解码为 nil。
    public var session: String?
    /// 进程内单调递增序号：`id` 唯一性的后盾（毫秒时间戳下同文案仍可能相撞）。
    public var sequence: UInt64?

    public init(timestamp: Date, level: String, subsystem: String, category: String,
                message: String, fields: [String: DiagnosticValue], suppressed: UInt64? = nil,
                session: String? = nil, sequence: UInt64? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.fields = fields
        self.suppressed = suppressed
        self.session = session
        self.sequence = sequence
    }

    /// 列表身份：新记录用「时间戳-序号」（同毫秒也不撞）；旧记录退回「时间戳-分类-文案」。
    public var id: String {
        if let sequence { return "\(timestamp.timeIntervalSince1970)-\(sequence)" }
        return "\(timestamp.timeIntervalSince1970)-\(category)-\(message)"
    }

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

/// 时间戳格式化器持有者：`ISO8601DateFormatter` 不是 `Sendable`（静态存储被 Swift 6 拒绝），
/// 但格式化/解析本身线程安全——与 `DiagnosticRedactor.SensitivePatterns` 同一处理方式。
private final class TimestampFormatters: @unchecked Sendable {
    static let shared = TimestampFormatters()

    /// 带小数秒（毫秒）：写盘用。
    let millis: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 秒级：历史记录是这么写的，解码兜底用。
    let seconds = ISO8601DateFormatter()

    /// 会话文件名里的时间戳（本地时区、人读友好；排序不依赖它——排序看 mtime）。
    let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private final class DiagnosticBackend: @unchecked Sendable {
    static let defaultDirectory: URL = {
        // 测试宿主（`xcodebuild test` 注入 App 进程）跑的是真实代码：让它写到临时目录。
        // 实测一次全量 AppTests 会在真实日志目录留下 6 个会话文件，还会混进用户报障时
        // 要发的诊断包；早先那 116 行残缺记录也是「测试宿主 + App」共写同一文件留下的。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "OcPlayerTests-Logs-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true)
        }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs/OcPlayer", isDirectory: true)
    }()

    /// 当前正在写的**会话文件**（写满会续编成 `…-2.jsonl`，见 `continueInNewFile`）。
    private(set) var fileURL: URL
    private let directory: URL
    private let sessionFileBaseName: String
    private let maxFileBytes: Int
    private let maxRetainedFiles: Int
    private let maxTotalBytes: Int
    private let maxFileAge: TimeInterval
    private let maintenanceInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "dev.jumusu.DiagnosticsKit.file-sink")
    private let encoder: JSONEncoder
    private let sinkLogger: Logger
    private var handle: FileHandle?
    private var currentBytes = 0
    private var fileIndex = 1
    private var lastMaintenanceDate: Date?
    private let emitToOSLog: Bool

    /// 单条记录上限：一条超长记录（内核 dump、巨型错误串）不该顶掉整个文件。
    private static let maxRecordBytes = 64 * 1024

    init(directory: URL,
         maxFileBytes: Int,
         maxRetainedFiles: Int,
         maxTotalBytes: Int,
         maxFileAge: TimeInterval = 30 * 24 * 60 * 60,
         maintenanceInterval: TimeInterval = 24 * 60 * 60,
         now: @escaping @Sendable () -> Date = Date.init,
         emitToOSLog: Bool = true,
         sessionID: String = DiagnosticLogger.sessionID) {
        self.directory = directory
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxRetainedFiles = max(1, maxRetainedFiles)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxFileAge = maxFileAge.isFinite ? max(0, maxFileAge) : 0
        self.maintenanceInterval = maintenanceInterval.isFinite ? max(0, maintenanceInterval) : 0
        self.now = now
        // 会话文件：一次启动一个，名字里带时间戳与会话标识——排障时「给发生问题那次
        // 启动的那个文件」，不用跨会话猜哪几行是这次跑的。
        let stamp = TimestampFormatters.shared.fileStamp.string(from: now())
        self.sessionFileBaseName = "diagnostics-\(stamp)-\(sessionID)"
        self.fileURL = Self.sessionFileURL(
            directory: directory, base: sessionFileBaseName, index: 1)
        self.encoder = Self.makeEncoder()
        self.sinkLogger = Logger(subsystem: "dev.jumusu.OcPlayer", category: "DiagnosticsKit.FileSink")
        self.emitToOSLog = emitToOSLog
    }

    private static func sessionFileURL(directory: URL, base: String, index: Int) -> URL {
        let name = index <= 1 ? "\(base).jsonl" : "\(base)-\(index).jsonl"
        return directory.appendingPathComponent(name)
    }

    /// 目录里的全部诊断文件（含旧版 `diagnostics.jsonl*`，好让它们被同一套保留策略
    /// 自然淘汰），按修改时间从旧到新——写盘追加会让 mtime 单调前进。
    private func existingLogFiles() -> [(url: URL, size: Int, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return contents.compactMap { url -> (URL, Int, Date)? in
            let name = url.lastPathComponent
            let isLog = name == "diagnostics.jsonl"
                || name.hasPrefix("diagnostics-") && name.hasSuffix(".jsonl")
                || name.hasPrefix("diagnostics.jsonl.") && !name.hasSuffix(".lock")
            guard isLog else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            return (url, size, modified)
        }
        .sorted { $0.2 == $1.2 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.2 < $1.2 }
    }

    /// 时间戳格式：写盘带毫秒（秒级精度下同秒事件的先后无法判定），
    /// 解码同时接受带/不带小数秒——旧文件照读。
    private static func makeEncoder() -> JSONEncoder {        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TimestampFormatters.shared.millis.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = TimestampFormatters.shared.millis.date(from: text) { return date }
            if let date = TimestampFormatters.shared.seconds.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "无法解析诊断记录时间戳：\(text)"))
        }
        return decoder
    }

    func append(_ record: DiagnosticEntry) {
        queue.async { [self] in
            do {
                var data = try encoder.encode(record) + Data([0x0A])
                if data.count > Self.maxRecordBytes {
                    data = try truncatedEncoding(of: record, originalBytes: data.count)
                    guard !data.isEmpty else { return }
                }
                try write(data)
            } catch {
                report(error)
            }
        }
    }

    /// 超长记录的编码：**截断保留现场**（原先整条换成一条 warning，等于把内容丢了）。
    /// 先留消息头部 + 标注被截字节数；还超就把字段也丢（膨胀元凶常常是它）；
    /// 都放不下才放弃整条。
    private func truncatedEncoding(of record: DiagnosticEntry, originalBytes: Int) throws -> Data {
        let marker = "…[超长截断，原 \(originalBytes) 字节]"
        let head = String(record.message.prefix(1024)) + marker
        func encode(fields: [String: DiagnosticValue]) throws -> Data {
            let entry = DiagnosticEntry(
                timestamp: record.timestamp, level: record.level,
                subsystem: record.subsystem, category: record.category,
                message: head, fields: fields,
                suppressed: record.suppressed, session: record.session, sequence: record.sequence)
            return try encoder.encode(entry) + Data([0x0A])
        }
        let withFields = try encode(fields: record.fields)
        if withFields.count <= Self.maxRecordBytes { return withFields }
        let bare = try encode(fields: [:])
        return bare.count <= Self.maxRecordBytes ? bare : Data()
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

            let decoder = Self.makeDecoder()
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
        // summary() 由设置页在主线程调用，2MB 逐字节扫描别占主线程 CPU：
        // 扫描投到自己的串行队列上跑，调用方只阻塞等结果（等待不烧 CPU）。
        // 队列串行 → 扫描与写入天然互斥，读到的计数与文件一致。
        let box = SummaryBox()
        queue.async { box.fill(self.summaryOnQueue()) }
        return box.wait()
    }

    private func summaryOnQueue() -> DiagnosticSummary? {
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

    /// 单次结果信箱：fill 一次，wait 取走（`stored` 的外层 nil 只在未 fill 时出现）。
    private final class SummaryBox: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var stored: DiagnosticSummary??

        func fill(_ value: DiagnosticSummary?) {
            stored = .some(value)
            semaphore.signal()
        }

        func wait() -> DiagnosticSummary? {
            semaphore.wait()
            return stored ?? nil
        }
    }

    func flush() {
        queue.sync {
            do { try handle?.synchronize() }
            catch { report(error) }
        }
    }

    /// 有界等待版 flush：`timeout` 内没落完就返回 false。
    /// 进程终止路径用它——别为了最后几条日志把退出流程吊住。
    func flush(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            do { try handle?.synchronize() }
            catch { report(error) }
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func performMaintenance() {
        queue.sync {
            do { try enforceRetention(referenceDate: now(), force: true) }
            catch { report(error) }
        }
    }

    /// 导出=目录里所有保留文件按时间从旧到新拼接（含当前会话文件与旧版文件）。
    func exportData() throws -> Data {
        try queue.sync {
            try handle?.synchronize()
            var output = Data()
            for file in existingLogFiles() {
                output.append(try Data(contentsOf: file.url))
            }
            return output
        }
    }

    func clear() throws {
        try queue.sync {
            try handle?.close()
            handle = nil
            currentBytes = 0
            fileIndex = 1
            fileURL = Self.sessionFileURL(
                directory: directory, base: sessionFileBaseName, index: 1)
            for file in existingLogFiles() {
                try FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private func write(_ data: Data) throws {
        try ensureDirectory()
        try enforceRetention(referenceDate: now(), force: false)
        if handle == nil {
            currentBytes = fileSize(at: fileURL)
        }
        if currentBytes > 0, currentBytes + data.count > maxFileBytes {
            try continueInNewFile()
        }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: fileURL)
            // **O_APPEND**：同一份日志可能被多个进程共写（App 与测试宿主、双开实例）。
            // 默认的「seek 到末尾 + 各自记偏移」在跨进程下会交错写，把两条记录撕碎
            // ——2026-09-15 实测到 116 行残缺记录（记录被拦腰截断后互相插入）。
            // 追加模式下每次 write 由内核原子落位到真实末尾，单条记录不会再被撕开。
            if let descriptor = handle?.fileDescriptor {
                let flags = fcntl(descriptor, F_GETFL)
                if flags >= 0 {
                    _ = fcntl(descriptor, F_SETFL, flags | O_APPEND)
                }
            }
            currentBytes = fileSize(at: fileURL)
        }
        try handle?.write(contentsOf: data)
        currentBytes += data.count
    }

    /// 写满就**续编**（`…-2.jsonl`、`…-3.jsonl`）。旧实现是滚动归档 + 删最旧，
    /// 于是「触发上限的那一刻」会直接毁掉一段历史；现在内容整段留给保留策略，
    /// 由它按数量/总量从最旧淘汰。
    private func continueInNewFile() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        fileIndex += 1
        fileURL = Self.sessionFileURL(
            directory: directory, base: sessionFileBaseName, index: fileIndex)
        currentBytes = 0
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 当前（正在写的）文件判定。
    ///
    /// `contentsOfDirectory` 返回的 URL 会把 `/var` 解析成 `/private/var`，直接比 URL
    /// 会把当前文件也当成可淘汰候选——维护一跑就把正在写的现场删掉（实测踩到）。
    private func isCurrentFile(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL
            == fileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// 保留策略：最新 `maxRetainedFiles` 个文件、总量 ≤ `maxTotalBytes`、不超过 `maxFileAge`。
    /// **当前会话文件永不删**——删它等于把现场毁掉；宁可短时超限。
    private func enforceRetention(referenceDate: Date, force: Bool) throws {
        if !force, let lastMaintenanceDate,
           referenceDate.timeIntervalSince(lastMaintenanceDate) < maintenanceInterval {
            return
        }
        lastMaintenanceDate = referenceDate

        let cutoff = referenceDate.addingTimeInterval(-maxFileAge)
        for file in existingLogFiles() where !isCurrentFile(file.url) {
            let expired = maxFileAge == 0 || file.modified < cutoff
            if expired { try? FileManager.default.removeItem(at: file.url) }
        }

        var candidates = existingLogFiles().filter { !isCurrentFile($0.url) }
        var total = candidates.reduce(0) { $0 + $1.size } + fileSize(at: fileURL)
        // 当前文件占一个名额。
        let keepOthers = max(0, maxRetainedFiles - 1)
        while !candidates.isEmpty, candidates.count > keepOthers || total > maxTotalBytes {
            let victim = candidates.removeFirst()
            try? FileManager.default.removeItem(at: victim.url)
            total -= victim.size
        }
    }

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func report(_ error: Error) {
        guard emitToOSLog else { return }
        sinkLogger.error("JSONL sink failure: \(String(describing: error), privacy: .private)")
    }
}
