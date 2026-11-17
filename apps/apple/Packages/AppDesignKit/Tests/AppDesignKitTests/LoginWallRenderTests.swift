import SwiftUI
import XCTest
@testable import AppDesignKit

/// 海报墙的**渲染**回归：把墙真渲染成位图，再从像素里量。
///
/// ## 为什么量像素而不是断言常量
///
/// 这面墙的承诺是「看得出来是一面海报墙，而且随指针倾斜」，两者都不是 token 值：
/// 前者取决于布局、程序化封面与遮罩叠出来的最终亮度分布；后者取决于
/// `rotation3DEffect` 真的作用在了墙上。断言 `tiltDegrees == 12` 挡不住
/// 「角度还在、效果没了」这类回归（比如透视参数被改成 0）。
///
/// ## 覆盖范围与限制
///
/// `ImageRenderer` 是**单帧同步**渲染，不会跑 `.task`，所以**真海报不会出现在这里**
/// ——画面里是程序化封面。这恰好让这个测试变得确定：它量的是布局 + 程序化封面 +
/// 遮罩 + 倾斜，而那正是墙的骨架。真海报的取图路径由
/// `LoginWallPosterSourceTests` 覆盖。
@MainActor
final class LoginWallRenderTests: XCTestCase {

    private let size = CGSize(width: 900, height: 600)

    private var catalog: [LoginWallPoster] {
        (0..<40).map { index in
            LoginWallPoster(id: "p-\(index)", art: LoginWallArt.make(seed: UInt64(index) &* 2_654_435_761))
        }
    }

    /// 渲染「底色 + 墙 + 遮罩」。刻意**不含** `LoginWallAtmosphereView` /
    /// `LoginWallFilmGrainView`：前者是叠加色晕、后者是平铺噪点，两者都会盖住
    /// 这里要量的明暗结构（而且它们各自都是装饰，没有可回归的几何）。
    private func render(pointer: CGPoint, motionEnabled: Bool = true) -> CGImage? {
        let content = ZStack {
            LoginWallStyle.backdrop(for: .dark)
            LoginWallView(catalog: catalog, pointer: pointer, motionEnabled: motionEnabled)
            LoginWallScrimView()
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// 像素缓冲（RGBA8）。
    private func pixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 亮度极差。纯色画面 = 0；有海报（明暗交错的 tile）就显著大于 0。
    private func lumaRange(_ buffer: [UInt8]) -> Int {
        var low = 255
        var high = 0
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let luma = (Int(buffer[index]) * 299 + Int(buffer[index + 1]) * 587 + Int(buffer[index + 2]) * 114) / 1000
            low = min(low, luma)
            high = max(high, luma)
        }
        return high - low
    }

    /// `PlatformImage` → `CGImage`（两端 API 不同，测试要跨平台）。
    private func cgImage(of image: PlatformImage) throws -> CGImage {
        #if canImport(UIKit)
        return try XCTUnwrap(image.cgImage)
        #else
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #endif
    }

    private func changedPixelRatio(_ a: [UInt8], _ b: [UInt8], threshold: Int = 6) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var changed = 0
        var total = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            total += 1
            let delta = abs(Int(a[index]) - Int(b[index]))
                + abs(Int(a[index + 1]) - Int(b[index + 1]))
                + abs(Int(a[index + 2]) - Int(b[index + 2]))
            if delta > threshold { changed += 1 }
        }
        return total > 0 ? Double(changed) / Double(total) : 0
    }

    // MARK: 画出来了

    /// 墙真的画出来了：画面有明显的明暗结构，而不是一片底色。
    ///
    /// 这条挡的是最难看的一种失败——布局或封面出了问题时，整页退化成一块纯色，
    /// 而代码「没有报错」。
    func testWallRendersVisiblePosterStructure() throws {
        let image = try XCTUnwrap(render(pointer: .zero))
        XCTAssertEqual(image.width, Int(size.width))
        XCTAssertEqual(image.height, Int(size.height))

        let range = lumaRange(try pixels(of: image))
        XCTAssertGreaterThan(range, 40, "整页亮度极差只有 \(range)：墙没画出来（退化成纯色了）")
    }

    /// 空库（首次装配的那一瞬）不该崩，画面仍是底色 + 遮罩。
    func testEmptyCatalogRendersBackdropOnly() throws {
        let content = ZStack {
            LoginWallStyle.backdrop(for: .dark)
            LoginWallView(catalog: [], pointer: .zero, motionEnabled: true)
            LoginWallScrimView()
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, Int(size.width))
    }

    // MARK: 倾斜

    /// **指针真的在倾斜这面墙**：同一面墙、两个指针位置，画面必须不同。
    ///
    /// 这是「鼠标移动 → 墙跟着倾斜」这条交互唯一可离线验证的一半（渲染路径）。
    /// 输入路径（`NSTrackingArea`）需要真实鼠标，见 `LoginWallPointerTracker`。
    func testPointerTiltChangesRenderedPixels() throws {
        let centered = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: 0, y: 0))))
        let corner = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: -0.9, y: -0.9))))

        let ratio = changedPixelRatio(centered, corner)
        XCTAssertGreaterThan(ratio, 0.10, "指针移动后只有 \(Int(ratio * 100))% 的像素变化：倾斜没生效")
    }

    /// 两个不同的指针位置给出**不同**的结果（不是所有位置都塌到同一个姿态）。
    func testDistinctPointerPositionsRenderDistinctly() throws {
        let left = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: -0.9, y: 0))))
        let right = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: 0.9, y: 0))))

        let ratio = changedPixelRatio(left, right)
        XCTAssertGreaterThan(ratio, 0.05, "左右两个指针位置渲染结果几乎一样（\(Int(ratio * 100))%）")
    }

    /// **关掉动效时墙必须完全静止**：`motionEnabled: false` 下两个指针位置渲染出的
    /// 位图要逐像素相同。
    ///
    /// 这条对应「减弱动态效果」无障碍设置：那条路径一旦漏了，用户开着减动效仍然会
    /// 看到整页在动。
    func testMotionDisabledFreezesTheWall() throws {
        let a = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: 0, y: 0), motionEnabled: false)))
        let b = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: 0.9, y: -0.9), motionEnabled: false)))
        XCTAssertEqual(changedPixelRatio(a, b), 0, "关掉动效后墙仍在随指针变化")
    }

    // MARK: 合成图（一张图那条路径）

    /// **整面墙真的能合成成一张不空的位图**，而且尺寸就是墙画布的点尺寸 × scale。
    ///
    /// 这条挡的是「合成失败但没人发现」：`ImageRenderer` 出图失败时返回 nil，
    /// 线上表现为墙退化成一片底色，而代码不会报错。
    func testRasterizerProducesOneImageCoveringTheWholeCanvas() async throws {
        let layout = LoginWallLayout(size: size, catalogSize: catalog.count)
        let produced = await LoginWallRasterizer.raster(
            catalog: catalog, layout: layout, scale: 1, backdrop: .black
        )
        let image = try XCTUnwrap(produced, "合成图没画出来")

        let cg = try cgImage(of: image)
        XCTAssertEqual(cg.width, Int(layout.totalWidth.rounded()))
        XCTAssertEqual(cg.height, Int(layout.totalHeight.rounded()))

        // 画布上必须有明暗结构，不能是一块纯色。
        let range = lumaRange(try pixels(of: cg))
        XCTAssertGreaterThan(range, 40, "合成图亮度极差只有 \(range)：合成出来的是一块纯色")
    }

    /// 合成图的**长边**受像素预算约束：大窗口不能悄悄生成一张几千万像素的图。
    func testRasterizerClampsPixelBudget() async throws {
        let big = LoginWallLayout(size: CGSize(width: 2560, height: 1440), catalogSize: catalog.count)
        let produced = await LoginWallRasterizer.raster(
            catalog: catalog, layout: big, scale: 4, backdrop: .black
        )
        let image = try XCTUnwrap(produced)
        let cg = try cgImage(of: image)
        XCTAssertLessThanOrEqual(
            max(cg.width, cg.height),
            Int(LoginWallRasterizer.maximumPixelExtent),
            "合成图长边超出了像素预算"
        )
    }

    /// 空库不合成——没有素材时应该直接走兜底，而不是画一张空图。
    func testRasterizerReturnsNilForEmptyCatalog() async {
        let layout = LoginWallLayout(size: size, catalogSize: 0)
        let image = await LoginWallRasterizer.raster(
            catalog: [], layout: layout, scale: 1, backdrop: .black
        )
        XCTAssertNil(image)
    }

    // MARK: 确定性

    /// 同一输入两次渲染逐像素相同。抖动/封面都是位置与种子的纯函数，渲染必须可复现
    /// ——否则这个测试文件里其它「像素比」断言本身就是不稳的。
    func testRenderIsDeterministic() throws {
        let a = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: 0.3, y: -0.2))))
        let b = try pixels(of: XCTUnwrap(render(pointer: CGPoint(x: 0.3, y: -0.2))))
        XCTAssertEqual(changedPixelRatio(a, b), 0, "同一输入的两次渲染不一致，像素断言不可信")
    }
}
