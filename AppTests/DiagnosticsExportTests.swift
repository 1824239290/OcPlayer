import DiagnosticsKit
import XCTest
@testable import OcPlayer

/// 诊断包导出的内容形态：头部说明行 + JSONL 记录本体（单文件，双端同一实现）。
final class DiagnosticsExportTests: XCTestCase {

    func testExportTextHasHeaderAndParsableBody() throws {
        let text = try DiagnosticsExport.makeText()
        let parts = text.components(separatedBy: "\n\n")
        let header = try XCTUnwrap(parts.first)

        XCTAssertTrue(header.hasPrefix("# OcPlayer 诊断日志"), "首行是给用户看的标题")
        XCTAssertTrue(header.contains("版本: "))
        XCTAssertTrue(header.contains("平台: "))
        XCTAssertTrue(header.contains("详细日志: "))
        XCTAssertTrue(header.contains("脱敏"), "头部要写明哪些字段被替换过")

        // 记录本体是 JSONL。**不要求 100% 可解析**：2026-09-15 之前文件 sink 用
        // 「seek 到末尾 + 各自记偏移」，多进程共写（App 与测试宿主）会留下残缺行；
        // sink 已改 O_APPEND（旧残缺行仍在历史归档里），所以这里按「绝大多数」判定。
        // 逐行 XCTAssertNoThrow 会在失败时触发 XCTest 符号化卡死（CoreSymbolication），
        // 因此一次性统计再断言，避免每行都记一次 issue。
        let lines = parts.dropFirst().joined(separator: "\n\n")
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        let parsable = lines.count { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
        }
        XCTAssertGreaterThan(
            Double(parsable) / Double(lines.count), 0.95,
            "绝大多数行应是合法 JSONL（可解析 \(parsable)/\(lines.count)）")
    }

    /// 内核 trace 由内核直接写盘、不经 App 日志管线，导出前必须显式过脱敏。
    /// 直连 URL 的签名 query 是最现实的泄露面。
    func testExportRedactsKernelTraceQuery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secret = "supersecretvalue"
        let traceURL = directory.appendingPathComponent(KernelTraceSwitches.traceFileNames[0])
        let body = "[erika-http-trace] stage=head_request uri=https://cdn.example.com/movie.mkv?token=\(secret)\n"
        try body.write(to: traceURL, atomically: true, encoding: .utf8)

        let text = try DiagnosticsExport.makeText(directory: directory)
        XCTAssertTrue(text.contains("# 内核 trace："), "trace 段应被带上")
        XCTAssertFalse(text.contains(secret), "trace 里的 query 凭据必须被脱敏")
        XCTAssertTrue(text.contains("?<redacted>"), "URL query 应替换为占位符")
    }

    func testSuggestedFileNameIsTimestampedAndHasNoColon() {
        let name = DiagnosticsExport.suggestedFileName()
        XCTAssertTrue(name.hasPrefix("OcPlayer-诊断-"), name)
        XCTAssertFalse(name.contains(":"), "文件名不能带冒号（macOS 会把它们转换掉）")
        XCTAssertTrue(name.allSatisfy { $0.isNumber || $0 == "-" || "OcPlayer诊断".contains($0) }, name)
    }
}
