import XCTest
@testable import JellyfinKit

/// 地址决议器：探活择优、粘性、失败切换、固定模式、缓存与失效。
///
/// 全部用**注入的探活**（`ServerProbe.inject`）而不是 mock URLProtocol：这里要
/// 验证的是「拿到一组可达性 / 延迟之后怎么选」，构造确定性延迟比让 URLProtocol
/// 真去 sleep 靠谱得多。真实探活链路（HTTP + 服务器 ID 校验）另有
/// `ServerProbeTests` 覆盖。
final class ServerEndpointDirectoryTests: XCTestCase {

    private let lan = URL(string: "http://192.168.5.107:8096")!
    private let tailscale = URL(string: "http://100.64.1.20:8096")!

    /// 线程安全的收集盒：决议器的变更回调是 `@Sendable`，捕获并修改局部 var
    /// 在 Swift 6 下不合法。
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URL] = []
        func append(_ url: URL) { lock.withLock { items.append(url) } }
        var all: [URL] { lock.withLock { items } }
    }

    /// 探活脚本：给定「哪个地址可达、延迟多少」，并记录调用次数。
    private final class ProbeScript: @unchecked Sendable {
        private let lock = NSLock()
        private var reachable: [String: TimeInterval]
        private(set) var calls: [String] = []
        /// 每个地址的探活耗时（默认 0）：制造「在飞」窗口用。
        var probeDelay: TimeInterval = 0

        init(reachable: [String: TimeInterval]) {
            self.reachable = reachable
        }

        func setReachable(_ urls: [URL], latency: TimeInterval = 0.01) {
            lock.withLock {
                reachable = Dictionary(uniqueKeysWithValues: urls.map { ($0.absoluteString, latency) })
            }
        }

        func probe(_ url: URL) async -> ServerProbeResult? {
            if probeDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(probeDelay * 1_000_000_000))
            }
            return lock.withLock {
                calls.append(url.absoluteString)
                guard let latency = reachable[url.absoluteString] else { return nil }
                return ServerProbeResult(url: url, latency: latency, serverID: "srv-1")
            }
        }

        var callCount: Int { lock.withLock { calls.count } }
        func calls(for url: URL) -> Int { lock.withLock { calls.filter { $0 == url.absoluteString }.count } }
    }

    private func makeDirectory(
        baseURL: URL,
        alternates: [URL] = [],
        pinned: URL? = nil,
        script: ProbeScript
    ) -> ServerEndpointDirectory {
        let profile = ServerProfile(
            id: "srv-1:user-1",
            serverName: "home-nas",
            baseURL: baseURL,
            userID: "user-1",
            addresses: alternates.map { ServerAddress(url: $0) },
            pinnedURL: pinned,
            serverID: "srv-1")
        let probe = ServerProbe(
            timeout: 0.2,
            sessionConfiguration: .ephemeral,
            inject: { url in await script.probe(url) })
        return ServerEndpointDirectory(profile: profile, probe: probe)
    }

    // MARK: - 择优

    func testPicksClearlyFasterAddressOverPersistedOne() async {
        // 档案里存的是 Tailscale（上次出门用的），但现在是局域网明显更快 → 切。
        let script = ProbeScript(reachable: [lan.absoluteString: 0.004,
                                             tailscale.absoluteString: 0.060])
        let directory = makeDirectory(baseURL: tailscale, alternates: [lan], script: script)

        let changes = Box()
        directory.setChangeHandler { changes.append($0) }

        let resolved = await directory.resolvedURL()
        XCTAssertEqual(resolved, lan, "局域网 4ms 明显快于 Tailscale 60ms，应该切过去")
        XCTAssertEqual(directory.currentURL, lan)
        XCTAssertEqual(changes.all, [lan], "地址变了要通知一次")
    }

    func testKeepsCurrentAddressWhenNotClearlyFaster() async {
        // 两条都通且延迟接近：不许来回抖。
        let script = ProbeScript(reachable: [lan.absoluteString: 0.004,
                                             tailscale.absoluteString: 0.005])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        let changes = Box()
        directory.setChangeHandler { changes.append($0) }

        let resolved = await directory.resolvedURL()
        XCTAssertEqual(resolved, lan, "延迟只差 1ms 不值得换地址")
        XCTAssertTrue(changes.all.isEmpty, "没换地址就不该通知")
    }

    func testSwitchesWhenCurrentAddressBecomesUnreachable() async {
        // 出门：局域网探不到，Tailscale 通 —— 这是这套机制最常见的现场。
        let script = ProbeScript(reachable: [tailscale.absoluteString: 0.05])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)

        let resolved = await directory.resolvedURL()
        XCTAssertEqual(resolved, tailscale)
    }

    // MARK: - 失败开放

    func testKeepsAddressWhenNothingIsReachable() async {
        let script = ProbeScript(reachable: [:])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)

        let resolved = await directory.resolvedURL()
        XCTAssertEqual(resolved, lan, "一个地址都探不通时保持原地址，不能把「探活失败」变成「连不上」")
    }

    func testRepeatedRequestsDoNotReProbeWhileNothingIsReachable() async {
        let script = ProbeScript(reachable: [:])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        directory.unreachableRetryInterval = 60

        _ = await directory.resolvedURL()
        let afterFirst = script.callCount
        _ = await directory.resolvedURL()
        _ = await directory.resolvedURL()
        XCTAssertEqual(script.callCount, afterFirst,
                       "服务器整个下线时，后续请求不该每次都先等一轮探活")
    }

    // MARK: - 缓存 / 失效

    func testFreshResolutionIsCachedUntilInvalidated() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.01])
        let directory = makeDirectory(baseURL: lan, script: script)
        directory.cacheTTL = 600

        _ = await directory.resolvedURL()
        let afterFirst = script.callCount
        _ = await directory.resolvedURL()
        _ = await directory.resolvedURL()
        XCTAssertEqual(script.callCount, afterFirst, "缓存有效期内不重复探活")

        directory.invalidate()
        _ = await directory.resolvedURL()
        XCTAssertGreaterThan(script.callCount, afterFirst, "失效后下一次请求要重新探活")
    }

    func testRefreshForcesProbe() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.01])
        let directory = makeDirectory(baseURL: lan, script: script)
        directory.cacheTTL = 600

        _ = await directory.resolvedURL()
        let afterFirst = script.callCount
        _ = await directory.refresh()
        XCTAssertGreaterThan(script.callCount, afterFirst)
    }

    /// 回归：`invalidate()` 必须作废**在飞**的那轮探活。
    ///
    /// 只置标志的话，在飞任务回来时仍会照常写 `resolvedAt`，把刚作废的结论重新标成
    /// 「新鲜」——于是「网络换了」被丢掉，最长再等一个缓存周期（300s）才自愈；
    /// 而且 `resolvedURL()` 还会 await 那个已成废案的任务，拿回一个旧地址。
    func testInvalidateDiscardsInFlightResolution() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.004])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        script.probeDelay = 0.15

        // 第一轮决议在飞：此刻只有局域网可达。
        let inFlight = Task { await directory.resolvedURL() }
        try? await Task.sleep(nanoseconds: 30_000_000)

        // 网络换了（出门）：作废结论，并且只有 Tailscale 可达了。
        script.setReachable([tailscale], latency: 0.05)
        directory.invalidate()

        let resolved = await directory.resolvedURL()
        _ = await inFlight.value

        XCTAssertEqual(resolved, tailscale, "作废后必须重新探活并采纳新结论")
        XCTAssertEqual(directory.currentURL, tailscale,
                       "在飞的旧结论不许把 currentURL 写回局域网")
    }

    // MARK: - 固定地址

    func testPinnedAddressIgnoresFasterAlternateAndOtherCandidates() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.001,
                                             tailscale.absoluteString: 0.080])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale],
                                      pinned: tailscale, script: script)

        let resolved = await directory.resolvedURL()
        XCTAssertEqual(resolved, tailscale, "固定了就只用固定的那条")
        XCTAssertEqual(script.calls(for: lan), 0, "固定模式下不该去探其它候选")
        XCTAssertTrue(directory.isPinned)
    }

    func testPinnedAddressNeverFailsOver() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.005])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale],
                                      pinned: tailscale, script: script)

        // 固定地址探不到：保持固定（让请求如实报错），不偷偷换线路。
        _ = await directory.resolvedURL()
        XCTAssertEqual(directory.currentURL, tailscale)

        let switched = await directory.reportFailure(of: tailscale)
        XCTAssertFalse(switched, "固定地址不该被自动换掉")
        XCTAssertEqual(directory.currentURL, tailscale)
    }

    // MARK: - 失败重决议

    func testReportFailureSwitchesToReachableAlternate() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.005,
                                             tailscale.absoluteString: 0.05])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        _ = await directory.resolvedURL()
        XCTAssertEqual(directory.currentURL, lan)

        // 局域网这条实际请求失败了（探活还在按老结论说它通，这里改成只有 Tailscale 通）。
        script.setReachable([tailscale], latency: 0.05)
        let switched = await directory.reportFailure(of: lan)
        XCTAssertTrue(switched)
        XCTAssertEqual(directory.currentURL, tailscale)
    }

    func testReportFailureReturnsFalseWhenNothingChanges() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.005])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        _ = await directory.resolvedURL()

        let switched = await directory.reportFailure(of: lan)
        XCTAssertFalse(switched, "只有一条通的时候换址无从谈起，调用方应走原来的退避重试")
    }

    func testConcurrentFailuresRespectCooldown() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.005,
                                             tailscale.absoluteString: 0.05])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        directory.failureCooldown = 60
        _ = await directory.resolvedURL()
        // 局域网这条真的断了（探活也随之为它改口），否则「换地址」本就无从谈起。
        script.setReachable([tailscale], latency: 0.05)

        let first = await directory.reportFailure(of: lan)
        let second = await directory.reportFailure(of: lan)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "冷却期内一串并发失败只触发一次重决议")
    }

    // MARK: - 展示用探活

    func testProbeAllCandidatesDoesNotChangeActiveAddress() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.020,
                                             tailscale.absoluteString: 0.005])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        _ = await directory.resolvedURL()
        XCTAssertEqual(directory.currentURL, lan)

        let results = await directory.probeAllCandidates()
        XCTAssertEqual(results.map(\.url), [tailscale, lan], "按延迟升序返回全部候选")
        XCTAssertEqual(directory.currentURL, lan, "展示性探活不参与决议，不该顺手换地址")
    }

    // MARK: - 档案同步

    func testSyncingProfileFollowsPinnedAndDroppedAddresses() async {
        let script = ProbeScript(reachable: [lan.absoluteString: 0.005,
                                             tailscale.absoluteString: 0.05])
        let directory = makeDirectory(baseURL: lan, alternates: [tailscale], script: script)
        _ = await directory.resolvedURL()
        XCTAssertEqual(directory.currentURL, lan)

        // 用户把 Tailscale 固定上：立即生效，不必等下一轮探活。
        var profile = ServerProfile(id: "srv-1:user-1", serverName: "home-nas",
                                    baseURL: lan, userID: "user-1",
                                    addresses: [ServerAddress(url: tailscale)],
                                    pinnedURL: tailscale, serverID: "srv-1")
        directory.sync(profile: profile)
        XCTAssertEqual(directory.currentURL, tailscale)
        XCTAssertEqual(directory.candidateCount, 2, "候选里仍保留 baseURL（取消固定后要能回来）")

        // 取消固定 + 当前地址被删：回落到档案里的 baseURL。
        profile.pinnedURL = nil
        directory.sync(profile: profile)
        XCTAssertEqual(directory.currentURL, tailscale, "取消固定不该改变当前地址")

        profile.baseURL = lan
        profile.addresses = []
        directory.sync(profile: profile)
        XCTAssertEqual(directory.currentURL, lan, "当前地址不在候选里时必须回落")
    }
}
