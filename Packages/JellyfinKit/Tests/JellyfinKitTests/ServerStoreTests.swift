import Dispatch
import XCTest
@testable import JellyfinKit

/// ServerStore 档案持久化（UserDefaults）+ 可替换 token 仓库。
final class ServerStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ServerStore!
    private var tokens: InMemoryTokenStore!

    /// 每个用例独立的凭据目录。**必须用**：不注入时 `LocalTokenStore` 会落到
    /// `CredentialFileStore.shared`，也就是开发机/CI 上**真实的**凭据文件。
    private var credentialsDirectory: URL!


    override func setUp() {
        super.setUp()
        let suiteName = "ServerStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        tokens = InMemoryTokenStore()
        credentialsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jellyfin-cred-\(UUID().uuidString)")
        store = ServerStore(defaults: defaults, tokens: tokens,
                            credentialsDirectory: credentialsDirectory)
    }

    override func tearDown() {
        if let credentialsDirectory {
            try? FileManager.default.removeItem(at: credentialsDirectory)
        }
        super.tearDown()
    }

    private func profile(id: String, name: String = "home-nas") -> ServerProfile {
        ServerProfile(id: id, serverName: name, baseURL: URL(string: "http://nas.local:8096")!,
                      userID: "u1", userName: "jumusu", serverVersion: "10.9.11")
    }

    func testEmptyStoreHasNoCurrentProfile() {
        XCTAssertNil(store.currentProfile)
        XCTAssertNil(MediaServerFactory.restore(from: store))
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
        let server = MediaServerFactory.restore(from: store)
        XCTAssertEqual(server?.profile.id, "srv2:u2")
        // accessToken 是 JellyfinServer 的实现细节，协议不暴露；铸型后验证 token 确实进了会话。
        XCTAssertEqual((server as? JellyfinServer)?.accessToken, "tok-2b")
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
        XCTAssertNil(MediaServerFactory.restore(from: store), "没有 token 就无法静默恢复")
    }

    func testDefaultTokenStorePersistsLocallyAcrossInstances() {
        let profile = profile(id: "srv1:u1")
        let firstStore = ServerStore(defaults: defaults, credentialsDirectory: credentialsDirectory)
        firstStore.activate(profile, token: "tok-local")

        let restoredStore = ServerStore(defaults: defaults, credentialsDirectory: credentialsDirectory)
        XCTAssertEqual(restoredStore.token(for: profile), "tok-local")
        XCTAssertEqual((MediaServerFactory.restore(from: restoredStore) as? JellyfinServer)?.accessToken, "tok-local")

        restoredStore.signOut(id: profile.id)
        XCTAssertNil(ServerStore(defaults: defaults, credentialsDirectory: credentialsDirectory).token(for: profile))
    }

    /// 回归（老版本升级）：token 曾存在 UserDefaults 里，现在搬到凭据文件。
    /// 升级用户第一次读到旧值时必须**既拿到值、又把旧键清掉**——
    /// 只搬不删的话，明文 token 会一直留在仍会进备份的 UserDefaults 里，
    /// 这次迁移的收益就等于零。
    func testLegacyUserDefaultsTokenIsMigratedAndRemoved() {
        let profile = profile(id: "srv9:u9")
        let legacyKey = "dev.jumusu.ocplayer.token.\(profile.id)"
        defaults.set("tok-legacy", forKey: legacyKey)

        // 读一次即触发迁移。
        let migrated = ServerStore(defaults: defaults, credentialsDirectory: credentialsDirectory)
        XCTAssertEqual(migrated.token(for: profile), "tok-legacy", "旧值必须仍可用")

        XCTAssertNil(defaults.string(forKey: legacyKey), "迁移后必须删掉 UserDefaults 里的明文副本")

        // 再开一个实例：值应来自凭据文件，而不是 UserDefaults。
        let fresh = ServerStore(defaults: defaults, credentialsDirectory: credentialsDirectory)
        XCTAssertEqual(fresh.token(for: profile), "tok-legacy")
    }

    func testConcurrentSavesDoNotLoseProfiles() {
        let testedStore = store!
        let profiles = (0..<200).map { profile(id: "srv:\($0)") }

        DispatchQueue.concurrentPerform(iterations: profiles.count) { index in
            testedStore.save(profiles[index], makeCurrent: false)
        }

        XCTAssertEqual(Set(testedStore.profiles.map(\.id)), Set(profiles.map(\.id)))
        XCTAssertEqual(testedStore.profiles.count, profiles.count)
    }

    // MARK: - ServerKind

    func testProfileKindRoundTripsThroughCodable() throws {
        let emby = ServerProfile(id: "srv:e1", serverName: "emby-nas",
                                 baseURL: URL(string: "http://nas.local:8096/emby")!,
                                 userID: "u1", kind: .emby)
        let data = try JSONEncoder().encode([emby])
        let decoded = try JSONDecoder().decode([ServerProfile].self, from: data)
        XCTAssertEqual(decoded.first?.kind, .emby)

        // UserDefaults 走一遍：落盘 → 读回，kind 不丢
        store.activate(emby, token: "tok-emby")
        XCTAssertEqual(store.currentProfile?.kind, .emby)
    }

    /// 0.1.4 及之前落盘的 profile 没有 kind 字段：解码必须成功且默认 Jellyfin。
    func testLegacyProfileJSONWithoutKindDecodesAsJellyfin() throws {
        let legacy = """
        [{"id":"srv-legacy:user-9","serverName":"home-nas",
          "baseURL":"http:\\/\\/nas.local:8096","userID":"user-9",
          "userName":"jumusu","serverVersion":"10.9.11"}]
        """
        let data = try JSONEncoder().encode(
            try JSONDecoder().decode([ServerProfile].self, from: Data(legacy.utf8))
        )
        defaults.set(data, forKey: "dev.jumusu.ocplayer.servers")
        tokens.save("tok-legacy", account: "srv-legacy:user-9")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].kind, .jellyfin)
        XCTAssertNotNil(MediaServerFactory.restore(from: store), "旧档案必须能静默恢复")
    }

    // MARK: - 启动默认服务器

    func testDefaultServerIDRoundTripsAndClearsWithEmptyString() {
        XCTAssertNil(store.defaultServerID)

        store.defaultServerID = "srv1:u1"
        XCTAssertEqual(ServerStore(defaults: defaults, credentialsDirectory: credentialsDirectory).defaultServerID, "srv1:u1")

        store.defaultServerID = ""
        XCTAssertNil(store.defaultServerID)

        store.defaultServerID = "srv1:u1"
        store.defaultServerID = nil
        XCTAssertNil(store.defaultServerID)
    }

    func testLaunchProfilePrefersDefaultOverCurrent() {
        store.activate(profile(id: "srv1:u1", name: "primary"), token: "tok-1")
        store.activate(profile(id: "srv2:u2", name: "secondary"), token: "tok-2")
        // 当前是 srv2；把启动默认指回 srv1
        store.defaultServerID = "srv1:u1"

        XCTAssertEqual(store.currentProfile?.id, "srv2:u2")
        XCTAssertEqual(store.launchProfile?.id, "srv1:u1")
        XCTAssertEqual(MediaServerFactory.restore(from: store)?.profile.id, "srv1:u1")
    }

    func testLaunchProfileFallsBackToCurrentWhenDefaultMissing() {
        store.activate(profile(id: "srv1:u1"), token: "tok-1")
        store.activate(profile(id: "srv2:u2"), token: "tok-2")
        store.defaultServerID = "srv-ghost:gone"

        XCTAssertEqual(store.launchProfile?.id, store.currentProfile?.id)
        XCTAssertEqual(MediaServerFactory.restore(from: store)?.profile.id, "srv2:u2")
    }

    func testRemoveClearsDefaultWhenDeletingThatProfile() {
        store.activate(profile(id: "srv1:u1"), token: "tok-1")
        store.activate(profile(id: "srv2:u2"), token: "tok-2")
        store.defaultServerID = "srv2:u2"

        store.remove(id: "srv2:u2")
        XCTAssertNil(store.defaultServerID, "删掉默认启动服务器后不应留下悬空 ID")
        XCTAssertEqual(store.launchProfile?.id, "srv1:u1")
        XCTAssertEqual(MediaServerFactory.restore(from: store)?.profile.id, "srv1:u1")
    }

    func testRemoveKeepsDefaultWhenDeletingAnotherProfile() {
        store.activate(profile(id: "srv1:u1"), token: "tok-1")
        store.activate(profile(id: "srv2:u2"), token: "tok-2")
        store.defaultServerID = "srv1:u1"

        store.remove(id: "srv2:u2")
        XCTAssertEqual(store.defaultServerID, "srv1:u1")
        XCTAssertEqual(MediaServerFactory.restore(from: store)?.profile.id, "srv1:u1")
    }

    /// 默认服务器没有 token（用户单独登出了它）时，启动仍回退到有 token 的档案。
    func testRestoreSkipsDefaultWithoutTokenAndUsesFirstWithToken() {
        let defaultNoToken = profile(id: "srv:a", name: "default-a")
        let otherWithToken = profile(id: "srv:b", name: "other-b")
        // 手工 save 避免 activate 自动写 current / token
        store.save(defaultNoToken, makeCurrent: false)
        store.save(otherWithToken, makeCurrent: false)
        tokens.save("tok-b", account: "srv:b")
        store.defaultServerID = "srv:a"

        XCTAssertEqual(store.launchProfile?.id, "srv:a")
        XCTAssertEqual(MediaServerFactory.restore(from: store)?.profile.id, "srv:b")
    }
}
