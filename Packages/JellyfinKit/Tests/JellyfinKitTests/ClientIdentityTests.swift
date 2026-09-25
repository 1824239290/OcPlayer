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

    func testMediaBrowserAuthorizationHeaderIncludesStableIdentity() {
        let withToken = ClientIdentity.mediaBrowserAuthorizationHeader(token: "tok-abc")
        XCTAssertTrue(withToken.hasPrefix("MediaBrowser "))
        XCTAssertTrue(withToken.contains("Client=\"OcPlayer\""))
        XCTAssertTrue(withToken.contains("Device=\"\(ClientIdentity.deviceName)\""))
        XCTAssertTrue(withToken.contains("DeviceId=\"\(ClientIdentity.deviceID)\""))
        XCTAssertTrue(withToken.contains("Version=\"\(ClientIdentity.version)\""))
        XCTAssertTrue(withToken.contains(#"Token="tok-abc""#))

        let withoutToken = ClientIdentity.mediaBrowserAuthorizationHeader(token: nil)
        XCTAssertFalse(withoutToken.contains("Token="))
        XCTAssertTrue(withoutToken.contains("DeviceId=\"\(ClientIdentity.deviceID)\""))

        let emptyToken = ClientIdentity.mediaBrowserAuthorizationHeader(token: "")
        XCTAssertFalse(emptyToken.contains("Token="))
    }

    func testCustomUserAgentStripsControlCharacters() async throws {
        // 头值里带控制字符时 `URLRequest.setValue` 会把**整条头**静默丢掉：
        // 用户以为白名单 UA 生效了，实际发出去的是系统默认 UA，且不报错。
        // 粘贴 UA 常带尾随换行，所以是剔除而不是整值作废（作废会静默退回默认）。
        await TestSupport.withCustomUserAgent("SenPlayer/2.1\r\nX-Injected: 1") {
            XCTAssertEqual(ClientIdentity.customUserAgent, "SenPlayer/2.1X-Injected: 1")
        }
        await TestSupport.withCustomUserAgent("  SenPlayer/2.1\n") {
            XCTAssertEqual(ClientIdentity.customUserAgent, "SenPlayer/2.1")
        }
    }

    func testCustomUserAgentIsNilWhenBlank() async throws {
        await TestSupport.withCustomUserAgent("   \n\t ") {
            XCTAssertNil(ClientIdentity.customUserAgent, "空白值等于没设置，走系统默认")
        }
        await TestSupport.withCustomUserAgent(nil) {
            XCTAssertNil(ClientIdentity.customUserAgent)
        }
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
