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

    /// **头的字段顺序与格式是契约，必须精确钉住。**
    ///
    /// 审查实测：把 `composeAuthorizationHeader` 的字段顺序调换后，所有用例**全绿** ——
    /// 因为缓存版与现拼版同源，对拍抓不到顺序变化；而既有那条
    /// `testMediaBrowserAuthorizationHeaderIncludesStableIdentity` 只用 `contains`。
    ///
    /// 顺序为什么是契约：`RemoteImage` 的凭证指纹是**整条头的 SHA256**，
    /// 顺序一变指纹就变 → 全部图片缓存键失效 → 表现为「升级后所有图重新下载」。
    func testAuthorizationHeaderFieldOrderIsPinned() {
        ClientIdentity.resetHeaderCacheForTesting()
        let composed = ClientIdentity.composeAuthorizationHeader(
            scheme: "MediaBrowser", userId: "UID", token: "TOK")

        // 用设备实际值拼出黄金串（deviceID/deviceName/version 是进程常量）。
        let expected = "MediaBrowser "
            + "Client=\"OcPlayer\", "
            + "Device=\"\(ClientIdentity.deviceName)\", "
            + "DeviceId=\"\(ClientIdentity.deviceID)\", "
            + "Version=\"\(ClientIdentity.version)\", "
            + "UserId=\"UID\", "
            + "Token=\"TOK\""
        XCTAssertEqual(composed, expected, "字段顺序 / 分隔符 / 引号形式都是契约")
    }

    /// 无 userId / token 时**不追加空字段**（不是 `UserId=""`）。
    func testAuthorizationHeaderOmitsEmptyFields() {
        ClientIdentity.resetHeaderCacheForTesting()
        let composed = ClientIdentity.composeAuthorizationHeader(
            scheme: "MediaBrowser", userId: nil, token: nil)
        XCTAssertFalse(composed.contains("UserId="))
        XCTAssertFalse(composed.contains("Token="))
        XCTAssertFalse(composed.hasSuffix(", "), "不能留下尾随分隔符")

        // nil 与空串必须产出**同一个**头（compose 里按 isEmpty 判空），
        // 缓存键也因此合并 —— 这条保证两种写法不会算出两种指纹。
        let emptyStrings = ClientIdentity.composeAuthorizationHeader(
            scheme: "MediaBrowser", userId: "", token: "")
        XCTAssertEqual(composed, emptyStrings)
    }

    // MARK: - 认证头缓存（P1-12）

    /// 缓存值必须与「不走缓存现拼」的值逐字节一致。
    ///
    /// 这条是缓存透明性的守门人：缓存实现写错（键少一个字段、拼错分隔符）时，
    /// 页面上的表现是「图片鉴权偶发失败」，极难查。
    func testMemoizedHeaderMatchesFreshComposition() {
        ClientIdentity.resetHeaderCacheForTesting()

        for scheme in ["MediaBrowser", "Emby"] {
            let cached = ClientIdentity.authorizationHeader(
                scheme: scheme, userId: "user-1", token: "token-abc")
            let fresh = ClientIdentity.composeAuthorizationHeader(
                scheme: scheme, userId: "user-1", token: "token-abc")
            XCTAssertEqual(cached, fresh, "缓存版与现拼版必须一致（scheme=\(scheme)）")
            // 再调一次走缓存，仍要一致。
            XCTAssertEqual(
                ClientIdentity.authorizationHeader(
                    scheme: scheme, userId: "user-1", token: "token-abc"),
                fresh)
        }
    }

    /// **缓存键必须含 token。**
    ///
    /// 只按 `userId` 缓存是这里最致命的错法：Jellyfin 的 access token 会轮换，
    /// 按 userId 缓存会让重登之后**仍发旧 token**，表现为「重新登录了但还是 401」。
    func testHeaderCacheDistinguishesTokens() {
        ClientIdentity.resetHeaderCacheForTesting()

        let first = ClientIdentity.authorizationHeader(
            scheme: "MediaBrowser", userId: "user-1", token: "token-old")
        let second = ClientIdentity.authorizationHeader(
            scheme: "MediaBrowser", userId: "user-1", token: "token-new")

        XCTAssertNotEqual(first, second, "token 变了头必须跟着变")
        XCTAssertTrue(second.contains(#"Token="token-new""#))
        XCTAssertFalse(second.contains("token-old"))
    }

    /// 缓存键必须含 scheme：Jellyfin 用 `MediaBrowser`、Emby 用 `Emby`。
    func testHeaderCacheDistinguishesScheme() {
        ClientIdentity.resetHeaderCacheForTesting()

        let jellyfin = ClientIdentity.authorizationHeader(
            scheme: "MediaBrowser", userId: "u", token: "t")
        let emby = ClientIdentity.authorizationHeader(
            scheme: "Emby", userId: "u", token: "t")

        XCTAssertTrue(jellyfin.hasPrefix("MediaBrowser "))
        XCTAssertTrue(emby.hasPrefix("Emby "))
        XCTAssertNotEqual(jellyfin, emby)
    }

    /// 缓存键必须含 userId（图片缓存身份靠它区分账号）。
    func testHeaderCacheDistinguishesUsers() {
        ClientIdentity.resetHeaderCacheForTesting()

        let a = ClientIdentity.authorizationHeader(
            scheme: "MediaBrowser", userId: "user-a", token: "t")
        let b = ClientIdentity.authorizationHeader(
            scheme: "MediaBrowser", userId: "user-b", token: "t")

        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.contains(#"UserId="user-b""#))
    }

    /// **注入的 Bundle 不能受缓存影响**：`version(in:)` 本体没有缓存，
    /// 连续读两个不同的临时 Bundle 必须各自拿到自己的版本。
    ///
    /// 这条守住的是清单点名的坑：如果为了加速而给 `version(in:)` 加无键全局缓存，
    /// 这里就会串台（第二次读到第一次的 `"1.2.3 (45)"`）。
    func testVersionInInjectedBundleIsNotCachedAcrossBundles() throws {
        let first = try makeBundle(shortVersion: "1.2.3", build: "45")
        let second = try makeBundle(shortVersion: nil, build: "99")

        XCTAssertEqual(ClientIdentity.version(in: first), "1.2.3 (45)")
        XCTAssertEqual(ClientIdentity.version(in: second), "99", "第二个 Bundle 不能被第一个的结果污染")
        // 反过来再读一次第一个，也仍要正确。
        XCTAssertEqual(ClientIdentity.version(in: first), "1.2.3 (45)")
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
