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

    func testRotationAndExportKeepAllRecords() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 每条消息约 150 字节；把单文件上限压到 1500 强制触发多次轮转，
        // 同时 retainedArchives 给足，验证 export 能找回全部记录。
        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1500, retainedArchives: 10, emitToOSLog: false
        )
        for index in 0..<30 {
            log.info("message number \(index) padding padding padding")
        }
        log.flush()

        let exported = try log.exportData()
        XCTAssertEqual(exported.split(separator: 0x0A).count, 30)
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
