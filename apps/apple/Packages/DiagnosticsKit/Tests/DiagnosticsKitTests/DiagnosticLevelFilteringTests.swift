import Foundation
import XCTest
@testable import DiagnosticsKit

/// 最低落盘级别的过滤语义：默认 info、开关切 debug、过滤发生在求值与节流之前。
final class DiagnosticLevelFilteringTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsKitLevelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    override func tearDown() {
        // 进程级阈值是全局状态：每个用例跑完都还原成产品默认值，避免串味。
        DiagnosticLogger.setMinimumLevel(.info)
        super.tearDown()
    }

    func testLevelOrderingMatchesSeverity() {
        XCTAssertLessThan(DiagnosticLevel.debug, DiagnosticLevel.info)
        XCTAssertLessThan(DiagnosticLevel.info, DiagnosticLevel.notice)
        XCTAssertLessThan(DiagnosticLevel.notice, DiagnosticLevel.warning)
        XCTAssertLessThan(DiagnosticLevel.warning, DiagnosticLevel.error)
        XCTAssertLessThan(DiagnosticLevel.error, DiagnosticLevel.critical)
        XCTAssertEqual(DiagnosticLevel.allCases.sorted(), DiagnosticLevel.allCases)
    }

    func testDefaultProcessLevelIsInfo() {
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .info)
    }

    func testDebugIsFilteredAtDefaultLevelAndMessageIsNotEvaluated() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        var evaluated = false
        func expensiveMessage() -> String {
            evaluated = true
            return "expensive"
        }
        log.debug("\(expensiveMessage())")
        log.info("kept")
        log.flush()

        XCTAssertFalse(evaluated, "被级别过滤的日志不该求值消息（含字符串插值）")
        let records = try log.readRecords()
        XCTAssertEqual(records.map(\.message), ["kept"])
    }

    func testSwitchingToDebugLetsDebugRecordsThrough() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        DiagnosticLogger.setMinimumLevel(.debug)
        log.debug("详细档可见")
        log.flush()

        let records = try log.readRecords()
        XCTAssertEqual(records.map(\.message), ["详细档可见"])
        XCTAssertEqual(records.first?.level, "debug")
    }

    func testInstanceOverrideWinsOverProcessLevel() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        DiagnosticLogger.setMinimumLevel(.error)
        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false, minimumLevel: .debug
        )
        XCTAssertTrue(log.isEnabled(.debug))
        log.debug("隔离实例不受进程阈值影响")
        log.flush()

        let records = try log.readRecords()
        XCTAssertEqual(records.map(\.message), ["隔离实例不受进程阈值影响"])
    }

    /// 过滤发生在节流判定之前：被压掉的记录不该改动节流计数。
    func testFilteredEntriesDoNotTouchThrottleState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        let throttle = DiagnosticThrottle(key: "hot", interval: 10)

        DiagnosticLogger.setMinimumLevel(.warning)
        log.info("被过滤", throttle: throttle)   // 不落盘，也不该记进节流状态
        log.info("被过滤", throttle: throttle)
        DiagnosticLogger.setMinimumLevel(.info)
        log.info("恢复可见", throttle: throttle)  // 应是该 key 的第一次发射
        log.flush()

        let records = try log.readRecords()
        XCTAssertEqual(records.map(\.message), ["恢复可见"])
        XCTAssertNil(records.first?.suppressed, "过滤期不该给节流计数充值")
    }

    /// 会话标记与序号：跨模块对齐同一次运行、并保证列表身份唯一。
    func testRecordsCarrySessionAndMonotonicSequence() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.info("一")
        log.info("二")
        log.info("三")
        log.flush()

        let records = try log.readRecords().reversed()   // 文件顺序
        XCTAssertFalse(DiagnosticLogger.sessionID.isEmpty)
        XCTAssertEqual(Set(records.compactMap(\.session)), [DiagnosticLogger.sessionID])
        let sequences = records.compactMap(\.sequence)
        XCTAssertEqual(sequences.count, 3, "每条都该有序号")
        XCTAssertEqual(sequences, sequences.sorted(), "序号单调递增")
        XCTAssertEqual(Set(records.map(\.id)).count, 3, "id 互不相同")
    }

    /// 毫秒精度：同秒内的事件先后要能排出来（旧格式的秒级精度做不到）。
    func testTimestampsCarryMillisecondsAndOldRecordsStillDecode() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticLogger(
            subsystem: "test", category: "cat", directory: directory,
            maxFileBytes: 1024 * 1024, emitToOSLog: false
        )
        log.info("a")
        log.flush()

        let raw = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("."), "时间戳该带小数秒：\(raw.prefix(160))")

        // 旧格式（秒级、无 session/sequence）仍要能读回来——历史文件不能变成乱码。
        let legacy = """
        {"category":"cat","fields":{},"level":"info","message":"旧记录",\
        "subsystem":"test","timestamp":"2026-09-14T13:56:30Z"}
        """
        try (legacy + "\n").write(to: log.fileURL, atomically: false, encoding: .utf8)
        let records = try log.readRecords()
        XCTAssertEqual(records.first?.message, "旧记录")
        XCTAssertNil(records.first?.session, "旧记录没有会话字段")
        XCTAssertNil(records.first?.sequence, "旧记录没有序号")
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-14T13:56:30Z"))
        XCTAssertEqual(records.first?.timestamp ?? .distantPast, expected)
    }
}
