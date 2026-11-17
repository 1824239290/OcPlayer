import BangumiKit
import DiagnosticsKit
import Foundation

/// Bangumi 联动的 App 层诊断入口（转发到 BangumiKit 的网络日志）。
///
/// 默认 info：自动标看过的决策与跳过原因要在默认档可见（排障要看「为什么没标」）；
/// 真实失败（加载/同步/标记失败）传 `level: .warning`。
enum BangumiDiagnostics {
    static func log(_ message: @autoclosure () -> String, level: DiagnosticLevel = .info) {
        BangumiNetworkLog.logger.log(level: level, message())
    }
}
