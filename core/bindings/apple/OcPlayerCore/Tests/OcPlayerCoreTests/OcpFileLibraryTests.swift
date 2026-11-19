import Foundation
import XCTest
@testable import OcPlayerCore

final class OcpFileLibraryTests: XCTestCase {
    func testCapabilityAndDirectoryLeaseWorkWithoutMigrationFlag() async throws {
        let core = try OcpCoreClient(libraryPath: OcpTestLibrary.path())
        let library = OcpFileLibrary(client: core)
        let capabilities = try await library.capabilities()
        XCTAssertEqual(capabilities.sourceKinds, ["localFolder", "webdav"])
        XCTAssertEqual(capabilities.libraryTypes, [.movies, .tvshows])
        XCTAssertFalse(capabilities.aggregation)
        XCTAssertTrue(capabilities.tmdbScraping)
        XCTAssertEqual(capabilities.schemaVersion, 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await library.open(directory: directory.appendingPathComponent("catalog"))
        let access = try await library.prepareAccess(root: directory)
        XCTAssertFalse(access.accessId.isEmpty)
        let sources = try await library.sources()
        XCTAssertTrue(sources.isEmpty)
    }

    func testInventedValidationCannotCreateLibrary() async throws {
        let core = try OcpCoreClient(libraryPath: OcpTestLibrary.path())
        let library = OcpFileLibrary(client: core)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await library.open(directory: directory.appendingPathComponent("catalog"))
        let access = try await library.prepareAccess(root: directory)
        do {
            _ = try await library.create(.init(draftId: "draft", verificationId: "invented", credentialRevision: "r", apiBase: "https://api.themoviedb.org/3", accessId: access.accessId, sourceName: "Files", rootPath: directory.path, name: "Movies", type: .movies))
            XCTFail("Unverified draft created a library")
        } catch { XCTAssertTrue(error.localizedDescription.contains("TMDB")) }
        let sources = try await library.sources()
        XCTAssertTrue(sources.isEmpty)
    }

    func testTypedAssetSizeAndSourceIdentityRetainWireValues() throws {
        let json = Data("{\"sourceId\":\"source\",\"assetId\":\"asset\",\"relativePath\":\"雪.mkv\",\"size\":9007199254740993,\"available\":true}".utf8)
        let asset = try JSONDecoder().decode(OcpFileLibrary.Asset.self, from: json)
        XCTAssertEqual(asset.size, 9007199254740993)
        XCTAssertEqual(asset.id, "source:asset")
        let query = OcpFileLibrary.Query(sourceId: "current", type: .tvshows, parentId: "season", startIndex: 9007199254740993)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
        XCTAssertEqual(object["sourceId"] as? String, "current")
        XCTAssertEqual(object["type"] as? String, "tvshows")
        XCTAssertEqual((object["startIndex"] as? NSNumber)?.int64Value, 9007199254740993)
    }
}
