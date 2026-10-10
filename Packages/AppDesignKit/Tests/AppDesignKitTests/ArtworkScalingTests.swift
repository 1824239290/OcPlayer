import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import AppDesignKit

/// 卡片图区**「四边贴死」**的回归：拿一张四边带红框的合成图，渲染一帧后检查
/// ①四条边上的红框都在（没裁切）②图片正好铺满盒子（没留灰边）。
///
/// 为什么必须量像素：这两条都是**几何后果**，断言常量看不见它们——盒宽 113 在图片被
/// 裁掉一半、或上下留出 6pt 灰边时照样成立。红框是证人：它贴着图片四边，裁哪条哪条
/// 就量不到红；而「有没有留边」靠比较图片实际范围与盒子尺寸。
///
/// 量法用**红框像素的外接矩形**：圆的四角会切掉一点，但外接矩形取的是整片红像素的
/// 极值，而最左/最右的红像素在边的中段、离圆角很远，所以量出来就是图片的真实边界。
/// （早先用「深色或饱和」取外接矩形是错的：卡片标题的黑字也算深色，会把文字圈进来。）
///
/// 夹具比例取 **400×570（≈0.702）** 与 **400×533（0.750）**：本机 Jellyfin 库里
/// 26 部剧集就是 0.667 / 0.70 / 0.75 三种混着——**没有统一比例**，所以盒子必须跟着
/// 图走（这正是这次修复的核心；隔壁 Rex 是固定框 + 裁切，实测它的卡恒为 0.688）。
@MainActor
final class ArtworkScalingTests: XCTestCase {
    /// 海报卡盒子宽：紧凑网格的列宽（402pt 手机）。
    private let boxWidth: CGFloat = 113
    private let renderScale: CGFloat = 2

    // MARK: - 贴死

    /// 主流比例（0.702，本机 22/26 部）：盒子按它排，图片四边贴死——不裁、不留边。
    func testCommonPosterRatioFillsBoxExactly() async throws {
        try await assertHugs(pixelSize: CGSize(width: 400, height: 570))
    }

    /// 宽海报（0.750，阿松 / Re:0 那种）：同样贴死。这条特意挑与 2:3 差得远的比例
    /// ——写死 2:3 时它会被裁掉 5.6% 宽度（用户最早报的问题）。
    func testWidePosterRatioFillsBoxExactly() async throws {
        try await assertHugs(pixelSize: CGSize(width: 400, height: 533))
    }

    /// 教科书 2:3（0.667）：也要贴死。
    func testTwoThirdPosterRatioFillsBoxExactly() async throws {
        try await assertHugs(pixelSize: CGSize(width: 400, height: 600))
    }

    /// 剧照 16:9：统一比例，与旧行为逐像素一致。
    func testStillRatioFillsBoxExactly() async throws {
        let pixelSize = CGSize(width: 640, height: 360)
        let width: CGFloat = 240
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        let budget = ArtworkMetrics.pixelBudget(boxWidth: width, heightRatio: 9.0 / 16.0, scale: renderScale)
        _ = try await pipeline.load(url, authHeader: nil, maxPixelSize: budget)

        let geometry = try renderAndMeasure(
            pipeline: pipeline, url: url, width: width, shape: .still,
            aspectRatio: CGFloat(pixelSize.width / pixelSize.height)
        )
        XCTAssertEqual(geometry.width, width * renderScale, accuracy: 2, "宽度应贴死边框")
        XCTAssertEqual(geometry.height, width * 9 / 16 * renderScale, accuracy: 2, "高度应贴死边框")
        XCTAssertTrue(geometry.hasRedOnAllFourEdges)
    }

    /// 反向验证：**把盒子比例喂错**（＝旧代码写死的 2:3）时，0.702 的图必然对不上盒子
    /// ——上下露灰边、高度明显小于盒子。这条证明上面「贴死」的断言不是恒真。
    func testWrongBoxRatioLeavesGapWhichProvesTheAssertionWorks() async throws {
        let pixelSize = CGSize(width: 400, height: 570)
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        let budget = ArtworkMetrics.pixelBudget(boxWidth: boxWidth, heightRatio: 1.5, scale: renderScale)
        _ = try await pipeline.load(url, authHeader: nil, maxPixelSize: budget)

        let geometry = try renderAndMeasure(
            pipeline: pipeline, url: url, width: boxWidth, shape: .poster,
            aspectRatio: 2.0 / 3.0          // 旧行为：写死 2:3
        )
        let boxHeight = boxWidth / (2.0 / 3.0) * renderScale
        XCTAssertTrue(geometry.hasRedOnAllFourEdges, "错比例只该留边，不该裁（.fit 的语义）")
        XCTAssertGreaterThan(
            boxHeight - geometry.height, 6,
            "旧行为必须让 0.702 的图上下各留出灰边——这正是用户看到的「上下空出一截」"
        )
    }

    // MARK: - 横版（剧照 / 库卡）：16:9 资产不能被挤变形

    /// **横版回归**：剧照卡拿到 16:9 的图（本机实测：`继续观看` / `接下来看` / 媒体库封面
    /// 的资产全是 1.7778）时，必须原样铺满 16:9 的框——不出灰条。
    ///
    /// 这条是上一版引入的缺陷的回归：框比例当时被夹在 `0.45…1.6`，而 16:9＝1.7778
    /// **超出上界被夹成 1.6**，于是 16:9 的图在 1.6 的框里 `.fit` → 上下各留一条灰边
    /// （用户报「横着的那些有问题」）。夹取本来是防脏数据的，却把正常画幅也切了。
    func testLandscapeStillFillsSixteenByNineBoxWithoutBars() async throws {
        let pixelSize = CGSize(width: 640, height: 360)          // 1.7778
        let width: CGFloat = 240
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        let budget = ArtworkMetrics.pixelBudget(boxWidth: width, heightRatio: 9.0 / 16.0, scale: renderScale)
        _ = try await pipeline.load(url, authHeader: nil, maxPixelSize: budget)

        // 剧照卡不传比例（与 `StillCard` / `LibraryCard` 的真实调用一致）：框是固定的
        // 16:9，铺法 `.fill`——图片比例与框一致，所以既不裁、也不留边。
        let geometry = try renderAndMeasure(
            pipeline: pipeline, url: url, width: width, shape: .still, aspectRatio: nil
        )

        XCTAssertTrue(geometry.hasRedOnAllFourEdges, "横版图四条边都该在——缺一条就是被裁了")
        XCTAssertEqual(geometry.width, width * renderScale, accuracy: 2, "宽度应贴死边框")
        XCTAssertEqual(geometry.height, width * 9 / 16 * renderScale, accuracy: 2,
                       "高度应贴死 16:9 边框")
        XCTAssertEqual(
            geometry.greenPixels, 0,
            "框里不该露出绿底——露了就说明图片没铺满、上下留了灰条（用户报的就是这个）"
        )
    }

    /// 库卡同样：16:9 封面铺满 16:9 框。
    func testLandscapeLibraryCardFillsItsBox() async throws {
        let pixelSize = CGSize(width: 720, height: 405)          // 1.7778
        let width: CGFloat = 328
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        let budget = ArtworkMetrics.pixelBudget(boxWidth: width, heightRatio: 9.0 / 16.0, scale: renderScale)
        _ = try await pipeline.load(url, authHeader: nil, maxPixelSize: budget)

        let geometry = try renderAndMeasure(
            pipeline: pipeline, url: url, width: width, shape: .still, aspectRatio: nil
        )
        XCTAssertEqual(geometry.height, width * 9 / 16 * renderScale, accuracy: 2)
        XCTAssertEqual(geometry.greenPixels, 0, "库卡封面也不该留边")
    }

    /// **海报卡遇到横版图**（服务端偶尔给出横版海报）：也不许挤变形、不许留白边
    /// ——框按图片走，比例多宽就多宽。
    func testLandscapeSourceInPosterCardDoesNotDistort() async throws {
        let pixelSize = CGSize(width: 640, height: 360)          // 1.7778
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        let budget = ArtworkMetrics.pixelBudget(boxWidth: boxWidth, heightRatio: 1.5, scale: renderScale)
        _ = try await pipeline.load(url, authHeader: nil, maxPixelSize: budget)

        let geometry = try renderAndMeasure(
            pipeline: pipeline, url: url, width: boxWidth, shape: .poster, aspectRatio: 16.0 / 9.0
        )
        XCTAssertTrue(geometry.hasRedOnAllFourEdges, "横版海报也不该被裁")
        XCTAssertEqual(geometry.width, boxWidth * renderScale, accuracy: 2)
        XCTAssertEqual(
            geometry.height, boxWidth / (16.0 / 9.0) * renderScale, accuracy: 2,
            "框高应按图片自己的 16:9 算——被夹取就会挤出灰条"
        )
        XCTAssertEqual(geometry.greenPixels, 0, "横版海报同样不许留边")
    }

    /// **兜底比例**（`nominalRatio`）：来源本身有固定惯例时（TMDb / bgm.tv 的海报都是
    /// 2:3），调用点给一个兜底比例，**加载前那一帧**也严丝合缝——不留边、不裁切。
    ///
    /// 不传这个参数时用的是通用兜底（0.70，Jellyfin 库的多数派），对 2:3 的 TMDb 海报
    /// 会多裁约 5%——那正是加这个参数的起因。
    func testNominalRatioMakesPreloadFrameFitExactly() async throws {
        let pixelSize = CGSize(width: 400, height: 600)          // 2:3
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        // 预热内存缓存（键要与 `MediaArtwork` 内部算的一致才会同步出图）。
        // 然后**不传 aspectRatio**：模拟「来源没有比例字段」的 TMDb / Bangumi 卡片，
        // 那一帧就只能靠 `nominalRatio` 排。
        _ = try await pipeline.load(
            url, authHeader: nil,
            maxPixelSize: ArtworkMetrics.pixelBudget(
                boxWidth: boxWidth, heightRatio: 1.5, scale: renderScale)
        )
        let view = MediaArtwork(
            url: url,
            shape: .poster,
            width: boxWidth,
            nominalRatio: 2.0 / 3.0,
            pipeline: pipeline
        )
        .background(Color.green)
        .environment(\.displayScale, renderScale)

        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        let scanner = try ArtworkScanner(image: XCTUnwrap(renderer.cgImage))
        let geometry = try XCTUnwrap(scanner.redBox(), "整页没有红框")
        var measured = geometry
        measured.greenPixels = scanner.greenPixelCount()

        XCTAssertEqual(measured.height, boxWidth * 1.5 * renderScale, accuracy: 2,
                       "兜底 2:3 的框高应是 宽×1.5")
        XCTAssertEqual(measured.greenPixels, 0, "兜底比例对得上时也不该留边")
    }

    // MARK: - 解码预算

    /// 解码预算按**盒子实际显示尺寸 × 屏幕缩放**算，不是写死的数字。
    /// 3x 手机上 113pt 的海报卡要 509px；原来写死 400，每张都被放大 27%。
    func testPixelBudgetFollowsDisplaySize() {
        // 海报：长边是高（113 × 1.5 × 3 = 508.5 → 509）。
        XCTAssertEqual(ArtworkMetrics.pixelBudget(boxWidth: 113, heightRatio: 1.5, scale: 3), 509)
        // 剧照：长边是宽（240 × 3 = 720）。
        XCTAssertEqual(ArtworkMetrics.pixelBudget(boxWidth: 240, heightRatio: 9.0 / 16.0, scale: 3), 720)
        // 同一张卡在 2x 屏上要的像素低一档。
        XCTAssertEqual(ArtworkMetrics.pixelBudget(boxWidth: 113, heightRatio: 1.5, scale: 2), 339)
        // 卡越大解码越大——这就是「按显示大小适配」。
        XCTAssertGreaterThan(
            ArtworkMetrics.pixelBudget(boxWidth: 178, heightRatio: 1.5, scale: 3),
            ArtworkMetrics.pixelBudget(boxWidth: 113, heightRatio: 1.5, scale: 3)
        )
    }

    // MARK: - 夹具

    /// 「图片四边贴死盒子」的完整断言：红框四条边都在，且图片范围＝盒子范围。
    private func assertHugs(
        pixelSize: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let ratio = CGFloat(pixelSize.width / pixelSize.height)
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let url = makeURL()
        // 预算必须与 `MediaArtwork` 内部算的**完全一致**才会命中内存缓存
        // （`RemoteImage.init` 只在显式传管道时同步出图；键含 maxPixelSize）。
        // 锚点用画幅的名义比例——刻意不跟图片真实比例走，否则同一张图在比例校正前后
        // 会算出两个键、白下一遍（见 `MediaArtwork` 的类型注释）。
        let budget = ArtworkMetrics.pixelBudget(boxWidth: boxWidth, heightRatio: 1.5, scale: renderScale)
        _ = try await pipeline.load(url, authHeader: nil, maxPixelSize: budget)

        let geometry = try renderAndMeasure(
            pipeline: pipeline, url: url, width: boxWidth, shape: .poster, aspectRatio: ratio
        )

        XCTAssertTrue(
            geometry.hasRedOnAllFourEdges,
            "\(Int(pixelSize.width))×\(Int(pixelSize.height)) 的四条边红框必须都在——缺一条就是被裁了",
            file: file, line: line
        )
        XCTAssertEqual(
            geometry.width, boxWidth * renderScale, accuracy: 2,
            "宽度应贴死边框（图片范围 \(geometry.width)px）", file: file, line: line
        )
        XCTAssertEqual(
            geometry.height, boxWidth / ratio * renderScale, accuracy: 2,
            "高度应贴死边框（盒子 \(boxWidth / ratio * renderScale)px，图片 \(geometry.height)px）",
            file: file, line: line
        )
    }

    private func renderAndMeasure(
        pipeline: ImagePipeline,
        url: URL,
        width: CGFloat,
        shape: MediaArtwork<EmptyView>.Shape,
        aspectRatio: CGFloat?
    ) throws -> ArtworkGeometry {
        let view = MediaArtwork(
            url: url,
            shape: shape,
            width: width,
            aspectRatio: aspectRatio,
            pipeline: pipeline
        )
        // **绿底**：图片盖住的地方看不到绿，空隙（＝留边）才露绿。见 `greenPixelCount()`。
        .background(Color.green)
        .environment(\.displayScale, renderScale)

        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出位图")
        let scanner = try ArtworkScanner(image: image)
        var geometry = try XCTUnwrap(scanner.redBox(), "整页没有红框——图片没渲染出来？")
        geometry.greenPixels = scanner.greenPixelCount()
        return geometry
    }

    private func makePipeline(pixelSize: CGSize) throws -> ImagePipeline {
        let bytes = Self.syntheticBorderedPNG(size: pixelSize)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkScaling-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        ArtworkProtocol.handler = { _ in (200, bytes) }
        return ImagePipeline(cacheDirectory: dir, protocolClasses: [ArtworkProtocol.self])
    }

    private func makeURL() -> URL {
        URL(string: "http://artwork.test/\(UUID().uuidString)/poster.png")!
    }

    /// 合成「海报」：深底 + 四边 8px 红框。
    ///
    /// 红框是**证人**（贴着四条边，裁哪条哪条就量不到红）；深底则让「图片」在渲染结果里
    /// 与占位灰区分开（占位是中性灰，既没有饱和色也不够暗）。
    private static func syntheticBorderedPNG(size: CGSize) -> Data {
        let width = Int(size.width), height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let border: CGFloat = 8
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: border))
        context.fill(CGRect(x: 0, y: size.height - border, width: size.width, height: border))
        context.fill(CGRect(x: 0, y: 0, width: border, height: size.height))
        context.fill(CGRect(x: size.width - border, y: 0, width: border, height: size.height))

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("合成图编码失败")
        }
        return data as Data
    }
}

// MARK: - 位图量尺

/// 量红框（＝图片边界）。
///
/// 用**红框像素的外接矩形**而不是「深色或饱和」：卡片标题的黑字也算深色，认深会把标题
/// 圈进来（第一版就把 0.702 量成了 0.88）。圆角会削掉四角，但外接矩形取的是整片红像素
/// 的极值，最左/最右的红像素在边的中段、离圆角很远，量出来就是图片真实边界。
struct ArtworkScanner {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ArtworkScannerError.noContext }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    enum ArtworkScannerError: Error { case noContext }

    /// 红框：R 明显高于 G、B。
    func isRed(x: Int, y: Int) -> Bool {
        let i = (y * width + x) * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        return r > 90 && r > g + 50 && r > b + 50
    }

    /// 绿色像素个数。用例给图区垫一块**绿底**（`.background(Color.green)`）：
    /// 图片盖住的地方看不到绿，**只有空隙（留边）才露绿**。这是唯一能测出「留边」的
    /// 办法——只量图片外接矩形的话，留边和贴死量出来一模一样（图片永远保持自己的比例，
    /// 挤变形的是框，不是图）。
    ///
    /// **排除四角**：卡片有 10pt 圆角，圆角外那块本来就看得到垫底色（那是设计的一部分，
    /// 不是留边）。实测 240×135 的卡四角加起来正好 ≈320px(@2x)，与「留边」是两回事。
    func greenPixelCount(excludingCornerMargin margin: Int = 26) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let nearVerticalEdge = x < margin || x >= width - margin
                let nearHorizontalEdge = y < margin || y >= height - margin
                if nearVerticalEdge && nearHorizontalEdge { continue }
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if g > 140, g > r + 60, g > b + 60 { count += 1 }
            }
        }
        return count
    }

    /// 红框的外接矩形＝图片范围；整页没有红像素时返回 nil。
    func redBox() -> ArtworkGeometry? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where isRed(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 探针往里 1px：图被缩得很小时 8px 的红框只剩 2–3px，往内 4px 就落到深底上、
        // 误判成「边被裁了」。外接矩形本身是紧贴红像素的，+1px 必然还在框内。
        let inset = 1
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        return ArtworkGeometry(
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1),
            hasRedOnLeftEdge: isRed(x: minX + inset, y: midY),
            hasRedOnRightEdge: isRed(x: maxX - inset, y: midY),
            hasRedOnTopEdge: isRed(x: midX, y: minY + inset),
            hasRedOnBottomEdge: isRed(x: midX, y: maxY - inset)
        )
    }
}

/// 一次测量的结果：图片画出来的像素尺寸 + 四条边上是否还有红框。
struct ArtworkGeometry {
    let width: CGFloat
    let height: CGFloat
    /// 垫在图片后面的绿底露出来的像素数：> 0 就是**留了边**（图片没铺满框）。
    var greenPixels: Int = 0
    let hasRedOnLeftEdge: Bool
    let hasRedOnRightEdge: Bool
    let hasRedOnTopEdge: Bool
    let hasRedOnBottomEdge: Bool

    var hasRedOnAllFourEdges: Bool {
        hasRedOnLeftEdge && hasRedOnRightEdge && hasRedOnTopEdge && hasRedOnBottomEdge
    }
}

// MARK: - 网络桩

/// 只服务一张合成图；把真实网络挡掉，用例因此完全离线。
final class ArtworkProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
