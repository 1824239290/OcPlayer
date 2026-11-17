import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AppDesignKit

final class ImageServerIsolationTests: XCTestCase {
    private let authA = "Emby DeviceId=\"same-device\", UserId=\"same-user\", Token=\"token-a\""
    private let authB = "Emby DeviceId=\"same-device\", UserId=\"same-user\", Token=\"token-b\""
    private let urlA = URL(string: "https://server-a.invalid/Items/42/Images/Primary?maxWidth=720")!
    private let urlB = URL(string: "https://server-b.invalid/Items/42/Images/Primary?maxWidth=720")!

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func request(_ url: URL, auth: String?, scope: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        return ImageCacheKey.scopedRequest(request, cacheScope: scope)
    }

    func testUnscopedRequestsDoNotShareImagesAcrossOrigins() throws {
        // The exact final-review reproduction: local user/item ids, distinct origins and tokens.
        let keyA = ImageCacheKey.canonicalURL(for: urlA, authHeader: authA)
        let keyB = ImageCacheKey.canonicalURL(for: urlB, authHeader: authB)
        XCTAssertNotEqual(keyA, keyB)
        let cache = CanonicalImageURLCache(memoryCapacity: 1_048_576, diskCapacity: 0, directory: try directory())
        let a = request(urlA, auth: authA, scope: nil)
        let b = request(urlB, auth: authB, scope: nil)
        let response = try XCTUnwrap(HTTPURLResponse(url: urlA, statusCode: 200, httpVersion: nil, headerFields: nil))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("A".utf8)), for: a)
        XCTAssertEqual(cache.cachedResponse(for: a)?.data, Data("A".utf8))
        XCTAssertNil(cache.cachedResponse(for: b))
    }

    func testScopeIsolatedEvenWhenOriginAndUserAreIdentical() throws {
        let cache = CanonicalImageURLCache(memoryCapacity: 1_048_576, diskCapacity: 0, directory: try directory())
        let a = request(urlA, auth: authA, scope: "server-A:account")
        let b = request(urlA, auth: authB, scope: "server-B:account")
        let response = try XCTUnwrap(HTTPURLResponse(url: urlA, statusCode: 200, httpVersion: nil, headerFields: nil))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("A".utf8)), for: a)
        XCTAssertEqual(cache.cachedResponse(for: a)?.data, Data("A".utf8))
        XCTAssertNil(cache.cachedResponse(for: b))
        XCTAssertEqual(a.allHTTPHeaderFields, ["Authorization": authA], "cache context stays out of HTTP headers")
        XCTAssertEqual(a.url, urlA, "cache context stays out of the network URL")
    }

    func testVerifiedServerReusesCacheAcrossAddressAndTokenChanges() throws {
        let a = ImageCacheKey.canonicalURL(for: urlA, authHeader: authA, cacheScope: "server-A:account")
        let b = ImageCacheKey.canonicalURL(for: urlB, authHeader: authB, cacheScope: "server-A:account")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ImageCacheKey.canonicalURL(for: urlB, authHeader: authB, cacheScope: "server-B:account"))
    }

    func testMissingContextSeparatesSchemesAndPorts() {
        let https = URL(string: "https://server.invalid/Items/42/Images/Primary")!
        let explicitDefault = URL(string: "https://server.invalid:443/Items/42/Images/Primary")!
        let http = URL(string: "http://server.invalid/Items/42/Images/Primary")!
        let otherPort = URL(string: "https://server.invalid:8443/Items/42/Images/Primary")!
        let identity = ImagePipeline.cacheIdentity(url: https, authHeader: authA)
        XCTAssertEqual(identity, ImagePipeline.cacheIdentity(url: explicitDefault, authHeader: authB))
        XCTAssertNotEqual(identity, ImagePipeline.cacheIdentity(url: http, authHeader: authA))
        XCTAssertNotEqual(identity, ImagePipeline.cacheIdentity(url: otherPort, authHeader: authA))
    }

    func testMemoryBlobAndLoginLookupAreAllServerScoped() async throws {
        let dir = try directory()
        IsolationProtocol.reset()
        let pipeline = ImagePipeline(cacheDirectory: dir, protocolClasses: [IsolationProtocol.self])
        let scopeA = "server-A:account"
        let scopeB = "server-B:account"
        let first = try await pipeline.load(urlA, authHeader: authA, cacheScope: scopeA, maxPixelSize: 720)
        XCTAssertNotNil(first)
        XCTAssertNotNil(pipeline.memoryCachedImage(url: urlA, authHeader: authA, cacheScope: scopeA, maxPixelSize: 720))
        XCTAssertNil(pipeline.memoryCachedImage(url: urlA, authHeader: authB, cacheScope: scopeB, maxPixelSize: 720))
        XCTAssertNil(pipeline.cachedFileURL(url: urlA, authHeader: authB, cacheScope: scopeB, maxPixelSize: 720))
        let absent = await pipeline.cachedImage(url: urlA, authHeader: authB, cacheScope: scopeB, maxPixelSize: 720)
        XCTAssertNil(absent)

        let identityA = ImagePipeline.cacheIdentity(url: urlA, authHeader: authA, cacheScope: scopeA)
        XCTAssertNil(pipeline.cachedFileURL(url: urlA, cacheIdentity: identityA, cacheScope: scopeB, maxPixelSize: 720))
        XCTAssertNil(pipeline.cachedFileURL(url: urlA, cacheIdentity: ImageCacheKey.authIdentity(authA), cacheScope: scopeA, maxPixelSize: 720))
        let fileA = try XCTUnwrap(pipeline.cachedFileURL(url: urlA, cacheIdentity: identityA, cacheScope: scopeA, maxPixelSize: 720))
        let second = try await pipeline.load(urlA, authHeader: authB, cacheScope: scopeB, maxPixelSize: 720)
        XCTAssertNotNil(second)
        let fileB = try XCTUnwrap(pipeline.cachedFileURL(url: urlA, authHeader: authB, cacheScope: scopeB, maxPixelSize: 720))
        XCTAssertNotEqual(try Data(contentsOf: fileA), try Data(contentsOf: fileB), "the B response must come from B")
        XCTAssertEqual(IsolationProtocol.count, 2)

        // Same server, new address and token: no extra network request.
        _ = try await pipeline.load(urlB, authHeader: authB, cacheScope: scopeA, maxPixelSize: 720)
        XCTAssertEqual(IsolationProtocol.count, 2)
        let restarted = ImagePipeline(cacheDirectory: dir, protocolClasses: [IsolationProtocol.self])
        let restored = await restarted.cachedImage(url: urlB, authHeader: authB, cacheScope: scopeA, maxPixelSize: 720)
        XCTAssertNotNil(restored)
        XCTAssertEqual(IsolationProtocol.count, 2)
    }

    func testCacheIdentityChangesRestartTheViewLoadKey() {
        let a = RemoteImage.probeScopedLoadKey(url: urlA, authHeader: authA, cacheScope: "A", maxPixelSize: 720)
        let b = RemoteImage.probeScopedLoadKey(url: urlA, authHeader: authA, cacheScope: "B", maxPixelSize: 720)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("token-a"))
    }

    func testStaleBlobRefreshBypassesTheCurrentURLCache() async throws {
        let dir = try directory()
        IsolationProtocol.reset()
        let scope = "server-A:account"
        let first = ImagePipeline(cacheDirectory: dir, protocolClasses: [IsolationProtocol.self])
        _ = try await first.load(urlA, authHeader: authA, cacheScope: scope, maxPixelSize: 400)
        let file = try XCTUnwrap(first.cachedFileURL(url: urlA, authHeader: authA, cacheScope: scope, maxPixelSize: 400))
        let original = try Data(contentsOf: file)
        let old = Date().addingTimeInterval(-ImagePipeline.blobStalenessThreshold - 3600)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: file.path)

        // Warm this instance's URLCache with a different decode budget. Its 400px blob
        // stays stale, while its URLCache already has this exact URL/account response.
        let restarted = ImagePipeline(cacheDirectory: dir, protocolClasses: [IsolationProtocol.self])
        _ = try await restarted.load(urlA, authHeader: authA, cacheScope: scope, maxPixelSize: 720)
        let before = IsolationProtocol.count
        _ = try await restarted.load(urlA, authHeader: authB, cacheScope: scope, maxPixelSize: 400)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (try Data(contentsOf: file)) == original {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(IsolationProtocol.count, before + 1, "background refresh must reach the server")
        XCTAssertNotEqual(try Data(contentsOf: file), original, "the refreshed token-b response is blue")
    }
}

private final class IsolationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let isB = request.value(forHTTPHeaderField: "Authorization")?.contains("token-b") == true
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: isB ? 0 : 1, green: 0, blue: isB ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: data as Data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
