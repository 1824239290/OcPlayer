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
/// 2. **未选中必须真的是模板渲染**（吃父层的 `foregroundStyle`，于是跟随 primary/secondary）。
///
/// ## 未选中态为什么用「探针前景色」而不是「是不是单色」
///
/// 第一版判据是「未选中态的平均通道极差 ≈ 0」，**它漏抓了一种错法**（反向变异实测）：
/// `bangumi-logo.svg` 自带的 `fill` 就是 `#e6e6e6` 浅灰 —— 即使误把渲染模式写成
/// `.original`，画出来依然是「纯灰、极差 0」，用例照样绿。也就是说「是单色」证明不了
/// 「它是被模板染色的」。
///
/// 改用**纯绿探针**：模板渲染的像素必须变成探针色（实测 `(0.00, 0.97, 0.00)`），
/// `.original` 则保持资产自己的颜色（`(0.87, 0.87, 0.87)` / `(0.96, 0.33, 0.61)`）。
/// 这两种结果在绿色通道上差一个量级，判据不可能混淆。生产代码里父层给的就是
/// `.primary` / `.secondary`，探针只是把这个输入换成一个不会和任何品牌色撞车的值。
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

    /// 探针前景色：纯绿。选它是因为两个品牌的颜色（洋红 / 紫）与灰都不在绿通道上占优，
    /// 「模板被染色」与「保持原色」在这条通道上差一个量级，不会误判。
    private static let probeColor = Color(red: 0, green: 1, blue: 0)

    /// 渲染一格。
    ///
    /// - Parameter foreground: 覆盖父层前景色；`nil` = 用默认的 `.primary`
    ///   （生产里父层给的就是 `.primary` / `.secondary`，两者都是中性灰）。
    ///
    /// 刻意**不**加不透明底色：模板图会整块变成前景色，透明底能让「哪些像素是图标」
    /// 用 alpha 精确切开，颜色统计不会被底色稀释。
    private func render(_ brand: Brand, isSelected: Bool, foreground: Color? = nil) -> CGImage? {
        var content = AnyView(SectionBrandIcon(
            name: brand.name,
            colorName: brand.colorName,
            isSelected: isSelected,
            side: brand.side
        ))
        if let foreground {
            content = AnyView(content.foregroundStyle(foreground))
        }
        let renderer = ImageRenderer(content: content.padding(6))
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

    /// 不透明像素（alpha > 200）的统计：像素数、平均通道极差、平均 RGB。
    ///
    /// 极差取**绝对** `max−min` 而不是相对饱和度 `(max−min)/max`：未选中的模板图是
    /// 近黑 / 纯色探针色，抗锯齿边缘那种 `(2,1,2)` 像素在相对口径下会算出 0.5 的「高饱和」
    /// —— 实测 MoviePilot 未选中态的相对饱和度是 **0.16**（明明是全灰的），纯噪声。
    ///
    /// 同时返回 count，供「资产没解析到」的失败消息用（`Image` 渲染失败就是
    /// 0 个不透明像素，`XCTUnwrap` 抓不到）。
    private struct Stats {
        let count: Int
        let meanChannelSpread: Double
        let meanRed: Double
        let meanGreen: Double
        let meanBlue: Double

        /// 与探针色（纯绿）的差：模板渲染 ≈ 0，保持原色则明显 > 0。
        var distanceFromProbe: Double {
            abs(meanRed) + abs(meanGreen - 1) + abs(meanBlue)
        }
    }

    private func stats(of image: CGImage) -> Stats {
        let (rgba, _, _) = pixels(of: image)
        var count = 0
        var spread = 0.0, red = 0.0, green = 0.0, blue = 0.0
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 200 {
            let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
            spread += max(r, g, b) - min(r, g, b)
            red += r; green += g; blue += b
            count += 1
        }
        guard count > 0 else { return Stats(count: 0, meanChannelSpread: 0,
                                            meanRed: 0, meanGreen: 0, meanBlue: 0) }
        let n = Double(count)
        return Stats(count: count, meanChannelSpread: spread / n,
                     meanRed: red / n, meanGreen: green / n, meanBlue: blue / n)
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

    // MARK: - 选中：品牌原色

    /// 选中：Bangumi 的品牌渐变（实测平均通道极差 ≈ 0.63）。
    ///
    /// 不透明像素阈值取 10 而不是 50：20pt 的线稿 glyph 在 scale=1 下只有 39 个
    /// 全不透明像素（其余都是抗锯齿边缘）——这条踩过一次，别按「面积」直觉定阈值。
    func testSelectedBangumiKeepsBrandColor() throws {
        let stats = self.stats(of: try XCTUnwrap(
            render(Self.bangumi, isSelected: true, foreground: Self.probeColor)))
        XCTAssertGreaterThan(stats.count, 10, "Bangumi 资产没画出来（名字写错 / 测试宿主找不到 assets？）")
        XCTAssertGreaterThan(stats.meanChannelSpread, 0.2,
                             "选中态必须是品牌色；一坨灰说明 .original 没覆盖 imageset 的模板意图")
        XCTAssertGreaterThan(stats.distanceFromProbe, 0.5,
                             "选中态不能是探针色：那说明它走了模板渲染（吃了父层前景色）")
    }

    /// 选中：MoviePilot 的彩色渐变存在**同一个** SVG 里（`colorName == name`），
    /// 这条同时证明「同一个资产、只换渲染模式」这条路成立（实测极差 ≈ 0.61）。
    func testSelectedMoviePilotKeepsBrandColor() throws {
        let stats = self.stats(of: try XCTUnwrap(
            render(Self.moviepilot, isSelected: true, foreground: Self.probeColor)))
        XCTAssertGreaterThan(stats.count, 10)
        XCTAssertGreaterThan(stats.meanChannelSpread, 0.2)
        XCTAssertGreaterThan(stats.distanceFromProbe, 0.5,
                             "选中态不能是探针色：那说明它走了模板渲染")
    }

    // MARK: - 未选中：模板渲染（吃父层前景色）

    /// 未选中：必须是**模板渲染** —— 像素变成父层给的前景色（探针纯绿）。
    ///
    /// 这条是「未选中=灰」的真实判据。只断言「是单色」不够：Bangumi 的 SVG 自带
    /// `#e6e6e6` 浅灰，误用 `.original` 时同样单色，反向变异实测漏抓。
    func testUnselectedBangumiTakesForegroundStyle() throws {
        let stats = self.stats(of: try XCTUnwrap(
            render(Self.bangumi, isSelected: false, foreground: Self.probeColor)))
        XCTAssertGreaterThan(stats.count, 10)
        XCTAssertLessThan(stats.distanceFromProbe, 0.1,
                          "未选中必须是模板渲染（像素应变成父层前景色）；"
                          + "实测 count=\(stats.count) rgb=(\(stats.meanRed),\(stats.meanGreen),\(stats.meanBlue))")
    }

    func testUnselectedMoviePilotTakesForegroundStyle() throws {
        let stats = self.stats(of: try XCTUnwrap(
            render(Self.moviepilot, isSelected: false, foreground: Self.probeColor)))
        XCTAssertGreaterThan(stats.count, 10)
        XCTAssertLessThan(stats.distanceFromProbe, 0.1,
                          "未选中必须是模板渲染（像素应变成父层前景色）；"
                          + "实测 count=\(stats.count) rgb=(\(stats.meanRed),\(stats.meanGreen),\(stats.meanBlue))")
    }

    /// 未选中在**生产上下文**（默认 `.primary`）下是单色灰 —— 用户看到的「未选中是灰的」。
    ///
    /// 单独一条、且**不**加探针色：探针是纯绿，通道极差本身就是 1.0，会和「单色」判据
    /// 自相矛盾（第一版把两条断言塞进同一个渲染里，实测报 `0.969 不小于 0.03`）。
    func testUnselectedIsMonochromeUnderProductionForeground() throws {
        for brand in [Self.bangumi, Self.moviepilot] {
            let stats = self.stats(of: try XCTUnwrap(render(brand, isSelected: false)))
            XCTAssertGreaterThan(stats.count, 10)
            XCTAssertLessThan(stats.meanChannelSpread, 0.03,
                              "\(brand.name) 未选中必须是单色（与 SF Symbol 同一套语言）")
        }
    }

    // MARK: - 接线（makeSegments 实际传的资产名）

    /// `makeSegments` 给两个品牌传的**资产名**必须和这里测的一致 —— 否则上面所有用例都绿，
    /// 而 App 里画的仍是单色（反向变异实测：把 Bangumi 的 `colorName` 改回 `bangumi-logo`，
    /// 6 条用例**全绿**，因为它们直接构造 `SectionBrandIcon`，绕过了真实配置）。
    ///
    /// 这条钉的是「配置」而不是「渲染」：它必须和上面两条选中态用例配成一对。
    func testSegmentsWireBrandColorAssets() {
        let segments = AppShellSectionGroup.makeSegments(
            bangumiEnabled: true, moviepilotEnabled: true)

        func brand(for section: AppModel.Section) -> (name: String, colorName: String, side: CGFloat)? {
            guard let segment = segments.first(where: { $0.section == section }),
                  case let .brand(name, colorName, side) = segment.icon
            else { return nil }
            return (name, colorName, side)
        }

        let bangumi = brand(for: .bangumi)
        XCTAssertEqual(bangumi?.name, "bangumi-logo")
        XCTAssertEqual(bangumi?.colorName, "bangumi-logo-color",
                       "Bangumi 的彩色是另一份渐变资产；写回单色资产会让选中态退化成灰")
        XCTAssertEqual(bangumi?.side, 20)

        let moviepilot = brand(for: .moviepilot)
        XCTAssertEqual(moviepilot?.name, "moviepilot-logo")
        XCTAssertEqual(moviepilot?.colorName, "moviepilot-logo",
                       "MoviePilot 的彩色就在同一份 SVG 里（只换渲染模式）")
        XCTAssertEqual(moviepilot?.side, 18)

        // 开关关掉时对应段消失（与侧栏时代一致）。
        let noIntegrations = AppShellSectionGroup.makeSegments(
            bangumiEnabled: false, moviepilotEnabled: false)
        XCTAssertNil(noIntegrations.first { $0.section == .bangumi })
        XCTAssertNil(noIntegrations.first { $0.section == .moviepilot })
    }

    /// 两个品牌资产确实存在且能被 `Image` 解析（名字写错时 `Image` 不报错、只渲染成空）。
    ///
    /// 上一条钉的是「配置里的名字」，这条钉的是「名字指向真资产」——两者缺一，
    /// 改名后都可能静默退化成空白。
    func testBrandAssetsResolve() throws {
        for name in ["bangumi-logo", "bangumi-logo-color", "moviepilot-logo"] {
            #if canImport(AppKit)
            XCTAssertNotNil(NSImage(named: name), "\(name) 资产不存在")
            #elseif canImport(UIKit)
            XCTAssertNotNil(UIImage(named: name), "\(name) 资产不存在")
            #endif
        }
    }

    // MARK: - 几何

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