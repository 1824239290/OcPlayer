import Foundation
import XCTest
@testable import JellyfinKit

final class SubtitleSourceIsolationTests: XCTestCase {
    private func server(emby: Bool, host: String = "nas.local") -> any MediaServer {
        let profile = ServerProfile(id: "same-profile", serverName: "nas", baseURL: URL(string: "http://\(host):8096")!, userID: "user", userName: nil, serverVersion: nil, kind: emby ? .emby : .jellyfin)
        if emby {
            return EmbyServer(profile: profile, session: EmbySession(baseURL: profile.baseURL, accessToken: "tok", userID: "user", profileID: profile.id, sessionConfiguration: TestSupport.mockedSessionConfiguration()))
        }
        return JellyfinServer(profile: profile, client: JellyfinServer.makeClient(baseURL: profile.baseURL, token: "tok", sessionConfiguration: TestSupport.mockedSessionConfiguration()))
    }

    func testBothServersUseSelectedSourceAndNeverFallbackForMissingID() async throws {
        let fixture = #"{"Items":[{"Id":"item","MediaSources":[{"Id":"first","SupportsDirectPlay":false,"MediaStreams":[{"Index":2,"Type":"Subtitle","IsExternal":true,"Codec":"subrip","Title":"First"}]},{"Id":"second","SupportsDirectPlay":true,"MediaStreams":[{"Index":2,"Type":"Subtitle","IsExternal":true,"Codec":"ass","Title":"Second"}]}]}]}"#
        for emby in [false, true] {
            try await TestSupport.withMock { request in
                MockURLProtocol.ok(fixture, for: request.url!)
            } with: {
                let server = self.server(emby: emby)
                let selected = try await server.externalSubtitles(itemID: "item", mediaSourceID: "second")
                XCTAssertEqual(selected.map(\.title), ["Second"])
                XCTAssertEqual(selected.first?.remotePath, "/Videos/item/second/Subtitles/2/Stream.ass")
                let missing = try await server.externalSubtitles(itemID: "item", mediaSourceID: "missing")
                XCTAssertTrue(missing.isEmpty)
                let preferred = try await server.externalSubtitles(itemID: "item", mediaSourceID: nil)
                XCTAssertEqual(preferred.map(\.title), ["Second"])
                let first = try await server.externalSubtitles(itemID: "item", mediaSourceID: "first")
                XCTAssertEqual(first.map(\.title), ["First"])
                XCTAssertNotEqual(first.first?.id, selected.first?.id)
            }
        }
    }

    func testCacheSeparatesServersSourcesAndFormatsWithoutLossySanitizing() async throws {
        for emby in [false, true] {
            try await TestSupport.withMock { request in
                MockURLProtocol.ok(request.url!.absoluteString, for: request.url!)
            } with: {
                let a = self.server(emby: emby)
                let b = self.server(emby: emby, host: "other.local")
                let first = ExternalSubtitle(itemID: "same/item", mediaSourceID: "source:a", index: 2, title: nil, language: nil, codec: "subrip")
                let second = ExternalSubtitle(itemID: "same/item", mediaSourceID: "source-a", index: 2, title: nil, language: nil, codec: "subrip")
                let ass = ExternalSubtitle(itemID: "same/item", mediaSourceID: "source:a", index: 2, title: nil, language: nil, codec: "ass")
                let urls = try await [a.downloadSubtitle(first), b.downloadSubtitle(first), a.downloadSubtitle(second), a.downloadSubtitle(ass)]
                defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
                XCTAssertEqual(Set(urls).count, 4)
                XCTAssertEqual(Set(try urls.map { try String(contentsOf: $0, encoding: .utf8) }).count, 4)
                let repeatDownload = try await a.downloadSubtitle(first)
                XCTAssertEqual(repeatDownload, urls[0], "Cache identity must be stable")
            }
        }
    }
}
