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

    /// 密码不是标识符：原样存取，含首尾空格也不许被 trim（trim 了登录会永远失败且无提示）。
    func testPasswordKeepsWhitespace() {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults())

        store.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: " pass with spaces ")
        XCTAssertEqual(store.password, " pass with spaces ")

        store.password = "  padded  "
        XCTAssertEqual(store.password, "  padded  ")

        // 空串仍然清键（判空用原始值）。
        store.password = ""
        XCTAssertEqual(store.password, "")
    }

    /// 登录前打快照、失败回滚：四键（含旧 token）原样还原。
    func testCredentialSnapshotRestoresFailedLoginState() {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults())
        store.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "old pass")
        store.accessToken = "old-token"

        let snapshot = store.credentialSnapshot()

        // 「保存并登录」的落盘动作：新地址/账号/密码 + 旧 token 作废。
        store.updateCredentials(serverURLString: "http://10.0.0.3:3000", username: "other", password: "typo")
        XCTAssertNil(store.accessToken)

        // 登录失败 → 回滚。
        store.restore(snapshot)
        XCTAssertEqual(store.serverURLString, "http://10.0.0.2:3000")
        XCTAssertEqual(store.username, "admin")
        XCTAssertEqual(store.password, "old pass")
        XCTAssertEqual(store.accessToken, "old-token")
        XCTAssertTrue(store.hasToken)
    }

    /// 快照里的 nil（键不存在）回滚时是删键，不是写空串——否则「从未配置」会变成
    /// 「配置了空地址」。
    func testCredentialRestoreDeletesAbsentKeys() {
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults())
        let empty = store.credentialSnapshot()
        XCTAssertNil(empty.serverURLString)
        XCTAssertNil(empty.accessToken)

        store.updateCredentials(serverURLString: "http://10.0.0.9:3000", username: "admin", password: "p")
        store.accessToken = "t"

        store.restore(empty)
        XCTAssertNil(store.serverURLString)
        XCTAssertNil(store.accessToken)
        XCTAssertEqual(store.username, "")
        XCTAssertEqual(store.password, "")
        XCTAssertFalse(store.isConfigured)
    }
}
