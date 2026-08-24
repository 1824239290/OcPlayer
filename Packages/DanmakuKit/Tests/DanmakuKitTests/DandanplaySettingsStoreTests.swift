import XCTest
@testable import DanmakuKit

final class DandanplaySettingsStoreTests: XCTestCase {

    private func makeSuite() -> (UserDefaults, DandanplaySettingsStore, String) {
        let suite = "ocp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = DandanplaySettingsStore(
            defaults: defaults,
            credentialStore: InMemoryCredentialStore()
        )
        return (defaults, store, suite)
    }

    func testDefaults() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(s.gatewayURLString)
        XCTAssertEqual(s.gatewayURL, DandanplaySettingsStore.defaultGatewayURL)
        // 未设置时回落内置公共 Key，开箱即用。
        XCTAssertEqual(s.apiKey, DandanplaySettingsStore.defaultAPIKey)
        XCTAssertTrue(s.isConfigured)
        s.apiKey = "sk-default"
        XCTAssertEqual(s.apiKey, "sk-default")
        XCTAssertTrue(s.isConfigured)
        // 清空 → 回落内置默认 Key（自定义失效）。
        s.apiKey = ""
        XCTAssertEqual(s.apiKey, DandanplaySettingsStore.defaultAPIKey)
        XCTAssertTrue(s.isConfigured)
    }

    func testURLStringRoundTrip() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        s.gatewayURLString = "https://my-gateway.workers.dev"
        XCTAssertEqual(s.gatewayURLString, "https://my-gateway.workers.dev")
        XCTAssertEqual(s.gatewayURL, URL(string: "https://my-gateway.workers.dev"))

        // 清空 → 回到默认，而不是回弹旧值。
        s.gatewayURLString = ""
        XCTAssertNil(s.gatewayURLString)
        XCTAssertEqual(s.gatewayURL, DandanplaySettingsStore.defaultGatewayURL)
    }

    func testSchemeAutoCompletion() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        s.gatewayURLString = "dandanplay.3841625.xyz"
        XCTAssertEqual(s.gatewayURL.absoluteString, "https://dandanplay.3841625.xyz")

        s.gatewayURLString = "https://gw.example.com"
        XCTAssertEqual(s.gatewayURL.absoluteString, "https://gw.example.com")

        s.gatewayURLString = "http://gw.example.com"
        XCTAssertEqual(s.gatewayURL, DandanplaySettingsStore.defaultGatewayURL)
        XCTAssertFalse(s.isConfigured) // 明文 HTTP 不允许携带 API Key
    }

    func testInvalidURLFallsBackToDefault() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        s.gatewayURLString = "https://"
        XCTAssertEqual(s.gatewayURL, DandanplaySettingsStore.defaultGatewayURL)
    }

    func testGatewayURLSetter() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        s.gatewayURL = URL(string: "https://custom.example.com")!
        XCTAssertEqual(s.gatewayURLString, "https://custom.example.com")
    }

    func testIsConfigured() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        s.apiKey = "k"
        s.gatewayURLString = "gw.example.com"
        XCTAssertTrue(s.isConfigured) // 无 scheme 自动补 https

        // 清空自定义 Key 会回落内置默认 Key，所以 isConfigured 仍为 true；
        // 网关地址无效才是未配置的主因。
        s.apiKey = ""
        XCTAssertTrue(s.isConfigured) // 回落内置默认 Key

        s.apiKey = "k"
        s.gatewayURLString = "ftp://gw.example.com"
        XCTAssertFalse(s.isConfigured) // 非 http(s)

        s.gatewayURLString = "https://"
        XCTAssertFalse(s.isConfigured) // 无 host
    }

    func testAPIKeyRoundTrip() {
        let (defaults, store, suite) = makeSuite()
        var s = store
        defer { defaults.removePersistentDomain(forName: suite) }
        s.apiKey = "sk-abc"
        XCTAssertEqual(s.apiKey, "sk-abc")
        s.apiKey = ""
        // 清空自定义 Key → 回落内置默认，而非变成空串。
        XCTAssertEqual(s.apiKey, DandanplaySettingsStore.defaultAPIKey)
    }

    /// 规范化是纯函数：核心边界单测。
    func testNormalizedURLFunction() {
        XCTAssertEqual(
            DandanplaySettingsStore.normalizedURL(from: "dandanplay.3841625.xyz")?.absoluteString,
            "https://dandanplay.3841625.xyz"
        )
        XCTAssertEqual(
            DandanplaySettingsStore.normalizedURL(from: "https://gw.example.com")?.absoluteString,
            "https://gw.example.com"
        )
        XCTAssertNil(DandanplaySettingsStore.normalizedURL(from: ""))
        XCTAssertNil(DandanplaySettingsStore.normalizedURL(from: "   "))
        XCTAssertNil(DandanplaySettingsStore.normalizedURL(from: "http://gw.example.com"))
        XCTAssertNil(DandanplaySettingsStore.normalizedURL(from: "https://gw.example.com/path"))
        XCTAssertNil(DandanplaySettingsStore.normalizedURL(from: "https://gw.example.com/?api_key=secret"))
        XCTAssertNil(DandanplaySettingsStore.normalizedURL(from: "https://user:password@gw.example.com"))
    }
}

/// 测试用内存凭据存储。
private final class InMemoryCredentialStore: DandanplayCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func readAPIKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func writeAPIKey(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func deleteAPIKey() {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}
