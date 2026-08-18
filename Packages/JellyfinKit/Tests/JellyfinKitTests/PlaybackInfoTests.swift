import XCTest
@testable import JellyfinKit

/// PlaybackInfo / DeviceProfile / MediaSource 选择的离线测试。
final class PlaybackInfoTests: XCTestCase {

    func testPlaybackInfoPostsDeviceProfileAndMapsMediaSources() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/Items/item-1/PlaybackInfo")
            XCTAssertEqual(TestSupport.queryItems(of: request)["userId"], "user")

            let body = try XCTUnwrap(TestSupport.body(of: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["EnableDirectPlay"] as? Bool, true)
            XCTAssertEqual(json["EnableDirectStream"] as? Bool, true)
            XCTAssertEqual(json["EnableTranscoding"] as? Bool, false)

            let profile = try XCTUnwrap(json["DeviceProfile"] as? [String: Any])
            XCTAssertEqual(profile["Name"] as? String, "OcPlayer")

            return MockURLProtocol.ok(
                """
                {
                  "MediaSources": [
                    {
                      "Id": "ms-1",
                      "Name": "Episode 01",
                      "Path": "/media/show/episode-01.mkv",
                      "Size": 123456789,
                      "Container": "mkv",
                      "SupportsDirectPlay": true,
                      "Bitrate": 8000000,
                      "RunTimeTicks": 1200000000
                    }
                  ],
                  "PlaySessionId": "ps-1"
                }
                """,
                for: request.url!
            )
        } with: {
            let info = try await Self.mockServer().playbackInfo(itemID: "item-1")
            XCTAssertEqual(info.playSessionID, "ps-1")
            XCTAssertEqual(info.mediaSources.count, 1)

            let source = try XCTUnwrap(info.mediaSources.first)
            XCTAssertEqual(source.id, "ms-1")
            XCTAssertEqual(source.name, "Episode 01")
            XCTAssertEqual(source.path, "/media/show/episode-01.mkv")
            XCTAssertEqual(source.size, 123456789)
            XCTAssertEqual(source.container, "mkv")
            XCTAssertEqual(source.supportsDirectPlay, true)
            XCTAssertEqual(try XCTUnwrap(source.runTimeSeconds), 120, accuracy: 0.001)

            let context = info.sessionContext(itemID: "item-1", selectedSource: source)
            XCTAssertEqual(context.itemID, "item-1")
            XCTAssertEqual(context.playSessionID, "ps-1")
            XCTAssertEqual(context.mediaSourceID, "ms-1")
            XCTAssertEqual(context.mediaSourceName, "Episode 01")
            XCTAssertEqual(context.mediaSourcePath, "/media/show/episode-01.mkv")
            XCTAssertEqual(context.mediaSourceSize, 123456789)
            XCTAssertEqual(try XCTUnwrap(context.durationSeconds), 120, accuracy: 0.001)
            XCTAssertEqual(context.deliveryMethod, .directPlay)
        }
    }

    func testSessionContextUsesSelectedSourceDeliveryMethod() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(
                #"{"MediaSources":[{"Id":"ms-2","SupportsDirectPlay":false,"SupportsDirectStream":true}]}"#,
                for: request.url!
            )
        } with: {
            let info = try await Self.mockServer().playbackInfo(itemID: "item-2")
            let source = try XCTUnwrap(info.mediaSources.first)
            XCTAssertEqual(
                info.sessionContext(itemID: "item-2", selectedSource: source).deliveryMethod,
                .directStream
            )
        }
    }

    func testStreamURLIncludesPlaybackSessionAndMediaSourceWithoutToken() throws {
        let url = try Self.mockServer().streamURL(
            itemID: "item-1",
            mediaSourceID: "ms 1",
            playSessionID: "ps 1"
        )
        XCTAssertTrue(url.contains("/Videos/item-1/stream?Static=true"))
        let components = try XCTUnwrap(URLComponents(string: url))
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(query["mediaSourceId"], "ms 1")
        XCTAssertEqual(query["playSessionId"], "ps 1")
        XCTAssertFalse(url.contains("tok"), "token 绝不能进 URL")
    }

    func testPlaybackInfoFallbackIDWhenSourceMissingID() async throws {
        try await TestSupport.withMock { request in
            return MockURLProtocol.ok(
                #"{"MediaSources":[{"Container":"mp4"}]}"#,
                for: request.url!
            )
        } with: {
            let info = try await Self.mockServer().playbackInfo(itemID: "item-9")
            XCTAssertEqual(info.mediaSources.first?.id, "item-9")
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
