import DiagnosticsKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 诊断包导出：头部（版本 / 平台 / 级别 / 脱敏说明）+ 全部日志记录，产出**单个 .txt**。
///
/// 单文件而非 zip：iOS 起不了 `ditto`，双端行为一致；GitHub issue 也能直接附件。
/// 记录本体是 JSONL（每行一条），头部是给人看的说明，工具解析照样从第一行 `{` 开始。
enum DiagnosticsExport {

    /// 日志正文进导出包的上限。
    ///
    /// 保留上限是 50 MB（`DiagnosticBackend.maxTotalBytes`），而导出会把内容同时
    /// 持有三份（`Data` + 解码后的 `String` + 拼接结果）——实测 48.4 MB 日志对应
    /// **112 MiB 峰值 RSS**（2.44×）。iOS 上是现实的 jetsam 风险（本 App 真实峰值
    /// RSS 到过 435 MB），而「导出诊断包附到 issue」这条工作流又必须可用。
    ///
    /// 8 MiB 按每条 ~1 KB ≈ **8000 条**，远超任何一个 issue 需要贴的量；实测把尖峰
    /// 压到 **32 MiB**。排障看的本来就是"崩前那一段"，所以只保留**最新**的记录。
    static let bodyByteBudget = 8 * 1024 * 1024

    static func makeText(
        directory: URL = AppDiagnostics.fileURL.deletingLastPathComponent(),
        traceTailBytes: Int = DiagnosticsExport.traceTailBytes,
        bodyByteBudget: Int? = DiagnosticsExport.bodyByteBudget
    ) throws -> String {
        // 正文有界：只留最新的那一段（`nil` 时行为退回「导出全部」，供测试/排障用）。
        var text = try AppDiagnostics.logger.exportText(
            headerLines: headerLines(bodyByteBudget: bodyByteBudget),
            bodyByteBudget: bodyByteBudget)
        // 详细档的内核 trace（HTTP 逐请求 / demux 读失败）是独立文件，附在后面：
        // 「一个文件说明一切」比让用户分别找两个 jsonl 靠谱。
        // trace 由内核**直接写盘**、不经 App 日志管线，所以这里显式过一遍脱敏：
        // 逐请求记录里带完整 URI，用户直连的带签名 query 的 URL 会原样落进去。
        for name in KernelTraceSwitches.traceFileNames {
            let url = directory.appendingPathComponent(name)
            guard let trace = readTraceTail(at: url, maxBytes: traceTailBytes),
                  !trace.text.isEmpty else { continue }
            text += "\n\n# 内核 trace：\(name)"
                + (trace.truncated ? "（只保留尾部 \(traceTailBytes / 1024 / 1024) MiB，已截断）" : "")
                + "\n" + DiagnosticSanitizer.redact(trace.text)
        }
        return text
    }

    /// 单个内核 trace 进导出包的上限。
    ///
    /// trace 是内核按需写盘的连续流，**没有大小上限也没有轮转**（`KernelTraceSwitches`
    /// 只在启动/关档时删文件）；播放 trace 实测约 120 KB/s，1 小时就是 ~430MB。
    /// 旧实现 `String(contentsOf:)` 整份读入再跑 6 遍正则脱敏，iOS 上是现实的
    /// OOM/被系统杀掉风险，而且长会话之后「导出诊断包附到 issue」这条工作流直接
    /// 不可用。这里只取尾部——排障看的本来就是"崩前那一段"。
    static let traceTailBytes = 4 * 1024 * 1024

    /// 读文件尾部至多 `traceTailBytes`，并按行对齐（丢掉可能被切一半的首行）。
    /// 返回 `truncated` 供头部标注，取不到时返回 nil（与原来的 `try?` 同语义）。
    static func readTraceTail(
        at url: URL,
        maxBytes: Int = DiagnosticsExport.traceTailBytes
    ) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // `seekToEnd()` 只借用它拿文件长度，**偏移会停在 EOF**——不显式回绕的话
        // 下面整份读取会读出空字符串。
        guard let size = try? handle.seekToEnd() else { return nil }
        let limit = UInt64(Swift.max(0, maxBytes))
        if size <= limit {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let data = try? handle.readToEnd() else { return nil }
            return (String(decoding: data, as: UTF8.self), false)
        }
        guard (try? handle.seek(toOffset: size - limit)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // 起点落在行中间是常态：丢掉第一段残行，保证导出段从完整行开始。
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return (text, true)
    }

    /// 文件名（不含扩展名）：`OcPlayer-诊断-<yyyyMMdd-HHmm>`，扩展名由 fileExporter 补。
    static func suggestedFileName(now: Date = Date()) -> String {
        "OcPlayer-诊断-" + formatter.string(from: now)
    }

    private static func headerLines(bodyByteBudget: Int?) -> [String] {
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
        var note = "说明: 凭据 / 用户路径 / URL query 已在写盘前脱敏为 <redacted> 等占位；"
            + "内核 trace 段同样已过脱敏。"
            + "以下每行是一条 JSONL 记录，按时间升序（归档在前、当前文件在后）。"
        if let bodyByteBudget {
            note += "日志正文只保留最新的一段（上限 "
                + ByteCountFormatter.string(
                    fromByteCount: Int64(bodyByteBudget), countStyle: .file) + "，已截断）。"
        }
        lines.append(note)
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
///
/// ## 为什么持 `Data` 而不是 `String`
///
/// 导出内容是几 MB 文本，`String → Data` 的那次编码（`Data(text.utf8)`）是一次
/// **整份拷贝**。改前它在 `fileWrapper` 里做 —— 而 `fileWrapper` 由 SwiftUI 在
/// **主线程**调用，等于导出瞬间多一次主线程大块分配。改成在 `makeText` 的
/// `Task.detached` 里就转好、文档直接持 `Data`，主线程只剩一次 `FileWrapper` 包装。
struct DiagnosticExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
