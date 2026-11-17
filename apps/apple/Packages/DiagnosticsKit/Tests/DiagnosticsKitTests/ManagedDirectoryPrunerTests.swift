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

    // MARK: - 前缀白名单（弹幕目录的真实形态）

    /// 回归：目录里混着「可重下缓存」与「永久数据」时，**永久数据必须活下来**。
    ///
    /// 淘汰按 mtime 最旧优先，而永久文件写得最少、mtime 最旧 —— 这正是弹幕目录的
    /// 形态：5 个 json 里只有 `comments-*.json` 是缓存，其余 4 个是永久的。
    /// 原实现只排除了 `mapping.json`，另外三个（片头提示 / 别名 / AniSkip MAL ID）
    /// 一直在被优先删除。白名单把这件事从"记得补名单"变成"默认安全"。
    func testPrefixAllowlistProtectsUnknownFilesEvenWhenOldest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 全部造得比缓存老：若是"最旧优先 + 只排除已知永久"，它们会被先删。
        let hints = try makeFile("intro-hints.json", bytes: 10, age: 300, in: directory)
        let aliases = try makeFile("title-aliases.json", bytes: 10, age: 200, in: directory)
        let aniskip = try makeFile("aniskip-ids.json", bytes: 10, age: 150, in: directory)
        let mapping = try makeFile("mapping.json", bytes: 10, age: 100, in: directory)
        // 将来新增的、连 preservedFileNames 都不知道的永久文件。
        let future = try makeFile("future-store.json", bytes: 10, age: 120, in: directory)
        // 真正的缓存，两条。
        let cacheOld = try makeFile("comments-101.json", bytes: 10, age: 50, in: directory)
        let cacheNew = try makeFile("comments-202.json", bytes: 10, age: 1, in: directory)

        let result = ManagedDirectoryPruner.prune(
            directory: directory,
            allowedExtensions: ["json"],
            maxFileCount: 1,
            maxTotalBytes: 1024,
            prunableFileNamePrefixes: ["comments-"]
        )

        // 只允许删 comments-*，且只删到剩 1 个。
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheOld.path), "最旧的缓存应被删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheNew.path), "留下的应是较新的缓存")

        for url in [hints, aliases, aniskip, mapping, future] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) 是永久数据，不该参与淘汰")
        }
    }

    /// 不传白名单 = 保持旧行为（目录里都是可重下缓存时用）。
    func testWithoutAllowlistAllCandidatesParticipate() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = try makeFile("comments-1.json", bytes: 10, age: 20, in: directory)
        let other = try makeFile("mapping.json", bytes: 10, age: 30, in: directory)

        let result = ManagedDirectoryPruner.prune(
            directory: directory,
            allowedExtensions: ["json"],
            maxFileCount: 0,
            maxTotalBytes: 0
        )

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    /// 空数组视同"未传"，避免调用方传 `[]` 时静默变成"什么都不删"。
    func testEmptyAllowlistBehavesLikeNil() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("comments-1.json", bytes: 10, age: 20, in: directory)

        let result = ManagedDirectoryPruner.prune(
            directory: directory,
            allowedExtensions: ["json"],
            maxFileCount: 0,
            maxTotalBytes: 0,
            prunableFileNamePrefixes: []
        )

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 白名单与前缀匹配都不区分大小写（与既有的扩展名 / 保留名单口径一致）。
    func testAllowlistMatchIsCaseInsensitive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("Comments-1.JSON", bytes: 10, age: 20, in: directory)

        let result = ManagedDirectoryPruner.prune(
            directory: directory,
            allowedExtensions: ["json"],
            maxFileCount: 0,
            maxTotalBytes: 0,
            prunableFileNamePrefixes: ["COMMENTS-"]
        )

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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
