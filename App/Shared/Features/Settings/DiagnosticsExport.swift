import DiagnosticsKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 诊断包导出：头部（版本 / 平台 / 级别 / 脱敏说明）+ 全部日志记录，产出**单个 .txt**。
///
/// 单文件而非 zip：iOS 起不了 `ditto`，双端行为一致；GitHub issue 也能直接附件。
/// 记录本体是 JSONL（每行一条），头部是给人看的说明，工具解析照样从第一行 `{` 开始。
enum DiagnosticsExport {

    static func makeText() throws -> String {
        try AppDiagnostics.logger.exportText(headerLines: headerLines())
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        formatter.string(from: now)
    }

    private static func headerLines() -> [String] {
        var lines = ["# OcPlayer 诊断日志"]
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        lines.append("版本: \(version) (\(build))")
        if let commit = AppVersion.gitCommit {
            lines.append("提交: \(commit)")
        }
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        lines.append("平台: \(platform) \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("详细日志: \(DiagnosticsSettings.isVerboseLoggingEnabled() ? "开（debug 档）" : "关（info 档）")")
        lines.append("时间: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("说明: 凭据 / 用户路径 / URL query 已在写盘前脱敏为 <redacted> 等占位；"
            + "以下每行是一条 JSONL 记录，按时间升序（归档在前、当前文件在后）。")
        return lines
    }

    /// 固定格式串必须配固定 locale（与设置页时间列同一坑）。
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}

/// `.fileExporter` 用的纯文本文档：macOS 存到用户选的位置，iOS 进分享/存储流程。
struct DiagnosticExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
