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
}
