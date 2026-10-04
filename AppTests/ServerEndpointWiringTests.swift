import JellyfinKit
@testable import OcPlayer
import XCTest

/// App 层的地址决议接线：决议器在后台探活选中的地址，必须
/// ① 写回档案（主线程，`ServerStore` 的写路径约束）② 让 `serverEndpointURL` 跟着变
/// （视图据此重算图片 / 播放流地址）。
///
/// 探活走 `MockURLProtocol`：这条链路的真实语义是「哪条地址通」，用 HTTP mock 表达
/// 最直接（延迟择优的算法细节由 `ServerEndpointDirectoryTests` 覆盖）。
@MainActor
final class ServerEndpointWiringTests: XCTestCase {

    /// 局域网那条用 TEST-NET-1（RFC 5737 保留段）：万一 mock 没拦住，请求也只会
    /// 掉进黑洞，绝不至于真的连上开发者局域网里的设备（这正是本仓库对测试的底线）。
    /// Tailscale 那条取 100.64/10 段里的地址。
    private let lan = URL(string: "http://192.0.2.10:8096")!
    private let tailscale = URL(string: "http://100.64.1.20:8096")!

    private func makeProfile() -> ServerProfile {
        ServerProfile(
            id: "srv-1:u1", serverName: "home-nas", baseURL: lan, userID: "u1",
            userName: "jumusu", addresses: [ServerAddress(url: tailscale)],
            serverID: "srv-1")
    }

    private func makeStore() -> ServerStore {
        ServerStore(defaults: TestSupport.isolatedDefaults("EndpointWiring-\(UUID().uuidString)"),
                    tokens: InMemoryTokenStore())
    }

    /// 局域网那条不通、Tailscale 通（典型的「人在外面」）：决议换址后要落进档案，
    /// 界面状态也要跟着换。
    func testResolvedAddressIsPersistedAndPublished() async throws {
        let store = makeStore()
        let profile = makeProfile()
        store.activate(profile, token: "tok-1")
        let configuration = TestSupport.mockedSessionConfiguration()
        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store, sessionConfiguration: configuration))

        MockURLProtocol.handler = { request in
            if request.url?.host == "192.0.2.10" { throw URLError(.cannotConnectToHost) }
            return TestSupport.response(#"{"Id":"srv-1","ServerName":"home-nas"}"#, status: 200,
                                        for: request.url!)
        }
        defer { MockURLProtocol.handler = nil }

        let app = AppModel(store: store)
        app.server = server
        app.attachEndpoints(to: server, sessionConfiguration: configuration)
        await waitUntil { app.serverEndpointURL == self.tailscale }

        XCTAssertEqual(app.serverEndpointURL, tailscale, "界面要显示当前生效地址")
        XCTAssertEqual(app.store.profiles[0].baseURL, tailscale, "换址结论要写回档案")
        XCTAssertEqual(app.store.profiles[0].addresses.map(\.url), [lan],
                       "被换下的地址退成备选，不能丢")
    }

    /// 原地址可通且不算慢：不换址，也就不该动档案（避免无意义的 UserDefaults 写入）。
    func testKeepingAddressDoesNotRewriteProfile() async throws {
        let store = makeStore()
        let profile = makeProfile()
        store.activate(profile, token: "tok-1")
        let configuration = TestSupport.mockedSessionConfiguration()
        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store, sessionConfiguration: configuration))

        let probes = Counter()
        MockURLProtocol.handler = { request in
            probes.increment()
            return TestSupport.response(#"{"Id":"srv-1"}"#, status: 200, for: request.url!)
        }
        defer { MockURLProtocol.handler = nil }

        let app = AppModel(store: store)
        app.server = server
        app.attachEndpoints(to: server, sessionConfiguration: configuration)
        // 必须等探活**真的跑过**再断言「状态没变」：固定 sleep 是恒真断言，
        // 探活整个坏掉（mock 没拦住 / 全 nil）时它照样绿。
        await waitUntil { probes.count >= 2 }

        XCTAssertGreaterThanOrEqual(probes.count, 2, "两个候选地址都该被探到")
        XCTAssertEqual(app.serverEndpointURL, lan)
        XCTAssertEqual(app.store.profiles[0].baseURL, lan)
    }

    /// 固定到 Tailscale 后，即使局域网明显更近也不换（用户在设置页的明确选择）。
    func testPinnedAddressWins() async throws {
        let store = makeStore()
        var profile = makeProfile()
        profile.pinnedURL = tailscale
        store.activate(profile, token: "tok-1")
        let configuration = TestSupport.mockedSessionConfiguration()
        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store, sessionConfiguration: configuration))

        MockURLProtocol.handler = { request in
            TestSupport.response(#"{"Id":"srv-1"}"#, status: 200, for: request.url!)
        }
        defer { MockURLProtocol.handler = nil }

        let app = AppModel(store: store)
        app.server = server
        app.attachEndpoints(to: server, sessionConfiguration: configuration)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(app.serverEndpointURL, tailscale)
        XCTAssertEqual(app.store.profiles[0].baseURL, tailscale)
    }

    /// 换会话之后，旧决议器迟到的回调必须被忽略：它会把界面与新档案指回上一台
    /// 服务器的地址。
    func testCallbackFromReplacedSessionIsIgnored() async throws {
        let store = makeStore()
        let profile = makeProfile()
        store.activate(profile, token: "tok-1")
        let app = AppModel(store: store)

        // A 上线，然后又换成 B：A 的决议器若迟到回调，绝不能把界面/档案指回 A 的地址。
        // 两个会话都从 store 里的档案恢复，与真实路径同源。
        let configuration = TestSupport.mockedSessionConfiguration()
        let serverA = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store, sessionConfiguration: configuration))
        app.server = serverA
        app.attachEndpoints(to: serverA, sessionConfiguration: configuration)

        let otherProfile = ServerProfile(
            id: "srv-2:u2", serverName: "other-nas", baseURL: tailscale, userID: "u2",
            serverID: "srv-2")
        store.activate(otherProfile, token: "tok-2")
        let serverB = try XCTUnwrap(JellyfinServer.resume(
            profile: otherProfile, from: store, sessionConfiguration: configuration))
        app.server = serverB
        app.serverEndpointURL = otherProfile.baseURL

        // A 的迟到回调：
        app.serverEndpointChanged(to: tailscale, profileID: profile.id)

        XCTAssertEqual(app.serverEndpointURL, otherProfile.baseURL, "旧会话的地址不该覆盖新会话")
        XCTAssertEqual(app.store.profiles.first(where: { $0.id == profile.id })?.baseURL, lan,
                       "也不该改档案")
    }

    /// 给 Emby 档案添加地址必须补 `/emby` 前缀（请求地址拼在 base 路径之后，缺前缀
    /// 就全链路 404，而 404 不算「地址不通」不会换址 —— 会卡死在那条候选上）。
    func testAddingEmbyAddressAppliesAPIPrefix() async throws {
        let store = makeStore()
        let profile = ServerProfile(
            id: "srv-9:u1", serverName: "emby-nas",
            baseURL: URL(string: "http://192.0.2.10:8096/emby")!, userID: "u1",
            kind: .emby, serverID: "srv-9")
        store.activate(profile, token: "tok-1")

        MockURLProtocol.handler = { request in
            // 探活本身走的是无前缀的根路径（Emby 对 `/System/Info/Public` 同样响应）。
            TestSupport.response(#"{"Id":"srv-9","ServerName":"emby-nas","ProductName":"Emby Server"}"#,
                                 status: 200, for: request.url!)
        }
        defer { MockURLProtocol.handler = nil }

        let app = AppModel(store: store)
        let outcome = await app.addAddress(
            "100.64.1.20:8096", to: profile, scheme: .http,
            sessionConfiguration: TestSupport.mockedSessionConfiguration())

        XCTAssertEqual(outcome, .added)
        let stored = try XCTUnwrap(app.store.profiles.first)
        XCTAssertEqual(stored.addresses.map(\.url.absoluteString),
                       ["http://100.64.1.20:8096/emby"],
                       "Emby 候选必须带 /emby 前缀，否则请求全丢前缀")

        // 重复添加同一个入口（用户手写带前缀的版本）应判重，而不是存成第二条。
        let again = await app.addAddress(
            "http://100.64.1.20:8096/emby", to: profile, scheme: .http,
            sessionConfiguration: TestSupport.mockedSessionConfiguration())
        XCTAssertEqual(again, .duplicate)
    }

    /// 探活计数：断言「探活真的发生过」用（固定 sleep 会变成恒真断言）。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - 工具

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
