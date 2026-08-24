import DiagnosticsKit
import Foundation

/// 播放链路日志入口（内核适配器 + App 播放层共用）。
///
/// 基于 `DiagnosticsKit`：JSONL 落盘（`~/Library/Logs/OcPlayer/diagnostics.jsonl`，
/// 2 MB 轮转保留 3 份）+ OSLog 镜像。所有播放相关模块（PlaybackKit / 各内核适配器 /
/// App 层）都往同一个文件追加，时间线上无缝；token / Authorization 头等敏感字段
/// 由 DiagnosticsKit 统一脱敏，不进任何 sink。
public enum PlaybackLog {
    private static let logger = DiagnosticLogger(subsystem: "dev.jumusu.OcPlayer", category: "Playback")

    public static var fileURL: URL { logger.fileURL }

    /// 等所有排队的 JSONL 写盘完成（App 退出前调用，别让最后几条丢）。
    public static func flush() {
        logger.flush()
    }

    /// 追加一条 debug 级链路日志。
    public static func append(_ message: String) {
        logger.debug(message)
    }

    /// 追加一条 error 级日志（渲染线程 / 内核错误事件这类真正要捞出来的）。
    public static func error(_ message: String,
                             fields: [String: DiagnosticValue] = [:],
                             throttle: DiagnosticThrottle? = nil) {
        logger.error(message, fields: fields, throttle: throttle)
    }
}
