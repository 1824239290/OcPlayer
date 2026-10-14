import AppDesignKit
import SwiftUI
import XCTest
@testable import OcPlayer

/// 顶栏药丸里「首页」那一格的头像图标（`SectionAvatarIcon`）。
///
/// 守的是一条**量出来**的口径：药丸的选中信号本来只有前景色亮暗，而位图不吃
/// `foregroundStyle`，所以头像那一格改用**灰化**（选中原色 / 未选中灰）。这条用例
/// 用 `ImageRenderer` 真渲染两种状态，量像素：
///
/// * 选中：饱和度必须与源图同一量级（别把信号做没了）；
/// * 未选中：饱和度必须≈0（灰化真的生效）；
/// * 两种状态都必须是**圆**（四角透明）—— 药丸槽位是方的，裁圆只能在这一层做。
///
/// ## 为什么是 `.grayscale` 而不是 `.saturation(0)`
///
/// 两者观感等价（都把饱和度整条抽掉），但实测（macOS 26 / `ImageRenderer`）：
/// **`.saturation()` 在 `ImageRenderer` 里不生效** —— 纯色矩形与位图加与不加逐值
/// 相同（0.897 vs 0.897、0.762 vs 0.762），而 `.grayscale(1)` 生效（0.762 → 0.000）。
/// 这一格的选中信号只有这一条，必须能被用例钉住，所以取 `.grayscale`。
///
/// ## 为什么不用「压暗 / 降不透明」
///
/// 头像亮度由图片内容决定，不由 App 决定：本机真实头像平均明度 209/255（偏亮），
/// 压在浅色玻璃上 `opacity(0.55)` 只剩 Δ20/255，而相邻 glyph 的 primary↔secondary
/// 是 Δ120/255（深色 96）。走这条路浅色模式下几乎看不出来（理由见
/// `SectionAvatarIcon` 的注释）。
@MainActor
final class SectionAvatarIconTests: XCTestCase {

    private static let side: CGFloat = 18

    /// 一张饱和度拉满的合成头像（纯色方块即可 —— 要量的是「有没有被灰化」）。
    private static func saturatedImage() -> PlatformImage {
        let width = 64, height = 64
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.95, green: 0.10, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #endif
    }

    /// 渲染一格。刻意**不**加不透明底色：裁圆是这一格的硬要求（槽位是方的），
    /// 加了底色四角就不再透明，那条断言也就失去意义。
    private func render(isSelected: Bool, padding: CGFloat = 4) -> CGImage? {
        let content = SectionAvatarIcon(image: Self.saturatedImage(), isSelected: isSelected)
            .padding(padding)
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

    /// 平均饱和度（0…1，只统计不透明像素）。
    private func meanSaturation(_ image: CGImage) throws -> Double {
        let (rgba, _, _) = pixels(of: image)
        var total = 0.0
        var count = 0
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 200 {
            let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            total += maxC == 0 ? 0 : (maxC - minC) / maxC
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "渲染出来一个不透明像素都没有？")
        return total / Double(count)
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> Double {
        let (rgba, width, height) = pixels(of: image)
        let row = height - 1 - y
        return Double(rgba[(row * width + x) * 4 + 3]) / 255
    }

    // MARK: - 用例

    /// 选中：饱和度保住（源图是纯洋红，饱和度 ≈ 0.89）。
    func testSelectedKeepsSaturation() throws {
        let saturation = try meanSaturation(try XCTUnwrap(render(isSelected: true)))
        XCTAssertGreaterThan(saturation, 0.7, "选中态必须是原色，饱和度不能被做没")
    }

    /// 未选中：灰化到位（饱和度 ≈ 0）。
    func testUnselectedIsDesaturated() throws {
        let saturation = try meanSaturation(try XCTUnwrap(render(isSelected: false)))
        XCTAssertLessThan(saturation, 0.05, "未选中必须灰化——这就是这一格的选中信号")
    }

    /// 两种状态都必须是圆：四角透明、中心不透明。
    func testBothStatesAreCircular() throws {
        for isSelected in [true, false] {
            let image = try XCTUnwrap(render(isSelected: isSelected))
            let w = image.width, h = image.height
            XCTAssertEqual(alpha(image, x: 1, y: 1), 0, accuracy: 0.02,
                           "左上角必须被裁掉（选中=\(isSelected)）")
            XCTAssertEqual(alpha(image, x: w - 2, y: h - 2), 0, accuracy: 0.02,
                           "右下角必须被裁掉（选中=\(isSelected)）")
            XCTAssertEqual(alpha(image, x: w / 2, y: h / 2), 1, accuracy: 0.02,
                           "中心必须还有图（选中=\(isSelected)）")
        }
    }

    /// 尺寸：18pt —— 量出来的下限（13pt 那档实拍只剩一团粉、认不出人；
    /// 18pt 起才看得出脸，且落在品牌 logo 已有的 18/20pt 档里）。
    func testRendersAtMeasuredSide() throws {
        let image = try XCTUnwrap(render(isSelected: true))
        XCTAssertEqual(Double(image.width), Double(Self.side) + 8, accuracy: 1,
                       "18pt 头像 + 两侧各 4pt padding")
    }
}
