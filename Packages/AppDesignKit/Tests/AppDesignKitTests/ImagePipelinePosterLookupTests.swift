import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import AppDesignKit

/// 「按条目复原缓存」的回归——登录页海报墙赖以工作的**全部**机制。
///
/// ## 为什么这个文件最要紧
///
/// 登录页铺墙时**没有 token**（登出 / 过期都会把 token 删掉），所以它不能用当前的
/// 认证头算缓存键，只能用会话还在时记下的**缓存身份**
/// （`ImagePipeline.cacheIdentity`）。于是系统里有两条算键的入口：
///
/// * 写入 / 正常读取走 `authHeader`；
/// * 登录页读取走 `cacheIdentity`。
///
/// 两者只要有一丁点不一致，墙就**一张图都命中不了**——而且不报错，只是悄悄退成
/// 程序化封面。那种失败在真机上看起来像「设计就是这样」，最难查。
///
/// 这里用真实的落盘路径（`load` 走网络写缓存）把两条入口对起来：写入用认证头，
/// 读出用身份，必须指到**同一个文件**。
final class ImagePipelinePosterLookupTests: XCTestCase {

    private let auth = "MediaBrowser Client=\"OcPlayer\", Device=\"mac\", DeviceId=\"D-1\", "
        + "Version=\"9.9.9 (1)\", Token=\"T-abc\""

    private func makePipeline() throws -> (ImagePipeline, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PosterLookup-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        HangingProtocol.handler = { _ in (200, Self.pngBytes) }
        HangingProtocol.hang = false
        return (ImagePipeline(cacheDirectory: dir, protocolClasses: [HangingProtocol.self]), dir)
    }

    private static let pngBytes: Data = {
        let context = CGContext(
            data: nil, width: 8, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    private func posterURL(_ id: String = "item-1", maxWidth: Int = 400) -> URL {
        URL(string: "http://192.168.1.10:8096/Items/\(id)/Images/Primary?maxWidth=\(maxWidth)&tag=tag-1")!
    }

    /// **核心**：写入用认证头、读出用记下来的身份，必须命中同一个文件。
    func testIdentityLookupFindsBytesWrittenViaAuthHeader() async throws {
        let (pipeline, _) = try makePipeline()
        let url = posterURL()

        // 会话还在时：正常加载 → 落盘
        let loaded = try await pipeline.load(url, authHeader: auth, maxPixelSize: 400)
        XCTAssertNotNil(loaded)

        // ① 用认证头查（在线路径）
        let viaHeader = pipeline.cachedFileURL(url: url, authHeader: auth, maxPixelSize: 400)
        XCTAssertNotNil(viaHeader, "刚写进去的字节，按认证头应当查得到")

        // ② 用**记下来的身份**查（登录页路径——那一刻 token 已经没了）
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        let viaIdentity = pipeline.cachedFileURL(url: url, cacheIdentity: identity, maxPixelSize: 400)
        XCTAssertNotNil(viaIdentity, "按缓存身份必须查到同一个文件；查不到 = 登录页海报墙全空")

        XCTAssertEqual(viaHeader, viaIdentity, "两条入口算出的必须是同一个键")
    }

    /// 身份不同就不该命中：两台服务器 / 两个账号的缓存互不可见。
    func testDifferentIdentityDoesNotMatch() async throws {
        let (pipeline, _) = try makePipeline()
        let url = posterURL()
        _ = try await pipeline.load(url, authHeader: auth, maxPixelSize: 400)

        XCTAssertNil(
            pipeline.cachedFileURL(url: url, cacheIdentity: "000000000000", maxPixelSize: 400),
            "别的账号的身份不该查到这台服务器的字节"
        )
    }

    /// `maxPixelSize` 是缓存键的一部分——**这正是参数阶梯存在的理由**。
    /// 报错一档就查不到，所以登录页要按阶梯逐个试。
    func testMaxPixelSizeIsPartOfTheKey() async throws {
        let (pipeline, _) = try makePipeline()
        let url = posterURL()
        _ = try await pipeline.load(url, authHeader: auth, maxPixelSize: 400)
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        XCTAssertNotNil(pipeline.cachedFileURL(url: url, cacheIdentity: identity, maxPixelSize: 400))
        XCTAssertNil(
            pipeline.cachedFileURL(url: url, cacheIdentity: identity, maxPixelSize: 300),
            "解码预算不同就是不同的键——阶梯里每一档都得单独试"
        )
    }

    /// `maxWidth` 在 URL 查询里，同样是键的一部分。
    func testMaxWidthIsPartOfTheKey() async throws {
        let (pipeline, _) = try makePipeline()
        _ = try await pipeline.load(posterURL(maxWidth: 400), authHeader: auth, maxPixelSize: 400)
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        XCTAssertNotNil(
            pipeline.cachedFileURL(url: posterURL(maxWidth: 400), cacheIdentity: identity, maxPixelSize: 400)
        )
        XCTAssertNil(
            pipeline.cachedFileURL(url: posterURL(maxWidth: 300), cacheIdentity: identity, maxPixelSize: 400)
        )
    }

    /// `tag` 也进键：服务端换图后 tag 变，旧字节自然查不到（正确的失效语义）。
    func testTagIsPartOfTheKey() async throws {
        let (pipeline, _) = try makePipeline()
        _ = try await pipeline.load(posterURL(), authHeader: auth, maxPixelSize: 400)
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        let otherTag = URL(string:
            "http://192.168.1.10:8096/Items/item-1/Images/Primary?maxWidth=400&tag=tag-2")!
        XCTAssertNil(pipeline.cachedFileURL(url: otherTag, cacheIdentity: identity, maxPixelSize: 400))
    }

    /// **跨实例**（= 重启 App）仍然查得到。登录页几乎总是冷启动后的第一屏，
    /// 只在同一个实例里成立的话这个功能等于没有。
    func testLookupSurvivesRestart() async throws {
        let (pipeline, dir) = try makePipeline()
        let url = posterURL()
        _ = try await pipeline.load(url, authHeader: auth, maxPixelSize: 400)
        let identity = ImagePipeline.cacheIdentity(authHeader: auth)

        let restarted = ImagePipeline(cacheDirectory: dir, protocolClasses: [HangingProtocol.self])
        let found = restarted.cachedFileURL(url: url, cacheIdentity: identity, maxPixelSize: 400)
        XCTAssertNotNil(found, "重启后仍要查得到，否则登录页永远只有程序化封面")
    }

    /// 查到的文件能解出图（查键与解码是两件事，配起来才算数）。
    func testFoundFileDecodes() async throws {
        let (pipeline, _) = try makePipeline()
        let url = posterURL()
        _ = try await pipeline.load(url, authHeader: auth, maxPixelSize: 400)

        let identity = ImagePipeline.cacheIdentity(authHeader: auth)
        let file = try XCTUnwrap(
            pipeline.cachedFileURL(url: url, cacheIdentity: identity, maxPixelSize: 400)
        )
        let image = await pipeline.decodeCachedFile(file, maxPixelSize: 400)
        XCTAssertNotNil(image)
    }

    /// 缓存里没有的条目：查键返回 nil，**不触发网络**（这是登录页的前提——
    /// 墙是装饰，不该产生任何流量）。
    func testMissDoesNotTouchNetwork() throws {
        let (pipeline, _) = try makePipeline()
        HangingProtocol.hang = true   // 之后任何网络请求都会永久挂起

        let start = Date()
        let result = pipeline.cachedFileURL(
            url: posterURL("never-cached"), authHeader: auth, maxPixelSize: 400
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.5, "查缓存是纯本地操作，不该等任何东西")
    }
}
