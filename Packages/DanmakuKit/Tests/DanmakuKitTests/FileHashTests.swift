import CryptoKit
import XCTest
@testable import DanmakuKit

final class FileHashTests: XCTestCase {

    /// 已知内容的前 16 MiB MD5 向量：空文件 → d41d8cd98f00b204e9800998ecf8427e。
    func testEmptyFileMD5() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-hash-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let hash = try FileHash.head16MiBMD5(at: url)
        XCTAssertEqual(hash, "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// "abc" → 900150983cd24fb0d6963f7d28e17f72。
    func testSmallFileMD5() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-hash-abc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let hash = try FileHash.head16MiBMD5(at: url)
        XCTAssertEqual(hash, "900150983cd24fb0d6963f7d28e17f72")
    }

    /// 超过 16 MiB 的文件只取前 16 MiB：与单独算前 16 MiB 一致。
    func testOnlyHead16MiBForLargeFile() throws {
        let big = Data((0..<(17 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-hash-big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try big.write(to: url)

        let hash = try FileHash.head16MiBMD5(at: url)
        let head = big.prefix(16 * 1024 * 1024)
        // 用 CryptoKit 直接算前 16 MiB 对照。
        var ref = Insecure.MD5()
        ref.update(data: head)
        let expected = ref.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
    }

    func testUnreadableFile() {
        let url = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertThrowsError(try FileHash.head16MiBMD5(at: url)) { error in
            XCTAssertEqual(error as? FileHash.FileHashError, .unreadable)
        }
    }

    func testReadFailureErrorIsDistinct() {
        // The enum keeps an I/O read failure distinct from an unreadable path;
        // callers must not treat a partial digest as valid.
        XCTAssertNotEqual(FileHash.FileHashError.readFailed, .unreadable)
    }

    func testLocalHashHonorsTaskCancellation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocp-hash-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        let task = Task.detached { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileHash.head16MiBMD5(at: url)
        }

        do {
            _ = try await task.value
            XCTFail("cancelled local hashing should throw")
        } catch is CancellationError {
            // expected
        }
    }

    func testRemoteRangeHashIncludesHeaders() async throws {
        let url = URL(string: "https://media.example/video.mkv")!
        let session = TestSupport.mockedSession()
        try await TestSupport.withMock({ request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-16777215")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "secret")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-2/3"]
            )!
            return (response, Data("abc".utf8))
        }) {
            let hash = try await FileHash.head16MiBMD5(
                from: url,
                headers: ["Authorization": "secret"],
                expectedFileSize: 3,
                session: session
            )
            XCTAssertEqual(hash, "900150983cd24fb0d6963f7d28e17f72")
        }
    }

    func testRemoteSourceThatIgnoresRangeIsRejected() async throws {
        let url = URL(string: "https://media.example/video.mkv")!
        let session = TestSupport.mockedSession()
        try await TestSupport.withMock({ request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("abc".utf8))
        }) {
            do {
                _ = try await FileHash.head16MiBMD5(
                    from: url,
                    expectedFileSize: Int64(FileHash.headByteCount + 1),
                    session: session
                )
                XCTFail("should reject a full-file response")
            } catch FileHash.FileHashError.rangeUnsupported {
                // expected
            }
        }
    }
}
