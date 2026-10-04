import DiagnosticsKit
import XCTest
@testable import JellyfinKit

/// 一台服务器两条地址（局域网 + Tailscale）时的**请求级换址**：
/// 某条地址上的请求在传输层失败 → 重新探活 → 换到另一条地址立刻重试一次。
///
/// 这是「出门那一刻 App 不该卡住」的落地：探活给的结论可能已经过期
/// （人刚离开家，局域网那条还没被重新探测过），真正的判据是**请求失败**。
final class ServerAddressFailoverTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []
        func record(_ host: String) { lock.withLock { hosts.append(host) } }
        var all: [String] { lock.withLock { hosts } }
    }

    private let lan = URL(string: "http://192.168.5.107:8096")!
    private let tailscale = URL(string: "http://100.64.1.20:8096")!

    private func makeStore() -> ServerStore {
        let suiteName = "AddressFailoverTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ServerStore(defaults: defaults, tokens: InMemoryTokenStore())
    }

    private func profile(baseURL: URL, kind: ServerKind) -> ServerProfile {
        ServerProfile(
            id: "srv-1:u1", serverName: "home-nas", baseURL: baseURL, userID: "u1",
            userName: "jumusu", serverVersion: kind == .emby ? "4.8.0.42" : "10.9.11",
            kind: kind,
            addresses: [ServerAddress(url: kind == .emby
                                      ? URL(string: "http://100.64.1.20:8096/emby")!
                                      : URL(string: "http://100.64.1.20:8096")!)],
            serverID: "srv-1")
    }

    /// 探活脚本：局域网那条只在**第一次**探活时报可达（首轮决议因此选它），
    /// 之后报不可达 —— 等价于「结论是刚才在家里探出来的，人已经出门」。
    private func installExpiringProbe(on store: ServerStore, lanHost: String = "192.168.5.107") -> Counter {
        let lanProbes = Counter()
        store.probeTimeout = 0.2
        store.probeOverride = { url in
            if url.host == lanHost {
                guard lanProbes.next() == 1 else { return nil }
                return ServerProbeResult(url: url, latency: 0.005, serverID: "srv-1")
            }
            return ServerProbeResult(url: url, latency: 0.05, serverID: "srv-1")
        }
        return lanProbes
    }

    // MARK: - Jellyfin

    func testJellyfinRequestFailsOverToReachableAlternate() async throws {
        let store = makeStore()
        let profile = profile(baseURL: lan, kind: .jellyfin)
        store.activate(profile, token: "tok-1")
        _ = installExpiringProbe(on: store)

        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        let hosts = Recorder()
        try await TestSupport.withMock { request in
            hosts.record(request.url?.host ?? "?")
            if request.url?.host == "192.168.5.107" {
                throw URLError(.cannotConnectToHost)
            }
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"lib-1","Name":"电影","CollectionType":"movies"}],"TotalRecordCount":1}"#,
                for: request.url!)
        } with: {
            let libraries = try await server.userViews()
            XCTAssertEqual(libraries.map(\.id), ["lib-1"], "换址后这次请求必须成功")
        }

        XCTAssertEqual(hosts.all, ["192.168.5.107", "100.64.1.20"],
                       "先在原地址上试、失败后立刻在新地址上重试一次")
        XCTAssertEqual(store.endpointDirectory(for: profile).currentURL, tailscale,
                       "决议器要记住换过的地址（写回档案由 App 层在主线程做）")
    }

    /// HTTP 状态码不是「地址不通」：服务器已经答了话，换地址只会把同一个错误再撞一遍。
    func testJellyfinDoesNotSwitchAddressOnServerError() async throws {
        let store = makeStore()
        let profile = profile(baseURL: lan, kind: .jellyfin)
        store.activate(profile, token: "tok-1")
        store.probeTimeout = 0.2
        store.probeOverride = { url in
            ServerProbeResult(url: url, latency: url.host == "192.168.5.107" ? 0.005 : 0.05,
                              serverID: "srv-1")
        }
        let savedPolicy = JellyfinServer.browseRetryPolicy
        JellyfinServer.browseRetryPolicy = RetryPolicy(attempts: 2, base: 0.001, jitter: 0.001...0.002)
        defer { JellyfinServer.browseRetryPolicy = savedPolicy }

        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        let hosts = Recorder()
        try await TestSupport.withMock { request in
            hosts.record(request.url?.host ?? "?")
            let response = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        } with: {
            do {
                _ = try await server.userViews()
                XCTFail("503 不该被当成成功")
            } catch {
                // 预期：重试预算用完后抛错
            }
        }

        XCTAssertEqual(Set(hosts.all), ["192.168.5.107"], "5xx 是服务器答了话，不该换地址")
    }

    /// 回归：主机名候选在那条网络里**解析不了**（`-1003 cannotFindHost`）也必须换址。
    ///
    /// `.serverUnreachable` 混着两类底层原因：「解析得到但连不上」（-1004，可重试）
    /// 与「名字解析不了」（-1003/-1006，`isRetryable` 为 false）。此前换址判断排在
    /// 重试闸门之后，后者会被 `break` 一起吃掉：一次请求只发一次、不换址、不重试，
    /// 且决议器仍认为旧结论新鲜 → 后续请求继续撞同一条死地址，最长拖到缓存过期。
    /// 而「出门」场景里的局域网候选常常正是 MagicDNS 名 / `nas.local`。
    func testJellyfinFailsOverWhenCandidateHostnameDoesNotResolve() async throws {
        let store = makeStore()
        // 局域网那条用主机名形态（DNS 解析失败），Tailscale 那条用 IP。
        let lanHost = URL(string: "http://nas.local:8096")!
        let profile = ServerProfile(
            id: "srv-1:u1", serverName: "home-nas", baseURL: lanHost, userID: "u1",
            addresses: [ServerAddress(url: tailscale)], serverID: "srv-1")
        store.activate(profile, token: "tok-1")
        _ = installExpiringProbe(on: store, lanHost: "nas.local")

        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        let hosts = Recorder()
        try await TestSupport.withMock { request in
            hosts.record(request.url?.host ?? "?")
            if request.url?.host == "nas.local" {
                // -1003：名字解析不了。`isRetryable` 判它不可重试。
                throw URLError(.cannotFindHost)
            }
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"lib-1","Name":"电影","CollectionType":"movies"}],"TotalRecordCount":1}"#,
                for: request.url!)
        } with: {
            let libraries = try await server.userViews()
            XCTAssertEqual(libraries.map(\.id), ["lib-1"], "解析失败也要换到能用的那条地址")
        }

        XCTAssertEqual(hosts.all, ["nas.local", "100.64.1.20"])
    }

    // MARK: - Emby

    func testEmbyRequestFailsOverToReachableAlternate() async throws {
        let store = makeStore()
        let profile = profile(baseURL: URL(string: "http://192.168.5.107:8096/emby")!, kind: .emby)
        store.activate(profile, token: "tok-1")
        _ = installExpiringProbe(on: store)

        let server = try XCTUnwrap(EmbyServer.resume(
            profile: profile, from: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        let hosts = Recorder()
        try await TestSupport.withMock { request in
            hosts.record(request.url?.host ?? "?")
            if request.url?.host == "192.168.5.107" {
                throw URLError(.cannotConnectToHost)
            }
            XCTAssertEqual(request.url?.path, "/emby/Users/u1/Views")
            return MockURLProtocol.ok(
                #"{"Items":[{"Id":"lib-1","Name":"电影","CollectionType":"movies"}]}"#,
                for: request.url!)
        } with: {
            let libraries = try await server.userViews()
            XCTAssertEqual(libraries.map(\.id), ["lib-1"])
        }

        XCTAssertEqual(hosts.all, ["192.168.5.107", "100.64.1.20"])
    }

    // MARK: - 没有备选可换时

    func testFallsBackToPlainRetryWhenNoAlternateIsReachable() async throws {
        let store = makeStore()
        let profile = profile(baseURL: lan, kind: .jellyfin)
        store.activate(profile, token: "tok-1")
        store.probeTimeout = 0.2
        // 两条都不可达：换址无从谈起，只能如实报错（且不许把原地址弄丢）。
        store.probeOverride = { _ in nil }
        let savedPolicy = JellyfinServer.browseRetryPolicy
        JellyfinServer.browseRetryPolicy = RetryPolicy(attempts: 2, base: 0.001, jitter: 0.001...0.002)
        defer { JellyfinServer.browseRetryPolicy = savedPolicy }

        let server = try XCTUnwrap(JellyfinServer.resume(
            profile: profile, from: store,
            sessionConfiguration: TestSupport.mockedSessionConfiguration()))

        let hosts = Recorder()
        try await TestSupport.withMock { request in
            hosts.record(request.url?.host ?? "?")
            throw URLError(.cannotConnectToHost)
        } with: {
            do {
                _ = try await server.userViews()
                XCTFail("两条地址都不通时必须抛错")
            } catch {
            }
        }

        XCTAssertEqual(Set(hosts.all), ["192.168.5.107"])
        XCTAssertEqual(store.profiles[0].baseURL, lan, "换不动就保持原地址")
    }
}
