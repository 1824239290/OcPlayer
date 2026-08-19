import DiagnosticsKit
import Foundation

/// App 全局诊断日志入口。
///
/// 单一 `DiagnosticLogger`，所有模块共用同一个 JSONL 文件
/// （`~/Library/Logs/OcPlayer/diagnostics.jsonl`，2 MB 轮转保留 3 份），
/// 同时镜像到 OSLog（Console.app 按 subsystem `dev.jumusu.OcPlayer` 过滤）。
/// 敏感字段（token / Authorization 头 / 用户路径）由红actor 在写盘前统一脱敏。
enum AppDiagnostics {

    static let logger = DiagnosticLogger(subsystem: "dev.jumusu.OcPlayer", category: "App")

    static var fileURL: URL { logger.fileURL }

    static var recentRecords: [DiagnosticEntry] {
        (try? logger.readRecords(limit: 40)) ?? []
    }

    static func logInfo(_ message: String, fields: [String: DiagnosticValue] = [:]) {
        logger.info(message, fields: fields)
    }

    static func logWarning(_ message: String, fields: [String: DiagnosticValue] = [:]) {
        logger.warning(message, fields: fields)
    }

    static func logError(_ message: String, fields: [String: DiagnosticValue] = [:]) {
        logger.error(message, fields: fields)
    }

    static func flush() {
        logger.flush()
    }

    /// 每次启动留一条会话记录：版本 + 平台 + 构建，排查「哪个版本出的问题」。
    static func recordLaunch() {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        logInfo("应用启动", fields: [
            "platform": .string(platform),
            "version": .string(version),
            "build": .string(build),
        ])
    }
}
