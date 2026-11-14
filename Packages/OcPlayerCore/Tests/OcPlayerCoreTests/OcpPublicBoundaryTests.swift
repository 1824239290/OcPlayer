import Foundation
import Darwin
import XCTest
@testable import OcPlayerCore

final class OcpPublicBoundaryTests: XCTestCase {
    private func client() throws -> OcpCoreClient { try OcpCoreClient(libraryPath: OcpTestLibrary.path()) }

    func testAsyncKeepsIntegralDecimalTokensAndNestedStringsIntact() async throws {
        let core = try client()
        let json = #" {"exportedAt":"2026-11-14T00:00:00Z","appVersion":"fixture","tmdb":{"language":"zh-CN","preferText":true,"replaceImages":false,"showPlaceholders":true,"cacheDays":9007199254740993},"preferences":{},"deviceName":"}\\\""} "#
        struct Projection: Decodable { let backupJSON: String }
        let sync = try core.call("settings.backup.snapshot", argumentsJSON: json)
        let async = try await core.callAsync("settings.backup.snapshot", argumentsJSON: json)
        XCTAssertTrue(sync.ok, sync.message)
        XCTAssertTrue(async.ok, async.message)
        let first = try sync.decodeData(Projection.self)
        let second = try async.decodeData(Projection.self)
        XCTAssertEqual(first.backupJSON, second.backupJSON)
        XCTAssertTrue(second.backupJSON.contains("9007199254740993"))
        for id in ["reused", "quote\"slash\\中文"] {
            let idJSON = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
            for _ in 0..<2 {
                let response = try await core.callAsync("ping", argumentsJSON: "{\"requestId\":\(idJSON)}")
                XCTAssertTrue(response.ok, response.message)
            }
        }
    }

    func testAsyncDeliversOriginalDecimalAndEscapedBytesToNativeABI() async throws {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_ECHO_LIBRARY_PATH"] else {
            throw XCTSkip("ABI echo fixture supplied by the completion audit gate")
        }
        let core = try OcpCoreClient(libraryPath: path)
        struct Echo: Decodable { let integer: Int64; let text: String }
        let json = #"{"integer":9007199254740993.0,"text":"braces } { quote \" 中文","unknown":[1e3,null,true]}"#
        let response = try await core.callAsync("echo", argumentsJSON: json)
        let value = try response.decodeData(Echo.self)
        XCTAssertEqual(value.integer, 9007199254740993)
        XCTAssertEqual(value.text, "braces } { quote \" 中文")
    }

    func testRejectedNativeLibrariesReleaseTheirLoadedImages() throws {
        guard let prefix = ProcessInfo.processInfo.environment["OCP_CORE_ECHO_LIBRARY_PATH"] else {
            throw XCTSkip("ABI rejection fixtures supplied by the completion audit gate")
        }
        for path in [prefix + ".missing.dylib", prefix + ".version.dylib"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "fixture must exist")
            XCTAssertThrowsError(try OcpCoreClient(libraryPath: path))
            let image = dlopen(path, RTLD_NOW | RTLD_NOLOAD)
            if let image { dlclose(image) }
            XCTAssertNil(image, "rejected library must not keep a dlopen reference")
        }
    }

    func testAsyncControlCommandsDoNotCreateTheirOwnReservations() async throws {
        let core = try client()
        let prepared = try await core.callAsync("request.prepare", argumentsJSON: #"{"requestId":"control"}"#)
        XCTAssertTrue(prepared.ok, prepared.message)
        let cancelled = try await core.callAsync("request.cancel", argumentsJSON: #"{"requestId":"control"}"#)
        XCTAssertTrue(cancelled.ok, cancelled.message)
        XCTAssertEqual(try core.call("ping", argumentsJSON: #"{"requestId":"control"}"#).code, 1003)
        let reused = try await core.callAsync("ping", argumentsJSON: #"{"requestId":"control"}"#)
        XCTAssertTrue(reused.ok, reused.message)
    }

    func testInvalidControlMetadataAndCStringsCannotDispatch() async throws {
        let core = try client()
        for json in ["[]", "null", #"{"requestId":null}"#, #"{"requestId":7}"#, #"{"requestId":""}"#, #"{"requestId":"a\u0000b"}"#] {
            do { _ = try await core.callAsync("ping", argumentsJSON: json); XCTFail("accepted \(json)") }
            catch { }
        }
        XCTAssertThrowsError(try core.call("playback.stop\0ping"))
        XCTAssertThrowsError(try core.call("ping", argumentsJSON: "{}\0[]"))
        XCTAssertThrowsError(try core.snapshot(kind: "core\0playback"))
        XCTAssertTrue(try core.call("ping").ok)
    }

    func testEventAndSnapshotTypedDecodingOwnExactWireBytes() throws {
        let core = try client()
        struct Surface: Decodable { let nativeHandle: UInt64 }
        struct Snapshot: Decodable { let abiVersion: UInt32; let surfaceAttached: Bool }
        while try core.pollEvent() != nil { }
        core.attachSurface(nativeHandle: UInt64.max, width: 10, height: 10, scale: 1, kind: 1)
        let event = try XCTUnwrap(core.pollEvent())
        XCTAssertEqual(try event.decodeData(Surface.self).nativeHandle, UInt64.max)
        let snapshot = try core.snapshot(as: Snapshot.self)
        XCTAssertTrue(snapshot.surfaceAttached)
        XCTAssertEqual(snapshot.abiVersion, 1)
    }
}
