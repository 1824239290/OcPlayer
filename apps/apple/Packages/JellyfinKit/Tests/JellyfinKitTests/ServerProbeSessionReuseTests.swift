import Foundation
import XCTest

@testable import JellyfinKit

/// 探活**会话复用**的回归（性能审查清单 `P1-05`）。
///
/// ## 为什么算性能问题
///
/// 改前每次 `probe` 都「copy 配置 → 新建 `URLSession` → `defer invalidateAndCancel`」。
/// 两个代价：
/// 1. 每次都现建会话；
/// 2. `invalidateAndCancel` 让**连接池当场作废** —— 每次探活都重新付 DNS + TCP + TLS。
///
/// 而探活测出的 `latency` 正是「挑最快地址」的判据输入（局域网 / Tailscale / 反代
/// 的握手成本各不相同），所以这不只是慢，是**判据被污染**。
///
/// ## 判据
///
/// `URLProtocol` 的 `startLoading` 里拿不到所属 `URLSession`，但可以数
/// 「同一会话内的请求是否共享连接池」—— 更直接的观测是：**同一 timeout 的两次探活
/// 必须拿到同一个 `URLSession` 实例**。这里把 `URLSession` 的身份用
/// `URLSessionConfiguration` 的观察点换成「请求头里的会话标识」不可行，
/// 所以改用最直白的方式：暴露一个内部计数器，数「新建过几个会话」。
final class ServerProbeSessionReuseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServerProbe.resetSessionCacheForTesting()
        MockURLProtocol.handler = { request in
            MockURLProtocol.ok(#"{"Id":"srv-1","ServerName":"home"}"#, for: request.url!)
        }
    }

    override func tearDown() {
        ServerProbe.resetSessionCacheForTesting()
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// **同一 timeout 的多次探活只建一个会话。**
    ///
    /// 这条直接钉住 `P1-05` 的修法：改前每次都新建 + `invalidateAndCancel`，
    /// 计数器会跟着探活次数涨；改后应恒为 1。
    func testRepeatedProbesWithSameTimeoutShareOneSession() async throws {
        let probe = ServerProbe(
            timeout: 2, sessionConfiguration: TestSupport.mockedSessionConfiguration())
        let url = URL(string: "http://192.0.2.10:8096")!

        ServerProbe.resetSessionCreationCounterForTesting()
        for _ in 0..<5 {
            let result = await probe.probe(url: url)
            XCTAssertNotNil(result, "mock 下每次都应可达")
        }
        XCTAssertEqual(
            ServerProbe.sessionCreationCountForTesting, 1,
            "5 次探活建了 \(ServerProbe.sessionCreationCountForTesting) 个会话 —— "
                + "会话没有复用（P1-05 回归：每次新建 + invalidateAndCancel 会让连接池作废）")
    }

    /// 不同 timeout 各自一档（不能把 2s 的超时复用给 0.5s 那档）。
    func testDifferentTimeoutsGetTheirOwnSession() async throws {
        let url = URL(string: "http://192.0.2.11:8096")!
        let configuration = TestSupport.mockedSessionConfiguration()

        ServerProbe.resetSessionCreationCounterForTesting()
        _ = await ServerProbe(timeout: 2, sessionConfiguration: configuration).probe(url: url)
        _ = await ServerProbe(timeout: 0.5, sessionConfiguration: configuration).probe(url: url)
        _ = await ServerProbe(timeout: 2, sessionConfiguration: configuration).probe(url: url)

        XCTAssertEqual(
            ServerProbe.sessionCreationCountForTesting, 2,
            "应按 timeout 分档：2s 一档、0.5s 一档（2s 的第二次要命中缓存）")
    }

    /// **配置不同就不许共用会话**（审查实测的串台风险）。
    ///
    /// 第一版只按 `timeout` 做键：两个配置分别挂 ProtoA / ProtoB、同 timeout=2
    /// 各探一次 → 第二次拿到第一次的会话，`r1=A r2=A`，第二个配置**完全没生效**。
    /// 而 `sessionConfiguration` 正是测试注入口，AppTests 里不同套件用不同 mock、
    /// timeout 都可能是 2 —— 顺序相关、随机串台。
    func testDifferentConfigurationsDoNotShareSession() async throws {
        let url = URL(string: "http://192.0.2.20:8096")!
        ServerProbe.resetSessionCacheForTesting()
        ServerProbe.resetSessionCreationCounterForTesting()

        ServerAProtocol.serverID = "A"
        ServerBProtocol.serverID = "B"
        let configA = URLSessionConfiguration.ephemeral
        configA.protocolClasses = [ServerAProtocol.self]
        let configB = URLSessionConfiguration.ephemeral
        configB.protocolClasses = [ServerBProtocol.self]

        let a = await ServerProbe(timeout: 2, sessionConfiguration: configA).probe(url: url)
        let b = await ServerProbe(timeout: 2, sessionConfiguration: configB).probe(url: url)

        XCTAssertEqual(a?.serverID, "A")
        XCTAssertEqual(b?.serverID, "B", "第二个配置没生效 —— 会话按 timeout 串台了")
        XCTAssertEqual(ServerProbe.sessionCreationCountForTesting, 2,
                       "不同配置必须各自建会话")
    }

    /// 非法 timeout（NaN / 0 / 负数 / 无穷）必须被夹成有限正数。
    ///
    /// 因为 timeout 是缓存键的一部分：NaN 做键**永不命中**（每次新建、键表无界增长），
    /// 负数 / infinity 会被 URLSession 接受但行为诡异。
    func testNonPositiveOrNonFiniteTimeoutIsClamped() async throws {
        let url = URL(string: "http://192.0.2.21:8096")!
        for bad in [Double.nan, 0, -1, .infinity] {
            ServerProbe.resetSessionCacheForTesting()
            ServerProbe.resetSessionCreationCounterForTesting()
            let probe = ServerProbe(
                timeout: bad, sessionConfiguration: TestSupport.mockedSessionConfiguration())
            _ = await probe.probe(url: url)
            _ = await probe.probe(url: url)
            XCTAssertEqual(
                ServerProbe.sessionCreationCountForTesting, 1,
                "timeout=\(bad) 时缓存键不稳定（NaN 永不命中 / 每次新建）")
        }
    }

    /// 复用会话之后，探活结果仍然正确（延迟有值、serverID 解析出来）。
    ///
    /// 防的是「为了复用而把请求/解码改坏」。
    func testReusedSessionStillProducesCorrectResult() async throws {
        let probe = ServerProbe(
            timeout: 2, sessionConfiguration: TestSupport.mockedSessionConfiguration())
        let url = URL(string: "http://192.0.2.12:8096")!

        for _ in 0..<3 {
            let probed = await probe.probe(url: url)
            let result = try XCTUnwrap(probed)
            XCTAssertEqual(result.serverID, "srv-1")
            XCTAssertEqual(result.serverName, "home")
            XCTAssertGreaterThanOrEqual(result.latency, 0)
        }
    }
}


/// 探活测试用：固定返回带指定 `Id` 的公开信息。
private class ServerAProtocol: URLProtocol {
    nonisolated(unsafe) static var serverID = "A"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data(#"{"Id":"\#(Self.serverID)","ServerName":"home"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ServerBProtocol: URLProtocol {
    nonisolated(unsafe) static var serverID = "B"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data(#"{"Id":"\#(Self.serverID)","ServerName":"home"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
