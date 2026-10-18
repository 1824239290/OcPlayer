import AppDesignKit
import CoreGraphics
import CoreModel
import Foundation
import ImageIO
import JellyfinKit
import MetadataKit
import UniformTypeIdentifiers
import XCTest

@testable import OcPlayer

/// 登录页海报墙**逐候选判定**（`LoginWallCatalogLoader.resolvePosters` /
/// `resolvePosterFile`）的回归。
///
/// ## 为什么这组用例值得单独存在
///
/// 这段逻辑被搬进 `nonisolated static` 是为了**离开主线程**（性能审查清单 `P1-09`：
/// 5 760 次 `cachedFileURL` 实测 125–199 ms，改前全在主线程上）。搬出去的风险是
/// 「键算错了 / 阶梯顺序变了 / 身份没试全」—— 而任何一种都**不会报错**，只是墙上
/// 少几张图或整面退成程序化封面。所以这里用**真实落盘**（`ImagePipeline.load` 走
/// mock 网络写 blob）把「存进去的那条键」与「按档案+身份复原出来的键」对起来。
final class LoginWallPosterResolutionTests: XCTestCase {

    private let auth = "MediaBrowser Client=\"OcPlayer\", Device=\"mac\", "
        + "DeviceId=\"D-1\", Version=\"9.9.9 (1)\", Token=\"T-abc\""

    // MARK: - 夹具

    /// 8×12 纯色 PNG。真实解码路径要它（`ImagePipeline.load` 会强制解码后才存 blob）。
    private static let pngBytes: Data = {
        let context = CGContext(
            data: nil, width: 8, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    private func makePipeline() -> (ImagePipeline, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginWallResolution-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png"])!, Self.pngBytes)
        }
        addTeardownBlock { MockURLProtocol.handler = nil }
        return (ImagePipeline(
            cacheDirectory: dir,
            protocolClasses: [MockURLProtocol.self]), dir)
    }

    private func makeProfile() -> ServerProfile {
        ServerProfile(
            id: "srv:user", serverName: "probe",
            baseURL: URL(string: "https://media.example.com")!, userID: "user")
    }

    private func makeCandidate(id: String, tag: String?) -> CachedItem {
        CachedItem(
            item: MediaItem(
                id: id, name: "Item \(id)", kind: .movie, primaryImageTag: tag),
            fetchedAt: Date(),
            progressFetchedAt: nil)
    }

    /// 按某一档阶梯把字节写进缓存（走真实 `load` 路径，键由 `ImagePipeline` 自己算）。
    @discardableResult
    private func seedCache(
        pipeline: ImagePipeline,
        profile: ServerProfile,
        itemID: String,
        tag: String,
        step: (maxWidth: Int, maxPixelSize: Int)
    ) async -> URL? {
        guard let url = profile.imageURL(
            itemID: itemID, type: .primary, maxWidth: step.maxWidth, tag: tag
        ) else { return nil }
        _ = try? await pipeline.load(url, authHeader: auth, maxPixelSize: step.maxPixelSize)
        return url
    }

    // MARK: - resolvePosterFile：单张判定

    /// 字节在缓存里 → 必须命中，且返回的 URL **确实存在**。
    func testResolvePosterFileFindsCachedBytes() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (400, 400))

        let file = LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile, identities: [identity],
            itemID: "abc123", tag: "t1")

        let unwrapped = try? XCTUnwrap(file)
        XCTAssertNotNil(unwrapped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped?.path ?? ""))
    }

    /// 字节不在缓存里 → `nil`（不抛错、不误报）。
    func testResolvePosterFileReturnsNilWhenAbsent() {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        let file = LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile, identities: [identity],
            itemID: "never-cached", tag: "t1")
        XCTAssertNil(file)
    }

    /// **身份历史要多试**：token 轮换后当前身份查不到，但旧身份记着字节。
    /// 这条守的是「轮换一次墙上 47 张图全消失」那个真实事故。
    func testResolvePosterFileTriesEveryIdentity() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let realIdentity = ImagePipeline.cacheIdentity(authHeader: auth)
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (400, 400))

        // 第一个身份是过期的，第二个才对。
        let file = LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile,
            identities: ["stale0000000", realIdentity],
            itemID: "abc123", tag: "t1")
        XCTAssertNotNil(file, "第二个身份应当命中（身份历史必须逐个试）")
    }

    /// **阶梯每一档都要试**：字节当初是按 `maxWidth=300` 存的，复原时要能找到。
    func testResolvePosterFileTriesEveryLadderStep() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        // 只写第二档（300/300）。
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (300, 300))

        let file = LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile, identities: [identity],
            itemID: "abc123", tag: "t1")
        XCTAssertNotNil(file, "第一档未命中时必须继续试后面的阶梯")
    }

    /// **`maxWidth` 与 `maxPixelSize` 不能互换**。
    ///
    /// 阶梯里前两档 `(400,400)` / `(300,300)` 的两个数值**恰好相同**，所以只写这两档
    /// 的 fixture 结构上发现不了「把 `step.maxWidth` 与 `step.maxPixelSize` 用反」这个
    /// 变异（独立审查实测：用反后前两档仍全部命中、10 条用例全绿）。
    ///
    /// 第三档 `(720, 360)` 是唯一**数值不对称**的一档，这条专门写它。
    func testResolvePosterFileKeepsAsymmetricLadderStepParameters() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        // 只按第三档 (720, 360) 写：maxWidth=720、maxPixelSize=360。
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (720, 360))

        let file = LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile, identities: [identity],
            itemID: "abc123", tag: "t1")
        XCTAssertNotNil(
            file,
            "第三档 (720,360) 的 maxWidth 与 maxPixelSize 数值不同 —— "
                + "把两者用反时这条会红（前两档 (400,400)/(300,300) 发现不了）")
    }

    /// 阶梯**顺序**：两档都写了字节时，必须返回**先命中**那一档的文件。
    func testResolvePosterFilePrefersEarlierLadderStep() async throws {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        // 两档都写。第一档 (400,400) 在阶梯里更靠前。
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (400, 400))
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (720, 360))

        let file = try XCTUnwrap(LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile, identities: [identity],
            itemID: "abc123", tag: "t1"))

        // 第一档对应的键必须与命中的这个文件一致。
        let firstStep = try XCTUnwrap(LoginWallStyle.cacheParameterLadder.first)
        let firstURL = try XCTUnwrap(profile.imageURL(
            itemID: "abc123", type: .primary, maxWidth: firstStep.maxWidth, tag: "t1"))
        let expected = try XCTUnwrap(pipeline.cachedFileURL(
            url: firstURL, cacheIdentity: identity, maxPixelSize: firstStep.maxPixelSize))
        XCTAssertEqual(file, expected, "两档都命中时必须返回阶梯里更靠前的那一档")
    }

    /// 空身份池 → 直接 nil（不能因为「没有身份」就退化成用当前认证头）。
    func testResolvePosterFileReturnsNilWithoutIdentities() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "abc123", tag: "t1",
            step: (400, 400))

        let file = LoginWallCatalogLoader.resolvePosterFile(
            pipeline: pipeline, profile: profile, identities: [],
            itemID: "abc123", tag: "t1")
        XCTAssertNil(file)
    }

    // MARK: - resolvePosters：整批判定

    /// `limit` 是硬上界：命中数到了就停，不多算。
    func testResolvePostersStopsAtLimit() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        var candidates: [CachedItem] = []
        for index in 0..<10 {
            let id = "item\(index)"
            candidates.append(makeCandidate(id: id, tag: "t\(index)"))
            await seedCache(
                pipeline: pipeline, profile: profile, itemID: id, tag: "t\(index)",
                step: (400, 400))
        }

        let posters = await LoginWallCatalogLoader.resolvePosters(
            candidates: candidates, profile: profile, identities: [identity],
            pipeline: pipeline, limit: 4)
        XCTAssertEqual(posters.count, 4, "limit 必须封住数量")
    }

    /// 没有 `primaryImageTag` 的条目直接跳过（没有 tag 就拼不出原始 URL）。
    func testResolvePostersSkipsItemsWithoutImageTag() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "item1", tag: "t1",
            step: (400, 400))

        let candidates = [
            makeCandidate(id: "item0", tag: nil),
            makeCandidate(id: "item1", tag: "t1"),
        ]
        let posters = await LoginWallCatalogLoader.resolvePosters(
            candidates: candidates, profile: profile, identities: [identity],
            pipeline: pipeline, limit: 10)
        XCTAssertEqual(posters.map(\.id), ["item1"])
    }

    /// 全部未命中 → 空数组（调用方据此退程序化封面）。
    func testResolvePostersReturnsEmptyWhenNothingCached() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        let candidates = (0..<5).map { makeCandidate(id: "item\($0)", tag: "t\($0)") }
        let posters = await LoginWallCatalogLoader.resolvePosters(
            candidates: candidates, profile: profile, identities: [identity],
            pipeline: pipeline, limit: 10)
        XCTAssertTrue(posters.isEmpty)
    }

    /// `limit <= 0` 时立即返回，不做任何文件判定（多服务器累加时最后可能刚好凑满）。
    func testResolvePostersShortCircuitsOnNonPositiveLimit() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "item0", tag: "t0",
            step: (400, 400))

        let candidates = [makeCandidate(id: "item0", tag: "t0")]
        for limit in [0, -3] {
            let posters = await LoginWallCatalogLoader.resolvePosters(
                candidates: candidates, profile: profile, identities: [identity],
                pipeline: pipeline, limit: limit)
            XCTAssertTrue(posters.isEmpty, "limit=\(limit) 应立即返回空")
        }
    }

    /// 程序化封面参数照样要装配好（墙给每张都配了 `art`）。
    func testResolvePostersAttachesProceduralArt() async {
        let (pipeline, _) = makePipeline()
        let profile = makeProfile()
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        await seedCache(
            pipeline: pipeline, profile: profile, itemID: "item0", tag: "t0",
            step: (400, 400))

        let posters = await LoginWallCatalogLoader.resolvePosters(
            candidates: [makeCandidate(id: "item0", tag: "t0")], profile: profile,
            identities: [identity], pipeline: pipeline, limit: 1)
        let poster = try? XCTUnwrap(posters.first)
        XCTAssertEqual(poster?.art, LoginWallArt.make(seedString: "item0"),
                       "art 必须由条目 id 播种，否则条目淘汰后封面会整体换面孔")
    }
}
