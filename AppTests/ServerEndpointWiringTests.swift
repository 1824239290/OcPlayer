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
        await waitUntil(
            diagnostics: {
                "serverEndpointURL=\(app.serverEndpointURL?.absoluteString ?? "nil") "
                    + "profile.baseURL=\(app.store.profiles.first?.baseURL.absoluteString ?? "nil")"
            }
        ) { app.serverEndpointURL == self.tailscale }

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
        await waitUntil(diagnostics: { "probes.count=\(probes.count)" }) { probes.count >= 2 }

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

        // ⚠️ **必须给 mock 一个 handler**，而且必须等后台探活结束。
        //
        // `attachEndpoints` 末尾是 `Task { await directory.refresh() }` —— 一次
        // **fire-and-forget** 的多地址探活。这条用例原本没设 handler：
        //   - 本机：`MockURLProtocol` 无 handler 时立刻回 `unsupportedURL`，毫秒级；
        //   - CI：那次探活还在飞，而 `defer { MockURLProtocol.handler = nil }`
        //     已经把 handler 清掉（或根本没设，落到真实网络路径），于是每个候选地址
        //     各等一次默认超时 —— 实测 **macOS 35.25 s / iOS 53.44 s**（本机 0.012 s）。
        //
        // 两个后果：① 这条用例本身慢得离谱；② 那个后台任务会**跨用例泄漏**，
        // 拖慢同套件后面的 `testResolvedAddressIsPersistedAndPublished`，让它的
        // 3 s 等待假红（`main` 在 `db23061` 就是这么红的）。
        //
        // 所以在 `defer` 清 handler 之前，先把这个后台探活等到落地。
        let probes = Counter()
        MockURLProtocol.handler = { request in
            probes.increment()
            return TestSupport.response(#"{"Id":"srv-1","ServerName":"home-nas"}"#,
                                        status: 200, for: request.url!)
        }

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

        // 等那次 fire-and-forget 探活落地，避免它跨用例泄漏（见方法开头那段注释）。
        // 判据用「探活确实发生过」而不是固定 sleep —— 固定 sleep 会变成恒真断言。
        await waitUntil(diagnostics: { "probes.count=\(probes.count)" }) { probes.count > 0 }
        MockURLProtocol.handler = nil
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

    /// 轮询等到条件成立；超时 `XCTFail`（带实测状态）后返回。
    ///
    /// **必须显式失败**：静默返回会把「后台探活没在超时内落地」伪装成下游那几条
    /// 完全看不懂的断言 —— CI 实测过一次（runner 被拖慢，上一条用例跑了 35 s），
    /// 报的是 `http://192.0.2.10:8096 ≠ http://100.64.1.20:8096`，看起来像地址决议
    /// 算错了，其实是夹具没等到。写法与 `PlayerHUDGatesTests` / `SkipPreferenceTests`
    /// 等处一致。
    ///
    /// ## ⚠️ 超时取 10 s，不是 3 s
    ///
    /// 3 s 时 `main` 仍红过一次（2026-10-19 的 `db23061`）：诊断信息已经正确打出
    /// 「后台探活/请求计数未在 3.0 seconds 内落地」，说明 `CORR-08` 的**可诊断性**
    /// 修复生效了，但**超时本身太紧** —— 条件是「后台探活走完一次 mock 往返」，
    /// 正常毫秒级，而那次 runner 上一条用例跑了 35 s（整机被拖慢一个量级）。
    ///
    /// 放到 10 s 的代价只有「真失败时多等 7 s」，而这个套件总共只有 8 处等待；
    /// 收益是不再让 runner 抖动变成假红。
    private func waitUntil(
        timeout: Duration = .seconds(10),
        diagnostics: () -> String = { "" },
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let detail = diagnostics()
        XCTFail(
            "等待超时：后台探活/请求计数未在 \(timeout) 内落地"
                + (detail.isEmpty ? "" : "（实测 \(detail)）"),
            file: file, line: line
        )
    }
}
