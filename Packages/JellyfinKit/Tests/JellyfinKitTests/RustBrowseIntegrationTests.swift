import CoreModel
import Foundation
import OcPlayerCore
import XCTest
@testable import JellyfinKit

#if os(macOS)
final class RustBrowseIntegrationTests: XCTestCase {
    func testNativeBrowsePreservesFiltersAuthPaginationAndDoesNotReplayFailures() async throws {
        guard let library = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"] else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH for native browsing integration tests")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", Bundle.module.url(forResource: "native_browse", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ServerProfile(id: "native", serverName: "native", baseURL: URL(string: "http://127.0.0.1:\(port)/base")!,
                                    userID: "native-user", userName: "native", serverVersion: "fixture", kind: .jellyfin)
        // The wrapped Swift implementation must never be invoked for migrated commands.
        let fallback = EmbyServer(profile: profile, session: EmbySession(
            baseURL: profile.baseURL, accessToken: "fixture", userID: profile.userID,
            profileID: profile.id, sessionConfiguration: .ephemeral))
        let native = try XCTUnwrap(RustCoreMediaServer(wrapping: fallback, libraryPath: library))
        if ProcessInfo.processInfo.environment["OCP_CORE_ENABLED"] == "1" {
            XCTAssertNotNil(RustCoreMediaServer(wrapping: fallback), "default Foundation sessions must activate Core without explicit library injection")
        }
        let page = try await native.itemsPage(parentID: "library", kinds: [.movie, .episode], recursive: false,
                                              startIndex: 50, limit: 25, sort: .init(field: .rating, ascending: false),
                                              watchState: .unwatched, searchTerm: "  native  ")
        XCTAssertEqual(page.startIndex, 50, "the server need not echo StartIndex")
        XCTAssertEqual(page.totalRecordCount, 80)
        XCTAssertEqual(page.items.first?.playState?.positionSeconds, 42)
        XCTAssertEqual(page.items.first?.runtimeSeconds, 100)
        let latest = try await native.latestItems(limit: 7)
        XCTAssertEqual(latest.first?.id, "native-item")
        do {
            _ = try await native.itemsPage(parentID: "failure", kinds: nil, recursive: true,
                                            startIndex: 0, limit: 25, sort: nil, watchState: nil, searchTerm: nil)
            XCTFail("a native error must propagate")
        } catch {
            XCTAssertTrue(error is RustCoreMediaServerError, "must not silently use the Swift network path")
        }
    }
}
#endif
