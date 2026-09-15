import Foundation
import XCTest
@testable import DiagnosticsKit

/// A controllable clock for deterministic throttle tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date { lock.withLock { currentDate } }

    func advance(by interval: TimeInterval) {
        lock.withLock { currentDate += interval }
    }
}

final class DiagnosticLoggerTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testWritesAndReadsBackRecords() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.info("hello", fields: ["count": 3])
        log.error("boom")
        log.flush()

        let records = try log.readRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].message, "hello")
        XCTAssertEqual(records[1].level, "info")
        XCTAssertEqual(records[1].fields["count"], .integer(3))
        XCTAssertEqual(records[0].message, "boom")
        XCTAssertEqual(records[0].diagnosticLevel, .error)
    }

    func testFieldRedactionReachesDisk() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.error("请求失败", fields: [
            "url": .string("https://admin:secret@host/Items/x?token=abc"),
            "token": .string("raw-token"),
        ])
        log.flush()

        let records = try log.readRecords()
        let fields = try XCTUnwrap(records.first?.fields)
        XCTAssertEqual(fields["token"], .string("<redacted>"))
        XCTAssertFalse(fields["url"]?.logDescription().contains("secret") == true)
    }

    func testThrottleSuppressesAndFlushSummarizes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, now: { clock.now() }, emitToOSLog: false
        )
        let throttle = DiagnosticThrottle(key: "hot", interval: 10)

        log.error("repeated", throttle: throttle)      // emitted
        log.error("repeated", throttle: throttle)      // suppressed
        log.error("repeated", throttle: throttle)      // suppressed
        clock.advance(by: 11)
        log.error("repeated", throttle: throttle)      // emitted, suppressed=2
        log.error("repeated", throttle: throttle)      // suppressed
        log.flush()                                     // summary: suppressed=1

        let records = try log.readRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertNil(records[2].suppressed)
        XCTAssertEqual(records[1].suppressed, 2)
        XCTAssertEqual(records[1].message, "repeated")
        XCTAssertEqual(records[0].suppressed, 1)
        XCTAssertTrue(records[0].message.contains("Suppressed repeated diagnostic events"))
    }

    func testSessionFileContinuesAndExportKeepsAllRecords() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 每条消息约 150 字节；把单文件上限压到 1500 强制续编多次，验证内容一段不丢。
        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1500, maxRetainedFiles: 10, emitToOSLog: false
        )
        for index in 0..<30 {
            log.info("message number \(index) padding padding padding")
        }
        log.flush()

        let exported = try log.exportData()
        XCTAssertEqual(exported.split(separator: 0x0A).count, 30)
        XCTAssertGreaterThan(
            log.fileURL.lastPathComponent.contains("-2") ? 2 : 1, 0,
            "写满应续编到 -2 文件")
    }

    func testMaintenanceRemovesExpiredFilesAndKeepsFreshFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024, maxRetainedFiles: 10,
            maxFileAge: 60, maintenanceInterval: 3600,
            now: { clock.now() }, emitToOSLog: false
        )
        // 上一轮会话留下的文件（同目录、不同会话名）。
        let stale = directory.appendingPathComponent("diagnostics-20200101-000000-deadbeef.jsonl")
        let fresh = directory.appendingPathComponent("diagnostics-20200101-000001-feedface.jsonl")
        try Data("stale\n".utf8).write(to: stale)
        try Data("fresh\n".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now().addingTimeInterval(-61)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now()], ofItemAtPath: fresh.path)

        log.performMaintenance()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// 超长记录**截断保留现场**（旧行为是整条换成一条 warning，等于把内容丢了）。
    func testOversizedEntryIsTruncatedNotReplaced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.error(String(repeating: "x", count: 200_000))
        log.flush()

        let record = try XCTUnwrap(try log.readRecords().first)
        XCTAssertTrue(record.message.hasPrefix("xxx"), "头部内容要留下")
        XCTAssertTrue(record.message.contains("超长截断"), "要标注被截断")
        XCTAssertEqual(record.diagnosticLevel, .error, "级别不变")
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? NSNumber)?.intValue)
        XCTAssertLessThan(size, 70_000, "单条不该撑爆文件")
    }

    /// 保留策略按数量淘汰最旧的会话文件，当前文件永不删。
    func testRetentionKeepsNewestFilesAndNeverDeletesCurrent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, maxRetainedFiles: 3, maxTotalBytes: 1024 * 1024,
            maxFileAge: 30 * 24 * 60 * 60, maintenanceInterval: 0,
            now: { clock.now() }, emitToOSLog: false, sessionID: "current1"
        )
        // 造 4 个更旧的会话文件（保留 3 个的名额里当前文件占一个 → 只该剩 2 个旧的）。
        for index in 0..<4 {
            let url = directory.appendingPathComponent("diagnostics-2020010\(index)-000000-old\(index).jsonl")
            try Data("old \(index)\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: clock.now().addingTimeInterval(TimeInterval(-100 + index))],
                ofItemAtPath: url.path)
        }
        log.info("current session record")
        log.flush()
        log.performMaintenance()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertTrue(names.contains(log.fileURL.lastPathComponent), "当前会话文件必须在")
        XCTAssertEqual(names.count, 3, "当前文件 + 最新 2 个旧的，共 3 个")
        XCTAssertFalse(names.contains { $0.contains("old0") }, "最旧的先被淘汰")
    }

    /// 会话文件名带时间戳与会话标识——排障时按名字就能认出「哪次启动」。
    func testSessionFileNameCarriesStampAndSession() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false, sessionID: "abc12345"
        )
        let name = log.fileURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("diagnostics-"), name)
        XCTAssertTrue(name.hasSuffix("-abc12345.jsonl"), name)
        XCTAssertNotNil(name.range(of: #"diagnostics-\d{8}-\d{6}-"#, options: .regularExpression), name)
    }

    func testClearRemovesEverything() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.warning("one")
        log.flush()
        XCTAssertEqual(try log.readRecords().count, 1)

        try log.clear()
        XCTAssertEqual(try log.readRecords().count, 0)
        XCTAssertTrue(try log.exportData().isEmpty)
        XCTAssertNil(log.summary())
    }

    func testSummaryReportsFileSizeAndCount() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.info("a")
        log.info("b")
        log.flush()

        let summary = try XCTUnwrap(log.summary())
        XCTAssertEqual(summary.recordCount, 2)
        XCTAssertGreaterThan(summary.fileSizeBytes, 0)
    }

    func testExportTextPrependsHeaderLines() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.info("hello")
        log.flush()

        let text = try log.exportText(headerLines: ["# 头部", "版本: 1.0"])
        XCTAssertTrue(text.hasPrefix("# 头部\n版本: 1.0\n\n"), "头部说明行原样在前，空行分隔")
        XCTAssertTrue(text.contains("\"message\":\"hello\""), "记录本体是 JSONL")
    }

    /// 回归（2026-09-15 实测到 116 行残缺记录）：同一份日志可能被多个进程共写
    /// （App 与测试宿主、双开实例）。旧实现「seek 到末尾 + 各自记偏移」，对方写入后
    /// 本 sink 的下一条会落在**旧偏移**上，把两条记录拦腰撕碎。
    /// sink 改 O_APPEND 后，每条记录都追加到真实末尾。
    func testAppendLandsAtRealEndWhenAnotherWriterIntervenes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.info("first")
        log.flush()

        // 另一个写入者，模拟另一个进程/实例往同一文件追加。
        let intruder = try FileHandle(forWritingTo: log.fileURL)
        try intruder.seekToEnd()
        try intruder.write(contentsOf: Data("INTRUDER\n".utf8))
        try intruder.close()

        log.info("third")
        log.flush()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3, "三条都要在，且不该互相覆盖")
        XCTAssertTrue(text.contains("INTRUDER"), "对方写入的内容不该被本 sink 覆盖")
        XCTAssertTrue(lines.last?.contains("\"third\"") == true, "新记录落在真实末尾")
        for line in lines where line != "INTRUDER" {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                            "记录本体不该被撕碎: \(line)")
        }
    }
}

private extension DiagnosticValue {
    func logDescription() -> String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .double(let value): return String(value)
        case .boolean(let value): return String(value)
        case .null: return "null"
        }
    }
}
