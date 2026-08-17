import XCTest
@testable import JellyfinKit

/// ServerStore 档案持久化（UserDefaults）+ token 仓库（内存版 Keychain）。
final class ServerStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ServerStore!
    private var tokens: InMemoryTokenStore!

    override func setUp() {
        super.setUp()
        let suiteName = "ServerStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        tokens = InMemoryTokenStore()
        store = ServerStore(defaults: defaults, tokens: tokens)
    }

    private func profile(id: String, name: String = "home-nas") -> ServerProfile {
        ServerProfile(id: id, serverName: name, baseURL: URL(string: "http://nas.local:8096")!,
                      userID: "u1", userName: "jumusu", serverVersion: "10.9.11")
    }

    func testEmptyStoreHasNoCurrentProfile() {
        XCTAssertNil(store.currentProfile)
        XCTAssertNil(JellyfinServer(restoringFrom: store))
    }

    func testActivatePersistsProfileTokenAndCurrent() {
        store.activate(profile(id: "srv1:u1"), token: "tok-1")
        store.activate(profile(id: "srv2:u2"), token: "tok-2")

        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.currentProfile?.id, "srv2:u2")

        // 同一 profile 再登录 → 更新而不是重复
        store.activate(profile(id: "srv2:u2", name: "renamed"), token: "tok-2b")
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.token(for: store.currentProfile!), "tok-2b")

        // 恢复会话
        let server = JellyfinServer(restoringFrom: store)
        XCTAssertEqual(server?.profile.id, "srv2:u2")
        XCTAssertEqual(server?.accessToken, "tok-2b")
    }

    func testRemoveDeletesTokenAndFallsBackToOtherProfile() {
        store.activate(profile(id: "srv1:u1"), token: "tok-1")
        store.activate(profile(id: "srv2:u2"), token: "tok-2")

        store.remove(id: "srv2:u2")
        XCTAssertEqual(store.profiles.map(\.id), ["srv1:u1"])
        XCTAssertEqual(store.currentProfile?.id, "srv1:u1")
        XCTAssertNil(tokens.read(account: "srv2:u2"))
    }

    func testSignOutKeepsProfileButDropsToken() {
        store.activate(profile(id: "srv1:u1"), token: "tok-1")
        store.signOut(id: "srv1:u1")

        XCTAssertEqual(store.profiles.count, 1, "登出不删档案，下次一键重连")
        XCTAssertNil(store.token(for: store.profiles[0]))
        XCTAssertNil(JellyfinServer(restoringFrom: store), "没有 token 就无法静默恢复")
    }
}
