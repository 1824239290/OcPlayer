import XCTest
@testable import JellyfinKit

/// 详情页媒体信息：`GET /Items?fields=MediaSources` 的解析、选源与容错。
final class MediaFileInfoTests: XCTestCase {

    func testParsesVideoAudioSubtitleAndFileFields() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items")
            XCTAssertEqual(request.httpMethod, "GET")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["ids"], "ep-1")
            XCTAssertEqual(query["fields"], "MediaSources")
            return MockURLProtocol.ok(
                """
                {
                  "Items": [{
                    "Id": "ep-1", "Name": "第 1 话", "Type": "Episode",
                    "MediaSources": [{
                      "Id": "ms-1",
                      "Container": "mkv",
                      "Size": 12345678900,
                      "RunTimeTicks": 14500000000,
                      "Path": "/media/番剧/Show S01E01.mkv",
                      "SupportsDirectPlay": true,
                      "MediaStreams": [
                        {
                          "Index": 0, "Type": "Video", "Codec": "hevc",
                          "Width": 3840, "Height": 2160,
                          "BitRate": 24500000, "BitDepth": 10,
                          "AverageFrameRate": 23.976,
                          "ColorPrimaries": "bt2020", "ColorTransfer": "smpte2084",
                          "ColorSpace": "bt2020nc", "ColorRange": "tv",
                          "VideoRangeType": "DOVIWithHDR10", "Profile": "Main 10"
                        },
                        {
                          "Index": 1, "Type": "Audio", "Codec": "truehd",
                          "Channels": 8, "ChannelLayout": "7.1",
                          "SampleRate": 48000, "BitRate": 4200000,
                          "Language": "jpn", "Title": "日语 TrueHD 7.1",
                          "IsDefault": true
                        },
                        {
                          "Index": 2, "Type": "Subtitle", "Codec": "ass",
                          "Language": "chi", "Title": "简中",
                          "IsDefault": true, "IsExternal": false
                        },
                        {
                          "Index": 3, "Type": "Subtitle", "Codec": "subrip",
                          "Language": "chi", "IsForced": true, "IsExternal": true
                        }
                      ]
                    }]
                  }],
                  "TotalRecordCount": 1
                }
                """,
                for: request.url!
            )
        } with: {
            let loaded = try await Self.server().mediaFileInfo(itemID: "ep-1")
            let info = try XCTUnwrap(loaded)

            let video = try XCTUnwrap(info.video)
            XCTAssertEqual(video.codec, "hevc")
            XCTAssertEqual(video.width, 3840)
            XCTAssertEqual(video.height, 2160)
            XCTAssertEqual(video.bitrate, 24_500_000)
            XCTAssertEqual(video.bitDepth, 10)
            XCTAssertEqual(try XCTUnwrap(video.frameRate), 23.976, accuracy: 0.001)
            XCTAssertEqual(video.colorPrimaries, "bt2020")
            XCTAssertEqual(video.colorTransfer, "smpte2084")
            XCTAssertEqual(video.colorSpace, "bt2020nc")
            XCTAssertEqual(video.colorRange, "tv")
            XCTAssertEqual(video.videoRangeType, "DOVIWithHDR10")
            XCTAssertEqual(video.profile, "Main 10")
            XCTAssertFalse(video.isInterlaced)

            XCTAssertEqual(info.audioTracks.count, 1)
            let audio = try XCTUnwrap(info.audioTracks.first)
            XCTAssertEqual(audio.codec, "truehd")
            XCTAssertEqual(audio.channels, 8)
            XCTAssertEqual(audio.channelLayout, "7.1")
            XCTAssertEqual(audio.sampleRate, 48_000)
            XCTAssertEqual(audio.bitrate, 4_200_000)
            XCTAssertEqual(audio.language, "jpn")
            XCTAssertEqual(audio.title, "日语 TrueHD 7.1")
            XCTAssertTrue(audio.isDefault)

            XCTAssertEqual(info.subtitleTracks.count, 2)
            XCTAssertEqual(info.subtitleTracks[0].codec, "ass")
            XCTAssertEqual(info.subtitleTracks[0].language, "chi")
            XCTAssertFalse(info.subtitleTracks[0].isExternal)
            XCTAssertTrue(info.subtitleTracks[0].isDefault)
            XCTAssertFalse(info.subtitleTracks[0].isForced)
            XCTAssertTrue(info.subtitleTracks[1].isForced)
            XCTAssertTrue(info.subtitleTracks[1].isExternal)

            XCTAssertEqual(info.container, "mkv")
            XCTAssertEqual(info.sizeBytes, 12_345_678_900)
            XCTAssertEqual(try XCTUnwrap(info.durationSeconds), 1450, accuracy: 0.001)
            // 只带文件名，不摊服务器目录结构。
            XCTAssertEqual(info.fileName, "Show S01E01.mkv")
            XCTAssertEqual(info.sourceCount, 1)
        }
    }

    /// 多版本条目：选源规则必须与开播一致（直连优先 → 直推 → 第一条）。
    func testPicksDirectPlaySourceLikePlaybackPath() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(
                """
                {
                  "Items": [{
                    "Id": "mv-9",
                    "MediaSources": [
                      {"Id": "transcode-only", "Container": "mp4",
                       "MediaStreams": [{"Type": "Video", "Codec": "h264", "Width": 1280, "Height": 720}]},
                      {"Id": "direct-stream", "Container": "mkv", "SupportsDirectStream": true,
                       "MediaStreams": [{"Type": "Video", "Codec": "hevc", "Width": 1920, "Height": 1080}]},
                      {"Id": "direct-play", "Container": "mkv", "SupportsDirectPlay": true,
                       "MediaStreams": [{"Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160}]}
                    ]
                  }],
                  "TotalRecordCount": 1
                }
                """,
                for: request.url!
            )
        } with: {
            let loaded = try await Self.server().mediaFileInfo(itemID: "mv-9")
            let info = try XCTUnwrap(loaded)
            // 直连优先：选中的是最后那条 4K 直连源，不是排在前面的直推 / 转码源。
            XCTAssertEqual(info.video?.width, 3840)
            XCTAssertEqual(info.container, "mkv")
            XCTAssertEqual(info.sourceCount, 3)
        }
    }

    /// 只有可直推源时选直推（第二轮规则），不是第一条。
    func testFallsBackToDirectStreamWhenNoDirectPlay() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(
                """
                {
                  "Items": [{
                    "Id": "mv-2",
                    "MediaSources": [
                      {"Id": "plain", "Container": "avi",
                       "MediaStreams": [{"Type": "Video", "Codec": "mpeg4", "Width": 720, "Height": 480}]},
                      {"Id": "stream", "SupportsDirectStream": true, "Container": "mp4",
                       "MediaStreams": [{"Type": "Video", "Codec": "h264", "Width": 1920, "Height": 1080}]}
                    ]
                  }]
                }
                """,
                for: request.url!
            )
        } with: {
            let loaded = try await Self.server().mediaFileInfo(itemID: "mv-2")
            let info = try XCTUnwrap(loaded)
            XCTAssertEqual(info.video?.width, 1920)
            XCTAssertEqual(info.container, "mp4")
            XCTAssertEqual(info.sourceCount, 2)
        }
    }

    /// 没有媒体源（目录 / 合集条目、或老服务端不返回）：返回 nil，调用方整块不渲染。
    func testReturnsNilWithoutMediaSources() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"Items":[{"Id":"folder-1","Name":"合集","Type":"Folder"}],"TotalRecordCount":1}"#, for: request.url!)
        } with: {
            let info = try await Self.server().mediaFileInfo(itemID: "folder-1")
            XCTAssertNil(info)
        }

        try await TestSupport.withMock { request in
            MockURLProtocol.ok(#"{"Items":[],"TotalRecordCount":0}"#, for: request.url!)
        } with: {
            let info = try await Self.server().mediaFileInfo(itemID: "missing")
            XCTAssertNil(info)
        }
    }

    /// 老服务端字段缺失：不崩，缺项为 nil，`sourceCount` 照报。
    func testToleratesMissingFields() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(
                #"{"Items":[{"Id":"old-1","MediaSources":[{"Id":"ms-old","Container":"mp4"}]}]}"#,
                for: request.url!
            )
        } with: {
            let loaded = try await Self.server().mediaFileInfo(itemID: "old-1")
            let info = try XCTUnwrap(loaded)
            XCTAssertNil(info.video)
            XCTAssertTrue(info.audioTracks.isEmpty)
            XCTAssertTrue(info.subtitleTracks.isEmpty)
            XCTAssertEqual(info.container, "mp4")
            XCTAssertNil(info.sizeBytes)
            XCTAssertNil(info.durationSeconds)
            XCTAssertNil(info.fileName)
            XCTAssertEqual(info.sourceCount, 1)
        }
    }

    /// 帧率回退：AverageFrameRate 缺失或离谱（0 / 超大脏值）时用 RealFrameRate。
    func testFrameRateFallsBackToRealFrameRate() async throws {
        try await TestSupport.withMock { request in
            MockURLProtocol.ok(
                """
                {
                  "Items": [{
                    "Id": "fps-1",
                    "MediaSources": [{
                      "Id": "ms-fps", "SupportsDirectPlay": true,
                      "MediaStreams": [
                        {"Index": 0, "Type": "Video", "Codec": "h264", "RealFrameRate": 25},
                        {"Index": 1, "Type": "Video", "Codec": "h264",
                         "AverageFrameRate": 0, "RealFrameRate": 30},
                        {"Index": 2, "Type": "Video", "Codec": "h264", "AverageFrameRate": 99999}
                      ]
                    }]
                  }]
                }
                """,
                for: request.url!
            )
        } with: {
            // 多视频流只取第一条：这里第一条只有 RealFrameRate。
            let loaded = try await Self.server().mediaFileInfo(itemID: "fps-1")
            let info = try XCTUnwrap(loaded)
            XCTAssertEqual(try XCTUnwrap(info.video?.frameRate), 25, accuracy: 0.001)
        }
    }

    private static func server() -> JellyfinServer {
        let profile = ServerProfile(id: "srv:user", serverName: "nas",
                                    baseURL: URL(string: "http://nas.local:8096")!,
                                    userID: "user", userName: nil, serverVersion: nil)
        let client = JellyfinServer.makeClient(baseURL: profile.baseURL, token: "tok",
                                               sessionConfiguration: TestSupport.mockedSessionConfiguration())
        return JellyfinServer(profile: profile, client: client)
    }
}
