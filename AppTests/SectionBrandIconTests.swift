import AppDesignKit
import SwiftUI
import XCTest
@testable import OcPlayer

/// 顶栏药丸（macOS）里两个品牌图的选中态渲染（`SectionBrandIcon`）。
///
/// 用户口径（2026-10-22）：Bangumi / MoviePilot 的图标要像首页头像那样 ——
/// **选中时是 SVG 原本的品牌色，未选中时是灰的**。
///
/// 这条口径的实现只有一句 `.renderingMode(isSelected ? .original : .template)`，但它有两个
/// 容易静默失效的前提，所以用 `ImageRenderer` 真渲染量像素把它们钉住：
///
/// 1. **`.original` 真的能覆盖 imageset 的 `template-rendering-intent`**。两个资产都带模板
///    意图（设置页 / 详情页要单色）；如果 `.original` 覆盖不了，选中态会渲染成一坨前景色，
///    观感上「改了跟没改一样」，但编译、截图的几何全对 —— 只有量通道值才看得见。
/// 2. **未选中必须仍然是单色**。模板渲染 + 父层 `.secondary` 是现存语言，不能被这次改动
///    顺手破坏。
///
/// 另外钉住「两态几何一致」：品牌色资产与单色资产是同一 viewBox 的同一 glyph，
/// 选中/未选中切换时图标不能跳尺寸。
///
/// ## 为什么不用 `Image(named:) == nil` 断言资产存在
///
/// `Image` 是不可失败的——资产名写错只会渲染成空。所以判据取**渲染后不透明像素数**
/// （>0 才说明真的画出了东西），这也顺带守住「测试宿主里能解析到 App 的 assets」。
@MainActor
final class SectionBrandIconTests: XCTestCase {

    /// 与 `AppShellSectionGroup.makeSegments` 里标定的边长一致（各 SVG 留白不同）。
    private struct Brand {
        let name: String
        let colorName: String
        let side: CGFloat
    }

    private static let bangumi = Brand(
        name: "bangumi-logo", colorName: "bangumi-logo-color", side: 20
    )
    private static let moviepilot = Brand(
        name: "moviepilot-logo", colorName: "moviepilot-logo", side: 18
    )

    /// 渲染一格。刻意**不**加不透明底色：模板图默认吃 `primary` 前景色（浅色外观下是黑），
    /// 透明底能让「哪些像素是图标」用 alpha 精确切开，饱和度统计不会被底色稀释。
    private func render(_ brand: Brand, isSelected: Bool) -> CGImage? {
        let content = SectionBrandIcon(
            name: brand.name,
            colorName: brand.colorName,
            isSelected: isSelected,
            side: brand.side
        )
        .padding(6)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.cgImage
    }

    private func pixels(of image: CGImage) -> (rgba: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height)
    }

    /// 不透明像素数（alpha > 200）与**平均通道极差**（逐像素 `max−min`，0…1）。
    ///
    /// 为什么不用相对饱和度 `(max−min)/max`：未选中的模板图是**近黑**的，抗锯齿边缘
    /// 那种 `(2,1,2)` 像素在相对口径下会算出 0.5 的「高饱和」——实测 MoviePilot
    /// 未选中态的相对饱和度是 **0.16**（明明是全灰的），纯噪声。绝对极差对低亮度稳定：
    /// 同一批像素实测 0.000 / 0.001，与观感一致。
    ///
    /// 同时返回 count，供「资产没解析到」的失败消息用（`Image` 渲染失败就是
    /// 0 个不透明像素，`XCTUnwrap` 抓不到）。
    private func opaqueStats(_ image: CGImage) -> (count: Int, meanChannelSpread: Double) {
        let (rgba, _, _) = pixels(of: image)
        var totalSpread = 0.0
        var count = 0
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 200 {
            let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
            totalSpread += max(r, g, b) - min(r, g, b)
            count += 1
        }
        return (count, count == 0 ? 0 : totalSpread / Double(count))
    }

    /// 不透明像素的外接框（用来比较两态几何）。
    private func opaqueBoundingBox(_ image: CGImage) -> CGRect? {
        let (rgba, width, height) = pixels(of: image)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - 用例

    /// 选中：品牌原色（Bangumi 是洋红→粉的渐变；实测平均通道极差 ≈ 0.63）。
    ///
    /// 不透明像素阈值取 10 而不是 50：20pt 的线稿 glyph 在 scale=1 下只有 39 个
    /// 全不透明像素（其余都是抗锯齿边缘）——这条踩过一次，别按「面积」直觉定阈值。
    func testSelectedBangumiKeepsBrandColor() throws {
        let stats = opaqueStats(try XCTUnwrap(render(Self.bangumi, isSelected: true)))
        XCTAssertGreaterThan(stats.count, 10, "Bangumi 资产没画出来（名字写错 / 测试宿主找不到 assets？）")
        XCTAssertGreaterThan(stats.meanChannelSpread, 0.2,
                             "选中态必须是品牌色；一坨灰说明 .original 没覆盖 imageset 的模板意图")
    }

    /// 未选中：单色（模板渲染 + 父层前景色），不能残留品牌色。
    func testUnselectedBangumiIsMonochrome() throws {
        let stats = opaqueStats(try XCTUnwrap(render(Self.bangumi, isSelected: false)))
        XCTAssertGreaterThan(stats.count, 10)
        XCTAssertLessThan(stats.meanChannelSpread, 0.03,
                          "未选中必须回到单色（与 SF Symbol 同一套语言）")
    }

    /// 选中：MoviePilot 的彩色渐变存在**同一个** SVG 里（`colorName == name`），
    /// 这条同时证明「同一个资产、只换渲染模式」这条路成立（实测极差 ≈ 0.61）。
    func testSelectedMoviePilotKeepsBrandColor() throws {
        let stats = opaqueStats(try XCTUnwrap(render(Self.moviepilot, isSelected: true)))
        XCTAssertGreaterThan(stats.count, 10)
        XCTAssertGreaterThan(stats.meanChannelSpread, 0.2)
    }

    func testUnselectedMoviePilotIsMonochrome() throws {
        let stats = opaqueStats(try XCTUnwrap(render(Self.moviepilot, isSelected: false)))
        XCTAssertGreaterThan(stats.count, 10)
        XCTAssertLessThan(stats.meanChannelSpread, 0.03)
    }

    /// 两态几何一致：同一 viewBox / 同一 `side`，选中切换不能跳尺寸。
    func testBothStatesShareGeometry() throws {
        for brand in [Self.bangumi, Self.moviepilot] {
            let selected = try XCTUnwrap(opaqueBoundingBox(
                try XCTUnwrap(render(brand, isSelected: true))))
            let unselected = try XCTUnwrap(opaqueBoundingBox(
                try XCTUnwrap(render(brand, isSelected: false))))
            XCTAssertEqual(selected.width, unselected.width, accuracy: 1,
                           "\(brand.name) 选中/未选中宽度不一致")
            XCTAssertEqual(selected.height, unselected.height, accuracy: 1,
                           "\(brand.name) 选中/未选中高度不一致")
        }
    }
}