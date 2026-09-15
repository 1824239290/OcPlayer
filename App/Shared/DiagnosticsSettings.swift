import DiagnosticsKit
import Foundation

/// 诊断日志的 App 层设置：设置页开关 ↔ 日志管线的最低落盘级别。
///
/// - 关（默认）= `info`：状态迁移、失败与决策可见；守卫与中间态被过滤。
/// - 开 = `debug`：连链路细节一起落盘，排障用（即设置页「详细日志」）。
///
/// 级别是日志管线的进程级状态，改了立刻生效（不需要重启，也不需要重建引擎）；
/// 唯一要注意的是启动顺序——`OcPlayerApp.init` 里先 `apply()` 再写第一条日志。
enum DiagnosticsSettings {
    /// `defaults` 可注入：测试用隔离域，生产走 `.standard`。
    static func isVerboseLoggingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: SettingsKeys.diagnosticsVerbose)
    }

    /// 把当前开关应用到日志管线。启动时与开关变化时各调一次。
    ///
    /// 一并处理内核开关（`ERIKA_*` trace / 诊断）：它们由内核在**引擎创建时**读取，
    /// 所以改动在下一次播放（重建引擎）后生效——设置页文案按这个口径写。
    /// `logDirectory` 只给测试注入临时目录用（避免动到真实日志目录里的 trace 文件）。
    static func apply(in defaults: UserDefaults = .standard, logDirectory: URL? = nil) {
        let verbose = isVerboseLoggingEnabled(in: defaults)
        DiagnosticLogger.setMinimumLevel(verbose ? .debug : .info)
        let directory = logDirectory ?? AppDiagnostics.fileURL.deletingLastPathComponent()
        KernelTraceSwitches.apply(verbose: verbose, into: directory)
    }
}
