import Foundation
import XCTest
@testable import DiagnosticsKit

final class DiagnosticExportDirectoryTests: XCTestCase {
    private func fixture() throws -> (URL, DiagnosticLogger) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diag-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, DiagnosticLogger(subsystem: "test", category: "export", directory: directory, maxFileBytes: 1024 * 1024, emitToOSLog: false))
    }
    func testQueuedRecordsAreSynchronizedBeforeDirectoryOperation() throws {
        let (directory, logger) = try fixture()
        logger.info("queued record")
        let text = try logger.withSynchronizedExportDirectory { actual in
            XCTAssertEqual(actual, directory)
            return String(decoding: try Data(contentsOf: logger.fileURL), as: UTF8.self)
        }
        XCTAssertTrue(text.contains("queued record"))
    }
    func testThrowingDirectoryOperationReleasesTheQueueForLaterExports() throws {
        enum Failure: Error { case expected }
        let (_, logger) = try fixture()
        XCTAssertThrowsError(try logger.withSynchronizedExportDirectory { _ in throw Failure.expected })
        logger.info("after failed export")
        XCTAssertTrue(String(decoding: try logger.exportData(), as: UTF8.self).contains("after failed export"))
    }
}
