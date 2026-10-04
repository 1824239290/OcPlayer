import XCTest
@testable import JellyfinKit

/// `/System/Info/Public` 探活：路径拼装、服务器 ID 校验、可达性判定。
final class ServerProbeTests: XCTestCase {

    private func probe() -> ServerProbe {
        ServerProbe(timeout: 2, sessionConfiguration: TestSupport.mockedSessionConfiguration())
    }

    func testProbeReadsPublicInfo() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/System/Info/Public")
            XCTAssertEqual(request.httpMethod, "GET")
            return MockURLProtocol.ok(
                """
                {"Id":"srv-1","ServerName":"home-nas","Version":"10.9.11",
                 "ProductName":"Jellyfin Server"}
                """,
                for: request.url!)
        } with: {
            let result = await probe().probe(url: URL(string: "http://nas.local:8096")!)
            XCTAssertEqual(result?.serverID, "srv-1")
            XCTAssertEqual(result?.serverName, "home-nas")
            XCTAssertEqual(result?.productName, "Jellyfin Server")
            XCTAssertEqual(result?.version, "10.9.11")
            XCTAssertGreaterThanOrEqual(result?.latency ?? -1, 0)
        }
    }

    func testProbeKeepsEmbyPathPrefix() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/emby/System/Info/Public")
            return MockURLProtocol.ok(#"{"Id":"emby-1","ProductName":"Emby Server"}"#, for: request.url!)
        } with: {
            let result = await probe().probe(url: URL(string: "http://nas.local:8096/emby")!)
            XCTAssertEqual(result?.serverID, "emby-1")
        }
    }

    func testProbeRejectsAnotherServersID() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"Id":"someone-else","ServerName":"other"}"#, for: request.url!)
        } with: {
            let result = await probe().probe(
                url: URL(string: "http://100.64.1.20:8096")!, expectedServerID: "srv-1")
            XCTAssertNil(result, "地址能通但不是同一台服务器时不能算可用")
        }
    }

    func testProbePassesWhenServerDoesNotReportID() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"ServerName":"home-nas"}"#, for: request.url!)
        } with: {
            let result = await probe().probe(
                url: URL(string: "http://nas.local:8096")!, expectedServerID: "srv-1")
            XCTAssertNotNil(result, "服务器没报 Id 时不能因为它缺失就把地址判死")
        }
    }

    /// 回归：200 + **不是**媒体服务器的响应体必须判不可达。
    ///
    /// 反代的 SPA fallback（`try_files … /index.html`）、NAS 管理页、任意静态服务器
    /// 都会回 200 加一段 HTML。此前解码失败被 `try?` 吞掉、`Id` 校验又因为拿不到
    /// `Id` 而被跳过，这类地址会被判「可达」：它通常比真服务器更快，于是被选为当前
    /// 地址，而探活永远成功（粘性不切走）、API 请求全部解不出来 —— 卡在错地址上
    /// 只能用户手动处理。登录路径本来是严格解码的，两处口径必须一致。
    func testProbeRejectsOKResponseThatIsNotAMediaServer() async throws {
        for body in ["<html><body>Welcome to nginx</body></html>", "{}", #"{"foo":"bar"}"#] {
            try await TestSupport.withMock { request in
                MockURLProtocol.ok(body, for: request.url!)
            } with: {
                let result = await probe().probe(url: URL(string: "http://192.0.2.10:8096")!)
                XCTAssertNil(result, "「\(body)」不是 Jellyfin / Emby 的 /System/Info/Public")
            }
        }
    }

    func testProbeTreatsHTTPErrorAsUnreachable() async throws {
        try await TestSupport.withMock { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        } with: {
            let result = await probe().probe(url: URL(string: "http://nas.local:8096")!)
            XCTAssertNil(result)
        }
    }

    func testProbeSendsAuthorizationHeaderWhenProvided() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "MediaBrowser Token=\"tok\"")
            return MockURLProtocol.ok(#"{"Id":"srv-1"}"#, for: request.url!)
        } with: {
            _ = await probe().probe(url: URL(string: "http://nas.local:8096")!,
                                    authorizationHeader: "MediaBrowser Token=\"tok\"")
        }
    }

    // MARK: - 给 UI 用的组合口

    func testCheckReportsDifferentServerInsteadOfUnreachable() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"Id":"someone-else"}"#, for: request.url!)
        } with: {
            let check = await ServerProbe.check(
                url: URL(string: "http://100.64.1.20:8096")!,
                expectedServerID: "srv-1",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            guard case .differentServer(let serverID) = check else {
                return XCTFail("应报「另一台服务器」，实际是 \(check)")
            }
            XCTAssertEqual(serverID, "someone-else")
        }
    }

    func testCheckReportsReachableForSameServer() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"Id":"srv-1","ServerName":"home-nas"}"#, for: request.url!)
        } with: {
            let check = await ServerProbe.check(
                url: URL(string: "http://100.64.1.20:8096")!,
                expectedServerID: "srv-1",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            guard case .reachable(let result) = check else {
                return XCTFail("应报可达，实际是 \(check)")
            }
            XCTAssertEqual(result.serverID, "srv-1")
        }
    }

    /// 「档案里的 baseURL 是家里那条，人已经出门」：并发探活要挑出唯一可达的那条。
    func testFirstReachableSkipsUnreachableAddresses() async throws {
        let lan = URL(string: "http://192.168.5.107:8096")!
        let tailscale = URL(string: "http://100.64.1.20:8096")!

        try await TestSupport.withMock { request in
            if request.url?.host == "192.168.5.107" {
                throw URLError(.cannotConnectToHost)
            }
            return MockURLProtocol.ok(#"{"Id":"srv-1"}"#, for: request.url!)
        } with: {
            let reachable = await ServerProbe.firstReachable(
                of: [lan, tailscale],
                expectedServerID: "srv-1",
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertEqual(reachable?.url, tailscale)
        }
    }

    func testFirstReachableReturnsNilWhenNothingAnswers() async throws {
        let lan = URL(string: "http://192.168.5.107:8096")!
        try await TestSupport.withMock { request in
            throw URLError(.cannotConnectToHost)
        } with: {
            let reachable = await ServerProbe.firstReachable(
                of: [lan],
                sessionConfiguration: TestSupport.mockedSessionConfiguration())
            XCTAssertNil(reachable)
        }
    }
}
