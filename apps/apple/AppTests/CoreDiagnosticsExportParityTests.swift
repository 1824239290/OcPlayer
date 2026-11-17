@testable import DiagnosticsKit
import Foundation
import OcPlayerCore
import XCTest
@testable import OcPlayer

final class CoreDiagnosticsExportParityTests: XCTestCase {
    private let headers = ["# OcPlayer 诊断日志", "版本: fixture", "脱敏: fixture"]
    private func fixture() throws -> (URL, URL, DiagnosticLogger) {
        if OcpCoreFeature.isEnabled { XCTAssertTrue(DiagnosticsExport.isCoreExportActive, "Core export must execute in enabled tests") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-parity-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs"), traces = root.appendingPathComponent("traces")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (logs, traces, DiagnosticLogger(subsystem: "test", category: "export", directory: logs,
            maxFileBytes: 1024 * 1024, maxRetainedFiles: 10, maxTotalBytes: 50 * 1024 * 1024, emitToOSLog: false))
    }
    private func write(_ data: Data, to directory: URL, name: String, time: TimeInterval = 100) throws {
        let path = directory.appendingPathComponent(name)
        try data.write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: path.path)
    }
    private func compare(_ logger: DiagnosticLogger, traces: URL, budget: Int?, tail: Int = 1024 * 1024) throws {
        let native = try DiagnosticsExport.nativeText(logger: logger, headerLines: headers, directory: traces, traceTailBytes: tail, bodyByteBudget: budget)
        let actual = try DiagnosticsExport.makeData(logger: logger, headerLines: headers, directory: traces, traceTailBytes: tail, bodyByteBudget: budget)
        XCTAssertEqual(actual, Data(native.utf8))
    }
    func testArchiveOrderingFiltersAndActualByteReclamation() throws {
        let (logs, traces, logger) = try fixture()
        try write(Data("a\n".utf8), to: logs, name: "diagnostics-a.jsonl", time: 1)
        try write(Data("b\n".utf8), to: logs, name: "diagnostics-b.jsonl", time: 1)
        try write(Data("xxxxxxxx\nnew\n".utf8), to: logs, name: "diagnostics.jsonl", time: 2)
        try write(Data("hidden\n".utf8), to: logs, name: "diagnostics.jsonl.1.lock", time: 3)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("diagnostics-c.jsonl"), withDestinationURL: logs.appendingPathComponent("diagnostics-a.jsonl"))
        for budget: Int? in [nil, 0, -1, 8, 100] { try compare(logger, traces: traces, budget: budget) }
    }
    func testUtf8RepairAcrossFilesAndIncompleteTraceTail() throws {
        let (logs, traces, logger) = try fixture()
        try write(Data([0xE4, 0xB8]), to: logs, name: "diagnostics-a.jsonl", time: 1)
        try write(Data([0xAD, 0xFF, 0xE2, 0x82]), to: logs, name: "diagnostics.jsonl", time: 2)
        try write(Data([0xFF, 0xE4, 0xB8, 0xAD, 0xE2, 0x82]), to: traces, name: KernelTraceSwitches.traceFileNames[0])
        try write(Data((0..<70_000).map { UInt8($0 % 256) }), to: logs, name: "diagnostics-b.jsonl", time: 3)
        for budget: Int? in [nil, 100, 1] { for tail in [0, 2, 100] { try compare(logger, traces: traces, budget: budget, tail: tail) } }
    }
    func testNativeSanitizerDifferentialCorpusAndOrderedTraces() throws {
        let (_, traces, logger) = try fixture()
        let corpus = [
            "file:///Users/\(NSUserName())/private /home/\(NSUserName())/private /Users/server/Items",
            "/private/var/mobile/Containers/Data/App /var/mobile/Containers/Data/App",
            "https://user:pass@host/a?token=hidden). https://host/a#fragment; HTTP://host/path",
            "https://host?x=1 https://u:p@host?x=1 https://host/a?x=1#part",
            "Bearer abc Basic QWxhZGRpbjpvcGVu= token=hidden password='secret value'",
            "\"refresh_token\": \"hidden\"; 'api-key'=hidden Cookie: hidden; X-Emby-Token=hidden",
            "ſecret=hidden paſſword=hidden İTOKEN=hidden Kookie=hidden",
            "eyJabcdefghijklmnop.a.b EYJabcdefghijklmnop.a.b",
            "plain subtitle stream /Users/server/Items 空白 中文\n"
        ].joined(separator: "\n")
        for name in KernelTraceSwitches.traceFileNames { try write(Data(corpus.utf8), to: traces, name: name) }
        try compare(logger, traces: traces, budget: nil)
        try compare(logger, traces: traces, budget: 0, tail: 120)
    }
    func testNoNewlineTraceKeepsSuffixAndLogReclaimsBudget() throws {
        let (logs, traces, logger) = try fixture()
        try write(Data("old\n".utf8), to: logs, name: "diagnostics-a.jsonl", time: 1)
        try write(Data("xxxxxxxxxxxxxxxx".utf8), to: logs, name: "diagnostics.jsonl", time: 2)
        try write(Data("abcdefghijklmnopqrstuvwxyz".utf8), to: traces, name: KernelTraceSwitches.traceFileNames[0])
        try compare(logger, traces: traces, budget: 8, tail: 5)
        try compare(logger, traces: traces, budget: -1, tail: -1)
    }
    func testQueuedRecordsAreFlushedBeforeCoreExportAndTemporaryFileIsRemoved() throws {
        let (_, traces, logger) = try fixture()
        logger.info("queued event", fields: ["event": "fixture"])
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("ocplayer-diagnostic-export-") })
        let data = try DiagnosticsExport.makeData(logger: logger, headerLines: headers, directory: traces, traceTailBytes: 100, bodyByteBudget: nil)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("queued event"))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("ocplayer-diagnostic-export-") })
        XCTAssertEqual(before, after)
    }
}
