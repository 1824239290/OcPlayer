import Foundation
import XCTest
@testable import OcPlayer

final class AppVersionTests: XCTestCase {

    func testSanitizeVersion() {
        XCTAssertEqual(AppVersion.sanitize("v1.0.0"), "1.0.0")
        XCTAssertEqual(AppVersion.sanitize("V2.3.4"), "2.3.4")
        XCTAssertEqual(AppVersion.sanitize("1.2.3"), "1.2.3")
        XCTAssertEqual(AppVersion.sanitize("v1.2.0-beta.1"), "1.2.0")
        XCTAssertEqual(AppVersion.sanitize("  v3.0.1  "), "3.0.1")
    }

    func testCompareVersions() {
        // Equal
        XCTAssertEqual(AppVersion.compare(current: "1.0.0", remote: "1.0.0"), .orderedSame)
        XCTAssertEqual(AppVersion.compare(current: "v1.0.0", remote: "1.0.0"), .orderedSame)
        XCTAssertEqual(AppVersion.compare(current: "1.0", remote: "1.0.0"), .orderedSame)

        // Remote newer
        XCTAssertEqual(AppVersion.compare(current: "1.0.0", remote: "1.0.1"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare(current: "1.0.0", remote: "1.1.0"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare(current: "1.0.0", remote: "2.0.0"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare(current: "1.9.9", remote: "1.10.0"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare(current: "v1.0.0", remote: "v1.0.1"), .orderedAscending)

        // Current newer
        XCTAssertEqual(AppVersion.compare(current: "1.0.1", remote: "1.0.0"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare(current: "2.0.0", remote: "1.9.9"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare(current: "1.10.0", remote: "1.9.9"), .orderedDescending)
    }

    func testIsNewer() {
        XCTAssertTrue(AppVersion.isNewer(remote: "1.0.1", than: "1.0.0"))
        XCTAssertTrue(AppVersion.isNewer(remote: "v1.1.0", than: "1.0.9"))
        XCTAssertFalse(AppVersion.isNewer(remote: "1.0.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer(remote: "0.9.9", than: "1.0.0"))
    }

    func testDecodeGitHubRelease() throws {
        let json = """
        {
            "tag_name": "v1.2.0",
            "name": "OcPlayer v1.2.0",
            "body": "### 新功能\\n- 支持关于页版本检查",
            "html_url": "https://github.com/1824239290/OcPlayer/releases/tag/v1.2.0",
            "published_at": "2026-08-25T10:00:00Z",
            "prerelease": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: json)

        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.name, "OcPlayer v1.2.0")
        XCTAssertEqual(release.body, "### 新功能\n- 支持关于页版本检查")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/1824239290/OcPlayer/releases/tag/v1.2.0")
        XCTAssertEqual(release.isPrerelease, false)
        XCTAssertNotNil(release.publishedAt)
    }
}
