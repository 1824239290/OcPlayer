import CoreModel
import Foundation
import OcPlayerCore
import XCTest
@testable import JellyfinKit

@MainActor
final class MediaNullableHTTPTests: XCTestCase {
    private func paired(_ name: String, kind: ServerKind,
                        _ operation: (any MediaServer, any MediaServer) async throws -> Void) async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", try XCTUnwrap(Bundle.module.url(forResource: "media_nullable_server", withExtension: "py", subdirectory: "Fixtures")).path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/case/\(name)"))
        let suiteName = "nullable-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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
    func testMissingNullAndEmptyListContainersAcrossBothServers() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["containers_missing", "containers_null", "containers_empty"] {
                try await paired(name, kind: kind) { native, core in
                    for server in [native, core] {
                        let views = try await server.userViews(), latest = try await server.latestItems(limit: 24)
                        let resume = try await server.resumeItems(), next = try await server.nextUp()
                        let page = try await server.itemsPage(parentID: nil, kinds: nil, recursive: false,
                            startIndex: 0, limit: 24, sort: nil, watchState: nil, searchTerm: nil)
                        let played = try await server.playedItemsPage(startIndex: 0, limit: 24)
                        let seasons = try await server.seasons(seriesID: "series")
                        let episodes = try await server.episodes(seriesID: "series", seasonID: nil)
                        let similar = try await server.similar(itemID: "item", limit: 12)
                        let segments = try await server.mediaSegments(itemID: "item"), chapters = try await server.chapters(itemID: "item")
                        XCTAssertTrue(views.isEmpty); XCTAssertTrue(latest.isEmpty); XCTAssertTrue(resume.isEmpty); XCTAssertTrue(next.isEmpty)
                        XCTAssertTrue(page.items.isEmpty); XCTAssertTrue(played.items.isEmpty); XCTAssertTrue(seasons.isEmpty)
                        XCTAssertTrue(episodes.isEmpty); XCTAssertTrue(similar.isEmpty); XCTAssertTrue(segments.isEmpty); XCTAssertTrue(chapters.isEmpty)
                    }
                }
            }
        }
    }
    func testFullAndNullableItemsRetainNativeMappingAcrossBothServers() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["full_movie", "full_episode", "full_season", "missing_identity", "null_name", "null_kind", "partial_people", "null_streams"] {
                try await paired(name, kind: kind) { native, core in
                    let expected = try await native.item("item"), actual = try await core.item("item")
                    XCTAssertEqual(try self.encoded(actual), try self.encoded(expected), "\(kind)/\(name)")
                    let expectedSimilar = try await native.similar(itemID: "item", limit: 12)
                    let actualSimilar = try await core.similar(itemID: "item", limit: 12)
                    XCTAssertEqual(try self.encoded(actualSimilar), try self.encoded(expectedSimilar), "similar \(kind)/\(name)")
                }
            }
        }
    }
    func testNullablePlaybackSourcesAndStreamsPreserveSessionContext() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["null_streams", "no_streams", "empty_streams", "null_sources", "missing_sources"] {
                try await paired(name, kind: kind) { native, core in
                    let expected = try await native.playbackInfo(itemID: "item"), actual = try await core.playbackInfo(itemID: "item")
                    XCTAssertEqual(actual.playSessionID, expected.playSessionID)
                    XCTAssertEqual(actual.mediaSources.map(\.id), expected.mediaSources.map(\.id))
                    XCTAssertEqual(actual.mediaSources.first?.size, expected.mediaSources.first?.size)
                    XCTAssertEqual(actual.mediaSources.first?.runTimeSeconds, expected.mediaSources.first?.runTimeSeconds)
                    XCTAssertEqual(actual.mediaSources.first?.videoRangeType, expected.mediaSources.first?.videoRangeType)
                }
            }
        }
    }
    func testLibraryFilteringCaseAndMissingIdentityMatchNative() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["full_movie", "library_missing_identity"] {
                try await paired(name, kind: kind) { native, core in
                    let expected = try await native.userViews(), actual = try await core.userViews()
                    XCTAssertEqual(actual.map(\.name), expected.map(\.name)); XCTAssertEqual(actual.map(\.collectionType), expected.map(\.collectionType))
                    XCTAssertEqual(actual.count, 2)
                    if name == "library_missing_identity" {
                        XCTAssertNotNil(UUID(uuidString: actual[0].id)); XCTAssertNotNil(UUID(uuidString: expected[0].id))
                    } else { XCTAssertEqual(actual.map(\.id), expected.map(\.id)) }
                }
            }
        }
    }
    func testWrongNonNullTypesFailInsteadOfBecomingEmptyLists() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["wrong_list", "wrong_chapters", "wrong_genres", "wrong_people", "wrong_images", "wrong_ticks", "wrong_sources", "wrong_streams"] {
                try await paired(name, kind: kind) { native, core in
                    for server in [native, core] {
                        do {
                            if name == "wrong_chapters" { _ = try await server.chapters(itemID: "item") }
                            else if name == "wrong_list" { _ = try await server.similar(itemID: "item", limit: 12) }
                            else if name == "wrong_sources" || name == "wrong_streams" { _ = try await server.playbackInfo(itemID: "item") }
                            else { _ = try await server.item("item") }
                            XCTFail("Unexpected success: \(kind)/\(name)")
                        } catch { XCTAssertFalse(error is CancellationError) }
                    }
                }
            }
        }
    }
    func testNullableRawMediaContainersAndMalformedArraysMatchNative() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            for name in ["containers_missing", "containers_null", "containers_empty", "null_sources", "missing_sources", "null_streams", "no_streams", "empty_streams"] {
                try await paired(name, kind: kind) { native, core in
                    let expectedSubtitles = try await native.externalSubtitles(itemID: "item")
                    let actualSubtitles = try await core.externalSubtitles(itemID: "item")
                    XCTAssertEqual(actualSubtitles, expectedSubtitles)
                    let expected = try await native.mediaFileInfo(itemID: "item"), actual = try await core.mediaFileInfo(itemID: "item")
                    XCTAssertEqual(try self.encoded(actual), try self.encoded(expected), "file info \(kind)/\(name)")
                }
            }
            for name in ["wrong_list", "wrong_sources", "wrong_streams"] {
                try await paired(name, kind: kind) { native, core in
                    for server in [native, core] {
                        for operation in 0...1 {
                            do {
                                if operation == 0 { _ = try await server.externalSubtitles(itemID: "item") }
                                else { _ = try await server.mediaFileInfo(itemID: "item") }
                                XCTFail("Unexpected raw-media success: \(kind)/\(name)")
                            } catch { XCTAssertFalse(error is CancellationError) }
                        }
                        if name == "wrong_list" && kind == .jellyfin {
                            do { _ = try await server.mediaSegments(itemID: "item"); XCTFail("Unexpected segments success") }
                            catch { XCTAssertFalse(error is CancellationError) }
                        }
                    }
                }
            }
        }
    }
    func testEmbyChapterMarkersAndFallbackRetainNativeSegments() async throws {
        for name in ["emby_markers", "emby_marker_fallback", "emby_marker_unknown"] {
            try await paired(name, kind: .emby) { native, core in
                let expected = try await native.mediaSegments(itemID: "item"), actual = try await core.mediaSegments(itemID: "item")
                XCTAssertEqual(actual, expected)
                if name != "emby_marker_unknown" {
                    XCTAssertEqual(actual.count, 2); XCTAssertEqual(actual.first?.startSeconds, 10)
                    XCTAssertEqual(actual.first?.endSeconds, 20); XCTAssertEqual(actual.last?.startSeconds, 7000)
                    XCTAssertEqual(actual.last?.endSeconds, 7200.25)
                } else { XCTAssertTrue(actual.isEmpty) }
            }
        }
    }
    func testPreparationWithNullStreamsRetainsNegotiatedSourceAndSession() async throws {
        for kind in [ServerKind.jellyfin, .emby] {
            try await paired("null_streams", kind: kind) { _, core in
                var result: PreparedPlayback?
                let outcome = try await PlaybackPreparationWorkflow.prepare(item: .init(id: "item", name: "片名", kind: .movie),
                    resumeSeconds: 80.5, server: core, home: { ([], []) }, onResolved: { _ in },
                    onFallback: { _, message in XCTFail("Unexpected fallback: \(message)") }, onReady: { result = $0 })
                if case .presented = outcome {} else { XCTFail("Not presented: \(outcome)") }
                XCTAssertEqual(result?.context.mediaSourceID, "source"); XCTAssertEqual(result?.context.playSessionID, "session")
                XCTAssertEqual(result?.context.mediaSourceSize, .max); XCTAssertEqual(result?.context.durationSeconds, 7200.25)
                XCTAssertEqual(result?.resumeSeconds, 80.5)
            }
        }
    }
}
