import XCTest
@testable import JellyfinKit

/// Jellyfin 外挂字幕：MediaStreams 解析 + 认证下载落盘。
final class ExternalSubtitleTests: XCTestCase {

    func testCodecMapping() {
        XCTAssertEqual(ExternalSubtitle.fileExtension(forCodec: "subrip"), "srt")
        XCTAssertEqual(ExternalSubtitle.fileExtension(forCodec: "SRT"), "srt")
        XCTAssertEqual(ExternalSubtitle.fileExtension(forCodec: "ass"), "ass")
        XCTAssertEqual(ExternalSubtitle.fileExtension(forCodec: "ssa"), "ssa")
        XCTAssertEqual(ExternalSubtitle.fileExtension(forCodec: "webvtt"), "vtt")
        // 图像字幕不认
        XCTAssertNil(ExternalSubtitle.fileExtension(forCodec: "pgs"))
        XCTAssertNil(ExternalSubtitle.fileExtension(forCodec: "pgssub"))
        XCTAssertNil(ExternalSubtitle.fileExtension(forCodec: "dvdsub"))
    }

    func testExternalSubtitlesParsesStreamsAndSkipsEmbedded() async throws {
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Items")
            let query = TestSupport.queryItems(of: request)
            XCTAssertEqual(query["ids"], "item-7")
            return MockURLProtocol.ok(
                """
                {"Items":[{
                  "Id":"item-7","Name":"沙丘 2","Type":"Movie",
                  "MediaSources":[{
                    "Id":"item-7",
                    "MediaStreams":[
                      {"Index":0,"Type":"Video","Codec":"hevc"},
                      {"Index":1,"Type":"Audio","Codec":"truehd"},
                      {"Index":2,"Type":"Subtitle","IsExternal":true,"Codec":"subrip",
                       "Language":"chi","Title":"简体中文","DisplayTitle":"简体中文 (SRT External)"},
                      {"Index":3,"Type":"Subtitle","IsExternal":true,"Codec":"ass",
                       "Language":"eng","Title":"English"},
                      {"Index":4,"Type":"Subtitle","IsExternal":false,"Codec":"subrip","Language":"chi"},
                      {"Index":5,"Type":"Subtitle","IsExternal":true,"Codec":"pgssub","Language":"chi"}
                    ]
                  }]
                }],"TotalRecordCount":1}
                """,
                for: request.url!
            )
        } with: {
            let subs = try await Self.server().externalSubtitles(itemID: "item-7")
            // 内封（IsExternal=false）和 PGS 图像字幕都要被跳过
            XCTAssertEqual(subs.map(\.index), [2, 3])
            XCTAssertEqual(subs[0].fileExtension, "srt")
            XCTAssertEqual(subs[0].title, "简体中文")
            XCTAssertEqual(subs[0].remotePath, "/Videos/item-7/item-7/Subtitles/2/Stream.srt")
            XCTAssertEqual(subs[1].remotePath, "/Videos/item-7/item-7/Subtitles/3/Stream.ass")
        }
    }

    func testDownloadSubtitleWritesFileWithAuthHeader() async throws {
        let body = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
        var capturedAuth: String?
        try await TestSupport.withMock { request in
            XCTAssertEqual(request.url?.path, "/Videos/item-7/item-7/Subtitles/2/Stream.srt")
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "text/plain"])!
            return (response, Data(body.utf8))
        } with: {
            let sub = ExternalSubtitle(itemID: "item-7", index: 2, title: "简体中文",
                                       language: "chi", codec: "subrip")
            let url = try await Self.server().downloadSubtitle(sub)
            defer { try? FileManager.default.removeItem(at: url) }

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), body)
            XCTAssertEqual(url.pathExtension, "srt")
        }
        let auth = try XCTUnwrap(capturedAuth)
        XCTAssertTrue(auth.hasPrefix("MediaBrowser "), "下载必须带认证头而不是 api_key")
        XCTAssertTrue(auth.contains("Token=tok"))
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
