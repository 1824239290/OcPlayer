import AppDesignKit
import BangumiKit
import CoreModel
import Foundation
import ImageIO
import JellyfinKit
import XCTest
@testable import OcPlayer

@MainActor
final class ViewingProfileAvatarTests: XCTestCase {
    private var directory: URL!
    private var pipeline: ImagePipeline!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        pipeline = ImagePipeline(cacheDirectory: directory, protocolClasses: [MockURLProtocol.self])
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func bangumiProfile() -> BangumiProfile {
        var profile = BangumiProfile()
        profile.id = 42
        profile.username = "viewer"
        profile.avatar = BangumiAvatar(large: "https://bgm-avatar.example/avatar.png")
        return profile
    }
    nonisolated private static func png(side: Int) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
    private func imageRequest(_ path: String) -> ViewingAvatarRequest {
        .init(identity: path, source: .bangumi, sourceName: "Bangumi",
              url: URL(string: "https://avatar-tests.example/\(path).png"), authHeader: nil, cacheScope: nil)
    }

    func testPendingServerMetadataDoesNotShowBangumiFirst() {
        let request = ViewingAvatarRequest.resolve(server: StubMediaServer(), generation: 1,
                                                   resolution: .pending, bangumiProfile: bangumiProfile())
        XCTAssertNil(request, "A cached Bangumi avatar must wait until the preferred server is checked")
    }

    func testCustomServerAvatarHasPriorityAndPreservesAuthenticatedCacheScope() throws {
        let server = StubMediaServer(primaryImageTag: "custom")
        let request = try XCTUnwrap(ViewingAvatarRequest.resolve(server: server, generation: 1,
                                                                 resolution: .resolved(tag: "custom"), bangumiProfile: bangumiProfile()))
        XCTAssertEqual(request.source, .server)
        XCTAssertEqual(request.url, server.userImageURL(tag: "custom"))
        XCTAssertEqual(request.authHeader, server.authorizationHeader)
        XCTAssertEqual(request.cacheScope, server.profile.imageCacheScope)
    }

    func testDefaultServerAvatarFallsBackDirectlyToBangumi() throws {
        for tag: String? in [nil, "", "  "] {
            let request = try XCTUnwrap(ViewingAvatarRequest.resolve(server: StubMediaServer(), generation: 1,
                                                                     resolution: .resolved(tag: tag), bangumiProfile: bangumiProfile()))
            XCTAssertEqual(request.source, .bangumi)
            XCTAssertEqual(request.url?.host, "bgm-avatar.example")
            XCTAssertNil(request.authHeader, "Server credentials cannot be sent to Bangumi images")
        }
    }

    func testBangumiWorksWithoutMediaServerAndNoAvatarHasExplicitFallback() throws {
        let bgm = try XCTUnwrap(ViewingAvatarRequest.resolve(server: nil, generation: 1,
                                                            resolution: .pending, bangumiProfile: bangumiProfile()))
        XCTAssertEqual(bgm.source, .bangumi)
        let none = try XCTUnwrap(ViewingAvatarRequest.resolve(server: StubMediaServer(), generation: 1,
                                                             resolution: .resolved(tag: nil), bangumiProfile: nil))
        XCTAssertEqual(none.source, .none)
        XCTAssertNil(none.url)
    }

    func testHeaderRemainsHiddenUntilPreferredBitmapIsPrepared() async throws {
        let bytes = Self.png(side: 64)
        MockURLProtocol.handler = { request in
            Thread.sleep(forTimeInterval: 0.15)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!, bytes)
        }
        let request = try XCTUnwrap(ViewingAvatarRequest.resolve(server: StubMediaServer(), generation: 1,
                                                                 resolution: .resolved(tag: "custom"), bangumiProfile: bangumiProfile()))
        let model = ViewingProfileAvatarModel()
        let task = Task { await model.load(request, pipeline: pipeline) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isReady(for: request))
        XCTAssertNil(model.image, "A placeholder/default avatar cannot become a visible intermediate face")
        await task.value
        XCTAssertTrue(model.isReady(for: request))
        XCTAssertEqual(model.request?.source, .server)
        XCTAssertNotNil(model.image)
    }

    func testNewAccountImmediatelyHidesPreviousAvatar() async throws {
        let bytes = Self.png(side: 64)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "image/png"])!, bytes)
        }
        let model = ViewingProfileAvatarModel()
        let first = imageRequest("one")
        let second = imageRequest("two")
        await model.load(first, pipeline: pipeline)
        XCTAssertTrue(model.isReady(for: first))
        XCTAssertFalse(model.isReady(for: second), "Guard by current account before a new task even starts")
        XCTAssertFalse(model.isReady(for: nil))
        await model.load(second, pipeline: pipeline)
        XCTAssertTrue(model.isReady(for: second))
        XCTAssertFalse(model.isReady(for: first))
    }

    func testOldSlowResponseCannotOverwriteNewAccount() async throws {
        let firstBytes = Self.png(side: 64)
        let secondBytes = Self.png(side: 32)
        MockURLProtocol.handler = { request in
            let isOld = request.url!.path.contains("old")
            if isOld { Thread.sleep(forTimeInterval: 0.2) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!, isOld ? firstBytes : secondBytes)
        }
        let model = ViewingProfileAvatarModel()
        let old = imageRequest("old")
        let new = imageRequest("new")
        let task = Task { await model.load(old, pipeline: pipeline) }
        try await Task.sleep(for: .milliseconds(50))
        await model.load(new, pipeline: pipeline)
        await task.value
        XCTAssertTrue(model.isReady(for: new))
        XCTAssertEqual(model.image?.size.width, 32)
    }

    func testDefaultFallbackOnlyPublishesAfterSourceResolutionAndResetHidesIt() async throws {
        let none = try XCTUnwrap(ViewingAvatarRequest.resolve(server: nil, generation: 1,
                                                             resolution: .pending, bangumiProfile: nil))
        let model = ViewingProfileAvatarModel()
        XCTAssertFalse(model.isReady(for: none))
        await model.load(none, pipeline: pipeline)
        XCTAssertTrue(model.isReady(for: none))
        XCTAssertNil(model.image)
        model.reset()
        XCTAssertFalse(model.isReady(for: none))
    }
}
