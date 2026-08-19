import Foundation
import XCTest
@testable import JellyfinKit

final class ClientIdentityTests: XCTestCase {
    func testVersionUsesMarketingVersionAndBuildFromBundle() throws {
        let bundle = try makeBundle(shortVersion: "1.2.3", build: "45")

        XCTAssertEqual(ClientIdentity.version(in: bundle), "1.2.3 (45)")
        XCTAssertEqual(ClientIdentity.marketingVersion(in: bundle), "1.2.3")
    }

    func testVersionDoesNotRepeatIdenticalBuild() throws {
        let bundle = try makeBundle(shortVersion: "1.2.3", build: "1.2.3")

        XCTAssertEqual(ClientIdentity.version(in: bundle), "1.2.3")
    }

    func testVersionFallsBackToAvailableBundleValue() throws {
        let buildOnly = try makeBundle(shortVersion: nil, build: "99")
        let empty = try makeBundle(shortVersion: nil, build: nil)

        XCTAssertEqual(ClientIdentity.version(in: buildOnly), "99")
        XCTAssertEqual(ClientIdentity.version(in: empty), "development")
        XCTAssertEqual(ClientIdentity.marketingVersion(in: buildOnly), "99")
        XCTAssertEqual(ClientIdentity.marketingVersion(in: empty), "development")
    }

    private func makeBundle(shortVersion: String?, build: String?) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ClientIdentityTests-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        var info: [String: Any] = [
            "CFBundleIdentifier": "dev.jumusu.ClientIdentityTests.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL",
        ]
        info["CFBundleShortVersionString"] = shortVersion
        info["CFBundleVersion"] = build
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: directory.appending(path: "Info.plist"))
        return try XCTUnwrap(Bundle(url: directory))
    }
}
