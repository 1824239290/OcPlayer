import DiagnosticsKit
import XCTest
@testable import OcPlayer

/// 设置页「详细日志」开关 ↔ 日志管线最低落盘级别的接线。
final class DiagnosticsSettingsTests: XCTestCase {

    func testVerboseToggleDrivesMinimumLevel() {
        let defaults = TestSupport.isolatedDefaults("DiagnosticsSettingsTests.verbose")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            DiagnosticLogger.setMinimumLevel(.info)
            try? FileManager.default.removeItem(at: directory)
        }

        // 键不存在（全新安装 / 从未拨过）= 关 = info 档。
        defaults.removeObject(forKey: SettingsKeys.diagnosticsVerbose)
        DiagnosticsSettings.apply(in: defaults, logDirectory: directory)
        XCTAssertFalse(DiagnosticsSettings.isVerboseLoggingEnabled(in: defaults))
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .info)

        defaults.set(true, forKey: SettingsKeys.diagnosticsVerbose)
        DiagnosticsSettings.apply(in: defaults, logDirectory: directory)
        XCTAssertTrue(DiagnosticsSettings.isVerboseLoggingEnabled(in: defaults))
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .debug)

        defaults.set(false, forKey: SettingsKeys.diagnosticsVerbose)
        DiagnosticsSettings.apply(in: defaults, logDirectory: directory)
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .info)
    }
}
