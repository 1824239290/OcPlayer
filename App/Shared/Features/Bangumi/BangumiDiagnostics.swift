import BangumiKit
import Foundation

/// Bangumi 联动的 App 层诊断入口（转发到 BangumiKit 的网络日志）。
enum BangumiDiagnostics {
    static func log(_ message: String) {
        BangumiNetworkLog.logger.debug("\(message)")
    }
}
