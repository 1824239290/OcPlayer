import Foundation
import XCTest
@testable import DiagnosticsKit

final class ManagedDirectoryPrunerTests: XCTestCase {
    func testPruneRemovesOldestFilesUntilCountAndBytesFit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldest = try makeFile("old.png", bytes: 40, age: 30, in: directory)
        let middle = try makeFile("middle.png", bytes: 50, age: 20, in: directory)
        let newest = try makeFile("new.png", bytes: 60, age: 10, in: directory)

        let result = ManagedDirectoryPruner.prune(
            directory: directory,
            allowedExtensions: ["png"],
            maxFileCount: 2,
            maxTotalBytes: 100
        )

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(result.removedBytes, 90)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    func testPruneLeavesUnlistedExtensionsAndChildSymlinksAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = try makeFile("notes.txt", bytes: 20, age: 20, in: directory)
        let target = try makeFile("target.dat", bytes: 20, age: 10, in: directory)
        let link = directory.appending(path: "linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = ManagedDirectoryPruner.prune(
            directory: directory,
            allowedExtensions: ["png"],
            maxFileCount: 0,
            maxTotalBytes: 0
        )

        XCTAssertEqual(result.removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testPruneRejectsSymbolicLinkRootWithoutTouchingTarget() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let image = try makeFile("keep.png", bytes: 20, age: 10, in: target)
        let link = parent.appending(path: "linked-root", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = ManagedDirectoryPruner.prune(
            directory: link,
            allowedExtensions: ["png"],
            maxFileCount: 0,
            maxTotalBytes: 0
        )

        XCTAssertTrue(result.skippedUnsafeRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testPruneTreatsMissingDirectoryAsNoWork() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "ManagedDirectoryPrunerTests-missing-\(UUID().uuidString)")

        XCTAssertEqual(
            ManagedDirectoryPruner.prune(
                directory: missing,
                allowedExtensions: ["png"],
                maxFileCount: 0,
                maxTotalBytes: 0
            ),
            .init()
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ManagedDirectoryPrunerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFile(_ name: String, bytes: Int, age: TimeInterval, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try Data(repeating: 0x78, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }
}
