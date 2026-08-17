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
            XCTAssertEqual(source.container, "mkv")
            XCTAssertEqual(source.supportsDirectPlay, true)
            XCTAssertEqual(try XCTUnwrap(source.runTimeSeconds), 120, accuracy: 0.001)
        }
    }

    func testStreamURLIncludesMediaSourceIDWithoutToken() throws {
        let url = try Self.mockServer().streamURL(itemID: "item-1", mediaSourceID: "ms-1")
        XCTAssertTrue(url.contains("/Videos/item-1/stream?Static=true"))
        XCTAssertTrue(url.contains("mediaSourceId=ms-1"))
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
