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
            let server = Self.mockJellyfinServer()
            let context = PlaybackSessionContext(itemID: "item-1")

            await server.reportPlaybackStart(context: context, positionSeconds: 90)
            await server.reportPlaybackProgress(context: context, positionSeconds: 100.5, isPaused: true)
            await server.reportPlaybackStopped(context: context, positionSeconds: 110)
        }

        XCTAssertEqual(requests.items.map(\.0), ["POST", "POST", "POST"])
        XCTAssertEqual(requests.items.map(\.1),
                       ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
    }

    func testReportsCarryPlaybackSessionContext() async throws {
        let bodies = LockedBodies()
        try await TestSupport.withMock { request in
            bodies.append(try XCTUnwrap(TestSupport.body(of: request)))
            return MockURLProtocol.ok("{}", for: request.url!)
        } with: {
            let server = Self.mockJellyfinServer()
            let context = PlaybackSessionContext(
                itemID: "item-1",
                playSessionID: "session-1",
                mediaSourceID: "source-1",
                deliveryMethod: .directStream
            )

            await server.reportPlaybackStart(context: context, positionSeconds: 90)
            await server.reportPlaybackProgress(context: context, positionSeconds: 100.5, isPaused: true)
            await server.reportPlaybackStopped(context: context, positionSeconds: 110)
        }

        XCTAssertEqual(bodies.items.count, 3)
        let jsonBodies = try bodies.items.map { data in
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for body in jsonBodies {
            XCTAssertEqual(body["ItemId"] as? String, "item-1")
            XCTAssertEqual(body["MediaSourceId"] as? String, "source-1")
            XCTAssertEqual(body["PlaySessionId"] as? String, "session-1")
        }
        for body in jsonBodies.prefix(2) {
            XCTAssertEqual(body["PlayMethod"] as? String, "DirectStream")
        }
    }

    func testTicksConversion() {
        XCTAssertEqual(JellyfinServer.ticks(1.0), 10_000_000)
        XCTAssertEqual(JellyfinServer.ticks(92.5), 925_000_000)
        XCTAssertEqual(JellyfinServer.ticks(0), 0)
        // 两家共用同一套 tick 口径（1 tick = 100 ns）。
        XCTAssertEqual(EmbyServer.ticks(92.5), 925_000_000)
    }

    func testReportFailureIsSilentlyIgnored() async throws {
        // 断网 / 服务器挂了：上报抛错也不能炸播放流程
        try await TestSupport.withMock { _ in
            throw URLError(.notConnectedToInternet)
        } with: {
            let context = PlaybackSessionContext(itemID: "x")
            await Self.mockJellyfinServer().reportPlaybackProgress(
                context: context, positionSeconds: 1, isPaused: false)
            await Self.mockEmbyServer().reportPlaybackProgress(
                context: context, positionSeconds: 1, isPaused: false)
            // 走到这就是没炸
        }
    }

    // MARK: - Emby 缺 PlaySessionId 必 400：回退直连时合成会话 id

    func testEmbyFallbackReportsSynthesizePlaySessionID() async throws {
        // 回退直连（PlaybackInfo 失败 → 裸 URL 播放）的 context 没有
        // playSessionID；Emby 的 Playing/Progress 缺它必 400、续播位置全丢。
        let bodies = LockedBodies()
        let paths = LockedRequests()
        try await TestSupport.withMock { request in
            bodies.append(try XCTUnwrap(TestSupport.body(of: request)))
            paths.append((request.httpMethod ?? "?", request.url?.path ?? "?"))
            return MockURLProtocol.ok("{}", for: request.url!)
        } with: {
            let server = Self.mockEmbyServer()
            let context = PlaybackSessionContext(itemID: "item-9")

            await server.reportPlaybackStart(context: context, positionSeconds: 1)
            await server.reportPlaybackProgress(context: context, positionSeconds: 2, isPaused: false)
            await server.reportPlaybackStopped(context: context, positionSeconds: 3)
        }

        let jsonBodies = try bodies.items.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(jsonBodies.count, 3)
        // 确定性 id：同一 item 三段上报落在服务端同一会话行。SessionId 只在
        // Start / Progress 上与 PlaySessionId 同值填入（Swiftfin 同款）；
        // Stopped 只带 PlaySessionId。
        for (index, body) in jsonBodies.enumerated() {
            let where_ = paths.items[index].1
            XCTAssertEqual(body["PlaySessionId"] as? String, "ocplayer-item-9", where_)
            if index < 2 {
                XCTAssertEqual(body["SessionId"] as? String, "ocplayer-item-9", where_)
            } else {
                XCTAssertNil(body["SessionId"], where_)
            }
        }
    }

    func testJellyfinFallbackReportsOmitPlaySessionID() async throws {
        // Jellyfin 三个端点都接受缺失；Emby 才合成，Jellyfin 行为一字不动。
        let bodies = LockedBodies()
        try await TestSupport.withMock { request in
            bodies.append(try XCTUnwrap(TestSupport.body(of: request)))
            return MockURLProtocol.ok("{}", for: request.url!)
        } with: {
            let server = Self.mockJellyfinServer()
            let context = PlaybackSessionContext(itemID: "item-9")

            await server.reportPlaybackStart(context: context, positionSeconds: 1)
            await server.reportPlaybackProgress(context: context, positionSeconds: 2, isPaused: false)
            await server.reportPlaybackStopped(context: context, positionSeconds: 3)
        }

        let jsonBodies = try bodies.items.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        for body in jsonBodies {
            XCTAssertNil(body["PlaySessionId"], "SDK encodeIfPresent：没协商过就整键省略")
            XCTAssertNil(body["SessionId"])
        }
    }

    func testEmbyNegotiatedSessionPassesThroughUnchanged() async throws {
        // 主路径（PlaybackInfo 成功）：协商会话原样透传，绝不被合成值覆盖。
        let bodies = LockedBodies()
        try await TestSupport.withMock { request in
            bodies.append(try XCTUnwrap(TestSupport.body(of: request)))
            return MockURLProtocol.ok("{}", for: request.url!)
        } with: {
            let server = Self.mockEmbyServer()
            let context = PlaybackSessionContext(itemID: "item-9", playSessionID: "negotiated-1")

            await server.reportPlaybackStart(context: context, positionSeconds: 1)
        }

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies.items[0]) as? [String: Any])
        XCTAssertEqual(body["PlaySessionId"] as? String, "negotiated-1")
    }

    func testSynthesizedSessionIDIsDeterministic() {
        let server = Self.mockEmbyServer()
        let context = PlaybackSessionContext(itemID: "item-9")
        XCTAssertEqual(server.resolvedPlaySessionID(context),
                       server.resolvedPlaySessionID(context))
        // 不同 item 不同 id，避免服务端会话互相串。
        XCTAssertNotEqual(server.resolvedPlaySessionID(context),
                          server.resolvedPlaySessionID(PlaybackSessionContext(itemID: "item-10")))
        // 协商过的值优先，且不经手合成格式。
        XCTAssertEqual(server.resolvedPlaySessionID(
            PlaybackSessionContext(itemID: "item-9", playSessionID: "abc")), "abc")
    }

    private static func profile(kind: ServerKind) -> ServerProfile {
        let path = kind == .emby ? "/emby" : ""
        return ServerProfile(
            id: "srv:user",
            serverName: "nas",
            baseURL: URL(string: "http://nas.local:8096\(path)")!,
            userID: "user",
            userName: nil,
            serverVersion: nil,
            kind: kind
        )
    }

    private static func mockJellyfinServer() -> JellyfinServer {
        let profile = profile(kind: .jellyfin)
        return JellyfinServer(
            profile: profile,
            client: JellyfinServer.makeClient(
                baseURL: profile.baseURL,
                token: "tok",
                sessionConfiguration: TestSupport.mockedSessionConfiguration()
            )
        )
    }

    private static func mockEmbyServer() -> EmbyServer {
        let profile = profile(kind: .emby)
        return EmbyServer(
            profile: profile,
            session: EmbySession(
                baseURL: profile.baseURL,
                accessToken: "tok",
                profileID: profile.id,
                sessionConfiguration: TestSupport.mockedSessionConfiguration()
            )
        )
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

private final class LockedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [Data] = []

    func append(_ item: Data) {
        lock.withLock { items.append(item) }
    }
}
