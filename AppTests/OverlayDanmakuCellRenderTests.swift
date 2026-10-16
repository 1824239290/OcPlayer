#if os(macOS)
import XCTest
import AppKit
import CoreText
import DanmakuKit
@testable import OcPlayer

/// 弹幕 cell 渲染回归：钉住「CoreText `CTLineDraw` 的基线与旧 `NSString.draw(at:)`
/// 的取点逐像素等价」这条换算。
///
/// 背景：macOS 侧把描边从 CoreText 的 `.strokeWidth` 文本效果（每次绘制实时
/// `CTFontCreatePathForGlyph`，实测 237 µs/字形、单条弹幕 2.0 ms）换成
/// 「同一行 CTLine 按圆环偏移画 12 次」。换实现必然要换取点方式——旧的是行盒
/// 左下角、CTLine 要基线——**写错不会让任何既有用例变红，只会整屏弹幕错位**，
/// 所以这里逐像素对照旧路径。
///
/// 本文件只在 macOS 编译：`drawFill`、`NSGraphicsContext` 都是 macOS 侧的东西，
/// 而 iOS 的 `DanmakuAsyncLayer` 走 y-down 翻转上下文，取点约定不同（未验证）。
///
/// `@MainActor`：`DanmakuCell` 是 `NSView` 子类（Swift 6 下 MainActor 隔离），
/// 而模型是非 Sendable 的 class，跨隔离调用会被判为 data race。
@MainActor
final class OverlayDanmakuCellRenderTests: XCTestCase {

    private let fontSize: CGFloat = 22
    private let scale: CGFloat = 2

    // MARK: - 工具

    private func makeContext(width: CGFloat, height: CGFloat) -> CGContext {
        let context = CGContext(
            data: nil,
            width: Int(width * scale),
            height: Int(height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func model(
        text: String = "前方高能预警 233333",
        color: UInt32 = 0xFF3B30,
        size: CGFloat? = nil
    ) -> OverlayDanmakuModel {
        OverlayDanmakuModel(
            comment: DanmakuJSONParser.Entry(time: 12, mode: .scroll, color: color, text: text),
            fontSize: size ?? fontSize
        )
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &buffer,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// 非透明像素数（覆盖率）。
    private func ink(_ image: CGImage) -> Int {
        let buffer = pixels(image)
        var count = 0
        for index in stride(from: 3, to: buffer.count, by: 4) where buffer[index] > 16 { count += 1 }
        return count
    }

    private func differingPixels(_ lhs: CGImage, _ rhs: CGImage) -> Int {
        let a = pixels(lhs)
        let b = pixels(rhs)
        var count = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            let delta = max(
                abs(Int(a[index]) - Int(b[index])),
                max(abs(Int(a[index + 1]) - Int(b[index + 1])), abs(Int(a[index + 2]) - Int(b[index + 2])))
            )
            if delta > 8 { count += 1 }
        }
        return count
    }

    /// 旧路径的填充趟（不带投影），作为逐像素对照基准。
    private func renderLegacyFill(_ model: OverlayDanmakuModel, origin: CGPoint,
                                  width: CGFloat, height: CGFloat) -> CGImage {
        let context = makeContext(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSString(string: model.comment.text).draw(
            at: origin,
            withAttributes: [.font: model.font, .foregroundColor: model.color]
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// 新路径的填充趟，取点换算与生产代码**同一处**（`OverlayDanmakuModel.lines()`）。
    private func renderCTLineFill(_ model: OverlayDanmakuModel, origin: CGPoint,
                                  width: CGFloat, height: CGFloat) -> CGImage {
        let context = makeContext(width: width, height: height)
        let lines = model.lines()
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: origin.x, y: origin.y + lines.baselineOffset)
        CTLineDraw(lines.fill, context)
        context.restoreGState()
        return context.makeImage()!
    }

    // MARK: - 基线换算

    /// **核心用例**：新的 CTLine 填充趟与旧的 `NSString.draw` 填充趟逐像素相同。
    func testCTLineFillIsPixelIdenticalToLegacyFill() throws {
        let model = self.model()
        let width = model.size.width + 12
        let height = model.size.height + 12
        let origin = CGPoint(x: 6, y: 6)

        let legacy = renderLegacyFill(model, origin: origin, width: width, height: height)
        let new = renderCTLineFill(model, origin: origin, width: width, height: height)

        XCTAssertGreaterThan(ink(legacy), 0, "对照组本身没画出东西，用例失效")
        XCTAssertEqual(
            differingPixels(legacy, new), 0,
            "CTLineDraw 的基线与 NSString.draw(at:) 不再逐像素等价——弹幕会整体错位"
        )
    }

    /// 九档字号都等价。
    ///
    /// **这条用例抓到过一个真缺陷**：换算最初写成 `round(descent)`，八档字号都对，
    /// 唯独 16pt 错一个像素（ascent 15.469 / descent 3.375 / 行盒高 19 →
    /// 正确偏移是 `19 − 15 = 4`，而 `round(descent)` 是 3）。现在钉的是
    /// `行盒高 − round(ascent)`。
    func testBaselineFormulaHoldsAcrossFontSizes() throws {
        for size in [12.0, 14, 16, 18, 22, 26, 30, 36, 44] as [CGFloat] {
            let model = self.model(text: "弹幕Danmaku99", color: 0xFFFFFF, size: size)
            let width = model.size.width + 20
            let height = model.size.height + 20
            let origin = CGPoint(x: 10, y: 10)

            let legacy = renderLegacyFill(model, origin: origin, width: width, height: height)
            let new = renderCTLineFill(model, origin: origin, width: width, height: height)
            XCTAssertEqual(differingPixels(legacy, new), 0, "fontSize=\(size)")
        }
    }

    /// 生产代码那处换算也要落在同一个点上（margin 推导的取点 + 偏移）。
    func testProductionBaselineMatchesLegacyOrigin() {
        let model = self.model()
        let lines = model.lines()
        let baseline = OverlayDanmakuCell.baseline(for: model, offset: lines.baselineOffset)
        XCTAssertEqual(baseline.x, model.marginX / 2, accuracy: 0.0001)
        XCTAssertEqual(baseline.y, model.marginY / 2 + lines.baselineOffset, accuracy: 0.0001)
        // 行盒高必须真的来自测量结果（不是随手取的字号倍数），否则偏移会整体漂。
        XCTAssertGreaterThan(model.textLineHeight, 0)
    }

    // MARK: - 描边本身

    /// 描边确实画出来了：完整渲染的墨迹必须显著多于纯填充。
    func testOutlineAddsInkAroundFill() throws {
        let model = self.model()
        let width = model.size.width + 12
        let height = model.size.height + 12

        let cell = OverlayDanmakuCell(frame: .zero)
        cell.model = model

        let fillOnly = makeContext(width: width, height: height)
        cell.drawFill(fillOnly, model: model, withShadow: false)

        let full = makeContext(width: width, height: height)
        cell.displaying(full, model.size, false)

        let fillInk = ink(try XCTUnwrap(fillOnly.makeImage()))
        let fullInk = ink(try XCTUnwrap(full.makeImage()))
        XCTAssertGreaterThan(fillInk, 0)
        XCTAssertGreaterThan(fullInk, fillInk, "描边没有产生额外墨迹")
    }

    /// 描边重量与旧实现同量级。偏移描边是「膨胀」而非真描边，覆盖率会有小差异，
    /// 但不能差出一个量级——那说明半径或方向数写错了。
    func testOutlineWeightIsComparableToLegacy() throws {
        let model = self.model(text: "前方高能预警")
        let width = model.size.width + 12
        let height = model.size.height + 12

        let legacyContext = makeContext(width: width, height: height)
        OverlayDanmakuCell(frame: .zero).drawLegacy(context: legacyContext, model: model)

        let newContext = makeContext(width: width, height: height)
        let newCell = OverlayDanmakuCell(frame: .zero)
        newCell.model = model
        newCell.displaying(newContext, model.size, false)

        let legacyInk = Double(ink(try XCTUnwrap(legacyContext.makeImage())))
        let newInk = Double(ink(try XCTUnwrap(newContext.makeImage())))
        XCTAssertGreaterThan(legacyInk, 0)
        let ratio = newInk / legacyInk
        XCTAssertGreaterThan(ratio, 0.75, "新描边明显偏细（ratio=\(ratio)）")
        XCTAssertLessThan(ratio, 1.35, "新描边明显偏粗（ratio=\(ratio)）")
    }

    /// 极深字走「柔和浅描边」分支，不能被当成纯黑处理（黑底黑边等于没描边）。
    func testVeryDarkTextUsesLightStrokeColor() {
        XCTAssertNotEqual(self.model(color: 0x000000).strokeColor, NSColor.black)
        XCTAssertEqual(self.model(color: 0xFFFFFF).strokeColor, NSColor.black)
    }

    // MARK: - 性能（守住这次的收益，别被改回去）

    /// 生产代码的新路径必须比旧路径快一个量级。
    ///
    /// 旧路径的描边走 CoreText 的 `.strokeWidth` 文本效果，每次绘制都要把字形实时
    /// 转成 `CGPath`（`CTFontCreatePathForGlyph` 实测 237 µs/字形）。这条断言是
    /// **防回归**用的：把 `displaying` 改回 `NSString.draw` 就会红。
    ///
    /// 阈值取 5×（实测约 10–25×），留足 CI 机器抖动的余量。
    func testCoreTextOutlineIsSubstantiallyFasterThanLegacyStroke() {
        let model = self.model(text: "前方高能预警 233333")
        let width = model.size.width + 12
        let height = model.size.height + 12

        let legacyCell = OverlayDanmakuCell(frame: .zero)
        legacyCell.model = model
        let newCell = OverlayDanmakuCell(frame: .zero)
        newCell.model = model

        let iterations = 40
        // 预热（首次会建 CTLine、填充字体缓存）
        for _ in 0..<5 {
            legacyCell.drawLegacy(context: makeContext(width: width, height: height), model: model)
            newCell.displaying(makeContext(width: width, height: height), model.size, false)
        }
        _ = model.lines()

        let legacyStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            legacyCell.drawLegacy(context: makeContext(width: width, height: height), model: model)
        }
        let legacyMicros = Double(DispatchTime.now().uptimeNanoseconds - legacyStart) / Double(iterations) / 1000

        let newStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            newCell.displaying(makeContext(width: width, height: height), model.size, false)
        }
        let newMicros = Double(DispatchTime.now().uptimeNanoseconds - newStart) / Double(iterations) / 1000

        let speedup = legacyMicros / newMicros
        XCTAssertGreaterThan(
            speedup, 5,
            "描边变慢了：旧 \(Int(legacyMicros))µs → 新 \(Int(newMicros))µs（\(String(format: "%.1f", speedup))×）"
        )
    }

    // MARK: - 对照图（只在显式要求时产出，默认不写盘）

    /// `OCPLAYER_RENDER_SNAPSHOT_DIR=<目录>` 时导出改动前后对照图：
    /// 现状（CoreText 文本效果描边）/ 新实现 / 纯填充，同尺寸纵向拼接并放大 3×。
    /// 对照图导出：默认跳过，设 `OCPLAYER_RENDER_SNAPSHOT_DIR=<目录>` 时写出
    /// 「现状 / 新实现 / 纯填充」三行对照图 + 墨迹量化。
    ///
    /// ⚠️ macOS 测试宿主**拿不到 shell 的环境变量**（实测：设了也走不到这里），
    /// 要在 Xcode 里跑的话，把变量加到 scheme 的 Test → Arguments → Environment。
    func testWriteBeforeAfterSnapshotWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["OCPLAYER_RENDER_SNAPSHOT_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("未设置 OCPLAYER_RENDER_SNAPSHOT_DIR，跳过对照图导出")
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = self.model(text: "前方高能预警 233333")
        let width = model.size.width + 16
        let height = model.size.height + 16

        let legacyContext = makeContext(width: width, height: height)
        OverlayDanmakuCell(frame: .zero).drawLegacy(context: legacyContext, model: model)

        let newContext = makeContext(width: width, height: height)
        let newCell = OverlayDanmakuCell(frame: .zero)
        newCell.model = model
        newCell.displaying(newContext, model.size, false)

        let fillContext = makeContext(width: width, height: height)
        newCell.drawFill(fillContext, model: model, withShadow: false)

        let images = [legacyContext.makeImage()!, newContext.makeImage()!, fillContext.makeImage()!]
        let upscale: CGFloat = 3
        let rowWidth = Int(width * scale * upscale)
        let rowHeight = Int(height * scale * upscale)
        let composite = CGContext(
            data: nil,
            width: rowWidth,
            height: rowHeight * images.count,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        composite.interpolationQuality = .none
        composite.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1))
        composite.fill(CGRect(x: 0, y: 0, width: CGFloat(rowWidth), height: CGFloat(rowHeight * images.count)))
        for (index, image) in images.enumerated() {
            let y = CGFloat(rowHeight * (images.count - 1 - index))
            composite.draw(image, in: CGRect(x: 0, y: y, width: CGFloat(rowWidth), height: CGFloat(rowHeight)))
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("danmaku-before-after.png")
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(composite.makeImage()))
            .representation(using: .png, properties: [:]))
        try data.write(to: url)

        // 量化：描边墨迹占「纯填充」的比例，新旧两条路各算一份。
        let legacyInk = Double(ink(try XCTUnwrap(legacyContext.makeImage())))
        let newInk = Double(ink(try XCTUnwrap(newContext.makeImage())))
        let fillInk = Double(ink(try XCTUnwrap(fillContext.makeImage())))
        let summary = String(
            format: "fillInk=%.0f legacyInk=%.0f newInk=%.0f\nlegacy/fill=%.3f new/fill=%.3f new/legacy=%.3f\nradius=%.3f fontSize=%.0f\n",
            fillInk, legacyInk, newInk,
            legacyInk / fillInk, newInk / fillInk, newInk / legacyInk,
            model.outlineRadius, fontSize
        )
        try summary.write(toFile: directory + "/ink-metrics.txt", atomically: true, encoding: .utf8)
        print("对照图已写入：\(url.path)（上=现状 中=新实现 下=纯填充）\n\(summary)")
    }
}
#endif
