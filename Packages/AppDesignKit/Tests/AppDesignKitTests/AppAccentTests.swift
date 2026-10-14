import SwiftUI
import XCTest

@testable import AppDesignKit

/// 中性强调色 `AppAccent` 的**可读性**回归。
///
/// 守的是一个真实踩过的坑：环境 tint 钉成 `.primary` 之后，`.borderedProminent`
/// 与自绘的 `.fill(Color.accentColor)` 填充会变 `.primary`，而**系统不会**把标签换成
/// 反色——整颗按钮变成「白底白字」，文字看不见（模拟器实拍：一颗纯白胶囊）。
/// 修法是所有实底强调显式点名 `AppAccent.onSolid`（反色）。
///
/// 这条用例用 `ImageRenderer` 真渲染「实底 + 反色字」，在深 / 浅两种外观下量
/// **文字与底的对比度**：只要有人把 `onSolid` 去掉、或把它改回跟 `solid` 同向，
/// 对比度会掉到 1:1 附近，立刻失败。判据用 WCAG 的 4.5:1（正文级）。
@MainActor
final class AppAccentTests: XCTestCase {

    // MARK: - 渲染

    /// 「实底主行动」的最小复刻：`AppAccent.solid` 底 + `AppAccent.onSolid` 字。
    private func render(_ scheme: ColorScheme) -> CGImage? {
        let content = ZStack {
            AppAccent.solid
            Text("继续播放")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppAccent.onSolid)
        }
        .frame(width: 220, height: 52)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.cgImage
    }

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

    // MARK: - 判据

    /// 相对亮度（WCAG 2.x，sRGB 反伽马后加权）。
    private func relativeLuminance(_ r: Int, _ g: Int, _ b: Int) -> Double {
        func linear(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.039_28 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
        let la = relativeLuminance(a.0, a.1, a.2)
        let lb = relativeLuminance(b.0, b.1, b.2)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 返回（出现最多的颜色 = 底，与其对比度最高的常见颜色 = 文字，对比度）。
    /// 少见颜色当抗锯齿边缘丢掉，避免拿一个过渡像素当"文字色"。
    private func fillAndInk(_ buffer: [UInt8], minCount: Int = 30)
        -> (fill: (Int, Int, Int), ink: (Int, Int, Int), ratio: Double) {
        var histogram: [Int: Int] = [:]
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let key = (Int(buffer[index]) << 16) | (Int(buffer[index + 1]) << 8) | Int(buffer[index + 2])
            histogram[key, default: 0] += 1
        }
        func rgb(_ key: Int) -> (Int, Int, Int) {
            ((key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF)
        }
        let fillKey = histogram.max { $0.value < $1.value }?.key ?? 0
        let fill = rgb(fillKey)
        var best = fill, bestRatio = 1.0
        for (key, count) in histogram where count >= minCount {
            let candidate = rgb(key)
            let ratio = contrast(fill, candidate)
            if ratio > bestRatio { best = candidate; bestRatio = ratio }
        }
        return (fill, best, bestRatio)
    }

    // MARK: - 用例

    /// 深色：底应近白、字应近黑，对比度 ≥ 4.5:1。
    func testSolidRecipeIsReadableInDarkMode() throws {
        let buffer = try pixels(of: XCTUnwrap(render(.dark)))
        let measured = fillAndInk(buffer)
        XCTAssertGreaterThanOrEqual(
            measured.ratio, 4.5,
            "深色下实底与文字对比度只有 \(String(format: "%.2f", measured.ratio)):1"
                + "（底 \(measured.fill)、字 \(measured.ink)）——实底强调忘了点名反色字？"
        )
    }

    /// 浅色：底应近黑、字应近白，对比度 ≥ 4.5:1。
    func testSolidRecipeIsReadableInLightMode() throws {
        let buffer = try pixels(of: XCTUnwrap(render(.light)))
        let measured = fillAndInk(buffer)
        XCTAssertGreaterThanOrEqual(
            measured.ratio, 4.5,
            "浅色下实底与文字对比度只有 \(String(format: "%.2f", measured.ratio)):1"
                + "（底 \(measured.fill)、字 \(measured.ink)）——实底强调忘了点名反色字？"
        )
    }

    /// 两种外观下底色必须**相反**：否则 `onSolid` 反色这一层就失去意义
    /// （例如把 `solid` 写死成 `Color.white`，深色下会重新变成白底白字）。
    func testSolidFlipsWithColorScheme() throws {
        let dark = fillAndInk(try pixels(of: XCTUnwrap(render(.dark)))).fill
        let light = fillAndInk(try pixels(of: XCTUnwrap(render(.light)))).fill
        let darkLuma = relativeLuminance(dark.0, dark.1, dark.2)
        let lightLuma = relativeLuminance(light.0, light.1, light.2)
        XCTAssertGreaterThan(darkLuma, 0.5, "深色模式的实底应当是亮的")
        XCTAssertLessThan(lightLuma, 0.5, "浅色模式的实底应当是暗的")
    }
}
