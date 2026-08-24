import XCTest
@testable import MoviePilotKit

final class MoviePilotStoreTests: XCTestCase {

    func testNormalizedURLAllowsHTTPForLAN() {
        XCTAssertEqual(
            MoviePilotStore.normalizedURL(from: "http://192.168.1.10:3000")?
                .absoluteString,
            "http://192.168.1.10:3000"
        )
        XCTAssertEqual(
            MoviePilotStore.normalizedURL(from: "https://mp.example.com")?
                .absoluteString,
            "https://mp.example.com"
        )
        // 缺 scheme 补 http（局域网部署为主），与弹幕网关（补 https）相反。
        XCTAssertEqual(
            MoviePilotStore.normalizedURL(from: "192.168.1.10:3000")?
                .absoluteString,
            "http://192.168.1.10:3000"
        )
    }

    func testNormalizedURLRejectsNonOrigin() {
        XCTAssertNil(MoviePilotStore.normalizedURL(from: ""))
        XCTAssertNil(MoviePilotStore.normalizedURL(from: "ftp://example.com"))
        XCTAssertNil(MoviePilotStore.normalizedURL(from: "http://example.com/api/v1"))
        XCTAssertNil(MoviePilotStore.normalizedURL(from: "http://user:pass@example.com"))
        XCTAssertNil(MoviePilotStore.normalizedURL(from: "http://example.com?q=1"))
        XCTAssertNil(MoviePilotStore.normalizedURL(from: "http://example.com#frag"))
    }

    func testCredentialsLifecycle() {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults())
        XCTAssertFalse(store.isConfigured)

        store.updateCredentials(serverURLString: "http://192.168.1.10:3000", username: "admin", password: "secret")
        store.accessToken = "old-token"
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.hasToken)

        // 保存新凭据必须作废旧 token。
        store.updateCredentials(serverURLString: "http://192.168.1.10:3000", username: "admin", password: "new")
        XCTAssertNil(store.accessToken)
        XCTAssertEqual(store.username, "admin")
        XCTAssertEqual(store.password, "new")

        // 退出登录：清密码与 token，留地址和用户名。
        store.accessToken = "t"
        store.clearSession()
        XCTAssertNil(store.accessToken)
        XCTAssertEqual(store.password, "")
        XCTAssertEqual(store.serverURLString, "http://192.168.1.10:3000")
        XCTAssertEqual(store.username, "admin")
        XCTAssertFalse(store.isConfigured)

        store.clearAll()
        XCTAssertNil(store.serverURLString)
        XCTAssertEqual(store.username, "")
    }
}
