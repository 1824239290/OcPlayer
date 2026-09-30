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
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
                        credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
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
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
                        credentialsDirectory: TestSupport.isolatedCredentialsDirectory())

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
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
                        credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
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
        let store = MoviePilotStore(defaults: TestSupport.isolatedDefaults(),
                        credentialsDirectory: TestSupport.isolatedCredentialsDirectory())
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

    // MARK: - 密码默认不落盘

    private func makeStore(defaults: UserDefaults, directory: URL) -> MoviePilotStore {
        MoviePilotStore(defaults: defaults, credentialsDirectory: directory)
    }

    /// 默认（开关关闭）下密码只活在本进程内：**重启后读不到**。
    /// 这是本项的核心承诺——密码不再明文躺在会被备份带走的存储里。
    func testPasswordIsNotPersistedByDefault() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()

        let first = makeStore(defaults: defaults, directory: directory)
        first.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "secret")
        XCTAssertEqual(first.password, "secret", "同一会话内必须可用（支撑静默重登）")
        XCTAssertFalse(first.rememberPassword, "默认关")

        // 模拟重启：换一个实例，内存副本没了。
        let restarted = makeStore(defaults: defaults, directory: directory)
        XCTAssertEqual(restarted.password, "", "默认不该落盘")
        XCTAssertEqual(restarted.username, "admin", "非机密项照旧保留")
    }

    /// 打开开关后密码跨启动保留，且在凭据文件里（不是 UserDefaults）。
    func testPasswordIsPersistedWhenRememberPasswordIsOn() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()

        let first = makeStore(defaults: defaults, directory: directory)
        first.rememberPassword = true
        first.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "secret")

        let restarted = makeStore(defaults: defaults, directory: directory)
        XCTAssertTrue(restarted.rememberPassword)
        XCTAssertEqual(restarted.password, "secret", "开关打开时必须跨启动记住")

        // 不能回落到 UserDefaults：那条路会被备份带走。
        XCTAssertNil(defaults.string(forKey: "dev.jumusu.ocplayer.moviepilot.password"))
    }

    /// 关掉开关要立即删掉已落盘的密码——否则「开关关了但密码还在」与语义不符。
    func testTurningOffRememberPasswordDeletesStoredPassword() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()

        let store = makeStore(defaults: defaults, directory: directory)
        store.rememberPassword = true
        store.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "secret")

        store.rememberPassword = false

        XCTAssertEqual(makeStore(defaults: defaults, directory: directory).password, "",
                       "关掉开关后不该还能读到")
    }

    /// 打开开关时把**当前会话已输入的**密码落盘，省得用户重输一遍。
    func testEnablingRememberPasswordPersistsSessionPassword() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()

        let store = makeStore(defaults: defaults, directory: directory)
        store.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "typed-now")
        store.rememberPassword = true

        XCTAssertEqual(makeStore(defaults: defaults, directory: directory).password, "typed-now")
    }

    /// 老版本的明文密码**只删不迁**（默认关）。它已经在 UserDefaults/备份里躺过，
    /// 留着只是让暴露继续。
    func testLegacyPlaintextPasswordIsDeletedNotMigrated() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()
        let legacyKey = "dev.jumusu.ocplayer.moviepilot.password"
        defaults.set("legacy-plaintext", forKey: legacyKey)

        let store = makeStore(defaults: defaults, directory: directory)

        XCTAssertNil(defaults.string(forKey: legacyKey), "旧明文密码必须被删掉")
        XCTAssertEqual(store.password, "", "且不能被当成已记住的密码")
    }

    /// 令牌是**可撤销**的，风险低于密码，所以迁移到凭据文件（保留「保持登录」）。
    func testLegacyTokenIsMigratedToCredentialFile() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()
        let legacyKey = "dev.jumusu.ocplayer.moviepilot.accessToken"
        defaults.set("legacy-token", forKey: legacyKey)

        let store = makeStore(defaults: defaults, directory: directory)
        XCTAssertEqual(store.accessToken, "legacy-token", "旧令牌必须仍可用")
        XCTAssertNil(defaults.string(forKey: legacyKey), "迁移后必须删掉 UserDefaults 里的副本")

        XCTAssertEqual(makeStore(defaults: defaults, directory: directory).accessToken, "legacy-token",
                       "新实例应从凭据文件读到")
    }

    /// 有有效令牌但没记住密码时，仍算「已配置」。
    /// 否则重启后 `MoviePilotHomeView` 会对着一个能正常用的账号显示「未配置」空态。
    func testConfiguredWithTokenButWithoutRememberedPassword() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()

        let store = makeStore(defaults: defaults, directory: directory)
        store.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "secret")
        store.accessToken = "valid-token"

        let restarted = makeStore(defaults: defaults, directory: directory)
        XCTAssertEqual(restarted.password, "", "密码没记住")
        XCTAssertTrue(restarted.hasToken)
        XCTAssertTrue(restarted.isConfigured, "有令牌就算配置好了")
    }

    /// 退出登录要连本次会话的内存副本一起清：留一份与「交还凭据」矛盾。
    func testClearSessionDropsSessionPassword() {
        let defaults = TestSupport.isolatedDefaults()
        let directory = TestSupport.isolatedCredentialsDirectory()

        let store = makeStore(defaults: defaults, directory: directory)
        store.updateCredentials(serverURLString: "http://10.0.0.2:3000", username: "admin", password: "secret")
        XCTAssertEqual(store.password, "secret")

        store.clearSession()

        XCTAssertEqual(store.password, "", "退出登录后内存副本也要清")
        XCTAssertEqual(store.username, "admin", "地址与用户名保留，方便下次登录")
    }
}
