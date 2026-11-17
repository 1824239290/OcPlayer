import Foundation
import XCTest
@testable import OcPlayerCore

final class OcpDiagnosticExportTests: XCTestCase {
    private func exporter() throws -> OcpDiagnosticExport {
        let path = try OcpTestLibrary.path()
        return try XCTUnwrap(OcpDiagnosticExport(libraryPath: path))
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocp-diag-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testFileReportAndNullableUnlimitedBudget() throws {
        let core = try exporter(), root = try fixture(), logs = root.appendingPathComponent("logs")
        try Data("记录\n".utf8).write(to: logs.appendingPathComponent("diagnostics.jsonl"))
        let output = root.appendingPathComponent("export.txt")
        let report = try core.export(logDirectory: logs, to: output, headerLines: ["# 诊断"], bodyByteBudget: nil, traces: [], username: "fixture")
        let data = try Data(contentsOf: output)
        XCTAssertEqual(data, Data("# 诊断\n\n记录\n".utf8)); XCTAssertEqual(report.bytes, UInt64(data.count))
        XCTAssertEqual(report.path, output.path); XCTAssertTrue(report.traces.isEmpty)
    }
    func testNegativeBudgetAndTraceSuffixRedaction() throws {
        let core = try exporter(), root = try fixture(), logs = root.appendingPathComponent("logs")
        let trace = root.appendingPathComponent("trace")
        try Data("old\npassword=private".utf8).write(to: trace)
        let output = root.appendingPathComponent("export.txt")
        let report = try core.export(logDirectory: logs, to: output, headerLines: [], bodyByteBudget: -1,
            traces: [.init(url: trace, name: "trace", maxBytes: 16)], username: "fixture")
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        XCTAssertTrue(text.contains("password=<redacted>")); XCTAssertFalse(text.contains("private"))
        XCTAssertEqual(report.traces.count, 1); XCTAssertTrue(report.traces[0].truncated)
    }
    func testExistingOutputAndNonFileURLsAreRejected() throws {
        let core = try exporter(), root = try fixture(), logs = root.appendingPathComponent("logs"), output = root.appendingPathComponent("export.txt")
        try Data("original".utf8).write(to: output)
        XCTAssertThrowsError(try core.export(logDirectory: logs, to: output, headerLines: [], bodyByteBudget: 8, traces: [], username: "fixture"))
        XCTAssertEqual(try Data(contentsOf: output), Data("original".utf8))
        XCTAssertThrowsError(try core.export(logDirectory: URL(string: "https://example.test")!, to: output, headerLines: [], bodyByteBudget: 8, traces: [], username: "fixture"))
    }
    func testBudgetKeepsCompleteNewestLines() throws {
        let core = try exporter(), root = try fixture(), logs = root.appendingPathComponent("logs")
        try Data("old\nnew\n".utf8).write(to: logs.appendingPathComponent("diagnostics.jsonl"))
        let output = root.appendingPathComponent("export.txt")
        _ = try core.export(logDirectory: logs, to: output, headerLines: [], bodyByteBudget: 5, traces: [], username: "fixture")
        XCTAssertEqual(try Data(contentsOf: output), Data("\n\nnew\n".utf8))
    }
}
