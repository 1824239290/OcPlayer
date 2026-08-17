import XCTest
@testable import JellyfinKit

/// 进度上报：三个端点的路径、方法（mock 全离线）。
final class PlaybackReportingTests: XCTestCase {

    func testReportStartProgressStopHitRightEndpoints() async {
        let requests = LockedRequests()
        await TestSupport.withMock { request in
            requests.append((request.httpMethod ?? "?", request.url?.path ?? "?"))
            return MockURLProtocol.ok("{}", for: request.url!)
        } with: {
            let server = Self.mockServer()

            await server.reportPlaybackStart(itemID: "item-1", positionSeconds: 90)
            await server.reportPlaybackProgress(itemID: "item-1", positionSeconds: 100.5, isPaused: true)
            await server.reportPlaybackStopped(itemID: "item-1", positionSeconds: 110)
        }

        XCTAssertEqual(requests.items.map(\.0), ["POST", "POST", "POST"])
        XCTAssertEqual(requests.items.map(\.1),
                       ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
    }

    func testTicksConversion() {
        XCTAssertEqual(JellyfinServer.ticks(1.0), 10_000_000)
        XCTAssertEqual(JellyfinServer.ticks(92.5), 925_000_000)
        XCTAssertEqual(JellyfinServer.ticks(0), 0)
    }

    func testReportFailureIsSilentlyIgnored() async throws {
        // 断网 / 服务器挂了：上报抛错也不能炸播放流程
        try await TestSupport.withMock { _ in
            throw URLError(.notConnectedToInternet)
        } with: {
            await Self.mockServer().reportPlaybackProgress(itemID: "x", positionSeconds: 1, isPaused: false)
            // 走到这就是没炸
        }
    }

    private static func mockServer() -> JellyfinServer {
        let profile = ServerProfile(id: "srv:user", serverName: "nas",
                                    baseURL: URL(string: "http://nas.local:8096")!,
                                    userID: "user", userName: nil, serverVersion: nil)
        let client = JellyfinServer.makeClient(baseURL: profile.baseURL, token: "tok",
                                               sessionConfiguration: TestSupport.mockedSessionConfiguration())
        return JellyfinServer(profile: profile, client: client)
    }
}

/// 测试辅助：并发安全的请求记录。
private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [(String, String)] = []

    func append(_ item: (String, String)) {
        lock.withLock { items.append(item) }
    }
}
