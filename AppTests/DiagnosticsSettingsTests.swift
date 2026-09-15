import DiagnosticsKit
import XCTest
@testable import OcPlayer

/// 设置页「详细日志」开关 ↔ 日志管线最低落盘级别的接线。
final class DiagnosticsSettingsTests: XCTestCase {

    func testVerboseToggleDrivesMinimumLevel() {
        let defaults = TestSupport.isolatedDefaults("DiagnosticsSettingsTests.verbose")
        defer { DiagnosticLogger.setMinimumLevel(.info) }

        // 键不存在（全新安装 / 从未拨过）= 关 = info 档。
        defaults.removeObject(forKey: SettingsKeys.diagnosticsVerbose)
        DiagnosticsSettings.apply(in: defaults)
        XCTAssertFalse(DiagnosticsSettings.isVerboseLoggingEnabled(in: defaults))
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .info)

        defaults.set(true, forKey: SettingsKeys.diagnosticsVerbose)
        DiagnosticsSettings.apply(in: defaults)
        XCTAssertTrue(DiagnosticsSettings.isVerboseLoggingEnabled(in: defaults))
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .debug)

        defaults.set(false, forKey: SettingsKeys.diagnosticsVerbose)
        DiagnosticsSettings.apply(in: defaults)
        XCTAssertEqual(DiagnosticLogger.minimumLevel, .info)
    }
}
