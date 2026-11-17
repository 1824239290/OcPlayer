import CoreModel
import Foundation
import OcPlayerCore
import XCTest
@testable import JellyfinKit

@MainActor
final class MediaProjectionHTTPTests: XCTestCase {
    private func paired(_ name: String, kind: ServerKind,
                        _ operation: (any MediaServer, any MediaServer) async throws -> Void) async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", try XCTUnwrap(Bundle.module.url(forResource: "media_projection_server", withExtension: "py", subdirectory: "Fixtures")).path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/case/\(name)"))
        let suiteName = "projection-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
        let profile = ServerProfile(id: UUID().uuidString, serverName: "fixture", baseURL: base,
            userID: "user", kind: kind, serverID: "fixture")
        store.activate(profile, token: "fixture-token")
        let native: any MediaServer
        if kind == .jellyfin { native = try XCTUnwrap(JellyfinServer.resume(profile: profile, from: store)) }
        else { native = try XCTUnwrap(EmbyServer.resume(profile: profile, from: store)) }
        if OcpCoreFeature.isEnabled {
            let core = try XCTUnwrap(RustCoreMediaServer(wrapping: native,
                libraryPath: ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"]))
            try await operation(native, core)
        } else { try await operation(native, native) }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func testExplicitSelectedSubtitleSourceNeverFallsBack() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            try await paired("full", kind: kind) { native, core in
                for source in ["stream", "play", "other", "missing", ""] {
                    let expected = try await native.externalSubtitles(itemID: "item", mediaSourceID: source)
                    let actual = try await core.externalSubtitles(itemID: "item", mediaSourceID: source)
                    XCTAssertEqual(actual, expected, "\(kind)/\(source)")
                    if source == "missing" || source.isEmpty { XCTAssertTrue(actual.isEmpty) }
                }
            }
        }
    }
    func testPreferredSourceOrdersDirectPlayBeforeDirectStreamAndFirstFallback() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["full", "stream_only", "none_playable", "empty"] {
                try await paired(name, kind: kind) { native, core in
                    let expected = try await native.externalSubtitles(itemID: "item"), actual = try await core.externalSubtitles(itemID: "item")
                    XCTAssertEqual(actual, expected, "\(kind)/\(name)")
                    let expectedInfo = try await native.mediaFileInfo(itemID: "item"), actualInfo = try await core.mediaFileInfo(itemID: "item")
                    XCTAssertEqual(try self.encoded(actualInfo), try self.encoded(expectedInfo), "\(kind)/\(name)")
                }
            }
        }
    }
    func testCompleteMediaFileInfoRetainsAllTracksAndExactInt64Size() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            try await paired("full", kind: kind) { native, core in
                let expectedOptional = try await native.mediaFileInfo(itemID: "item"), expected = try XCTUnwrap(expectedOptional)
                let actualOptional = try await core.mediaFileInfo(itemID: "item"), actual = try XCTUnwrap(actualOptional)
                XCTAssertEqual(try self.encoded(actual), try self.encoded(expected))
                XCTAssertEqual(actual.sizeBytes, .max); XCTAssertEqual(actual.durationSeconds, 7200.25)
                XCTAssertEqual(actual.fileName, "剧名 第1集.mkv"); XCTAssertEqual(actual.sourceCount, 3)
                XCTAssertEqual(actual.video?.videoRangeType, "DOVIWithHDR10"); XCTAssertEqual(actual.audioTracks.count, 2)
                if actual.audioTracks.count > 1 { XCTAssertNil(actual.audioTracks[1].title) }
                if !actual.subtitleTracks.isEmpty { XCTAssertNil(actual.subtitleTracks[0].title) }
                let subtitles = try await core.externalSubtitles(itemID: "item")
                XCTAssertEqual(subtitles.map(\.title), ["简中外挂", "英语外挂", "旧字幕"])
                XCTAssertEqual(subtitles.map(\.fileExtension), ["ass", "vtt", "ssa"])
                XCTAssertTrue(subtitles.allSatisfy { $0.remotePath.contains("/item/play/Subtitles/") })
            }
        }
    }
    func testFrameRateUsesNativeValidRangeAndRealRateFallback() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["fps_zero", "fps_high", "fps_negative", "fps_invalid", "fps_missing", "fps_round"] {
                try await paired(name, kind: kind) { native, core in
                    let expected = try await native.mediaFileInfo(itemID: "item"), actual = try await core.mediaFileInfo(itemID: "item")
                    XCTAssertEqual(try self.encoded(actual), try self.encoded(expected), "\(kind)/\(name)")
                }
            }
        }
    }
    func testMissingSourceIDsAndNullMetadataPreserveNativeDefaults() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["missing_ids", "null_fields", "path_root", "path_trailing", "path_empty", "path_windows"] {
                try await paired(name, kind: kind) { native, core in
                    let expected = try await native.externalSubtitles(itemID: "item"), actual = try await core.externalSubtitles(itemID: "item")
                    XCTAssertEqual(actual, expected)
                    let expectedInfo = try await native.mediaFileInfo(itemID: "item"), actualInfo = try await core.mediaFileInfo(itemID: "item")
                    XCTAssertEqual(try self.encoded(actualInfo), try self.encoded(expectedInfo))
                    let missing = try await core.externalSubtitles(itemID: "item", mediaSourceID: "missing")
                    XCTAssertTrue(missing.isEmpty)
                }
            }
        }
    }
    func testMalformedNonNullSourceAndTrackScalarsFailAcrossBothServers() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["wrong_size", "wrong_ticks", "wrong_supports", "wrong_width", "wrong_rate", "wrong_sample", "wrong_flag"] {
                try await paired(name, kind: kind) { native, core in
                    for server in [native, core] {
                        do { _ = try await server.mediaFileInfo(itemID: "item"); XCTFail("Unexpected file-info success: \(kind)/\(name)") }
                        catch { XCTAssertFalse(error is CancellationError) }
                    }
                }
            }
        }
    }
    func testUnknownStreamAndRangeValuesRetainFlavorSpecificNativeBehavior() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["unknown_stream", "lower_stream", "unknown_range", "fps_overflow", "fps_small"] {
                try await paired(name, kind: kind) { native, core in
                    for server in [native, core] {
                        if kind == .jellyfin {
                            do { _ = try await server.mediaFileInfo(itemID: "item"); XCTFail("Unexpected Jellyfin enum success") }
                            catch { XCTAssertFalse(error is CancellationError) }
                        }
                    }
                    if kind == .emby {
                        let expected = try await native.mediaFileInfo(itemID: "item"), actual = try await core.mediaFileInfo(itemID: "item")
                        XCTAssertEqual(try self.encoded(actual), try self.encoded(expected))
                        let expectedSubtitles = try await native.externalSubtitles(itemID: "item"), actualSubtitles = try await core.externalSubtitles(itemID: "item")
                        XCTAssertEqual(actualSubtitles, expectedSubtitles)
                    }
                }
            }
        }
    }
    func testMetadataRequestsDoNotFilterSelectedSourceOrCreatePlaybackSession() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            try await paired("full", kind: kind) { native, core in
                _ = try await native.externalSubtitles(itemID: "item", mediaSourceID: "play")
                _ = try await core.externalSubtitles(itemID: "item", mediaSourceID: "play")
                _ = try await core.mediaFileInfo(itemID: "item")
                var components = try XCTUnwrap(URLComponents(url: native.profile.baseURL, resolvingAgainstBaseURL: false))
                components.path = "/stats"
                let (data, _) = try await URLSession.shared.data(from: try XCTUnwrap(components.url))
                let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                XCTAssertFalse(rows.contains { $0["method"] as? String == "POST" })
                let requests = rows.filter { ($0["path"] as? String)?.hasSuffix("/Items") == true }
                XCTAssertEqual(requests.count, 3)
                for row in requests {
                    let query = try XCTUnwrap(row["query"] as? [String: [String]])
                    XCTAssertEqual(query["ids"], ["item"]); XCTAssertEqual(query["fields"], ["MediaSources"])
                    XCTAssertEqual(query["userId"], ["user"]); XCTAssertNil(query["mediaSourceId"])
                }
            }
        }
    }

}
