import SwiftUI
import XCTest

@testable import AppDesignKit

/// 紧凑海报墙的**真实布局**回归：把 `PosterGrid.columns` 交给 SwiftUI 排一遍，
/// 再从渲染出的像素里数出「排了几列、每列多宽、列缝多宽」。
///
/// 为什么不只断言 token 值：列数是 `.adaptive(minimum:)` 与可用宽度共同决定的
/// 结果，token 对不代表列数对（改小 token 一个数就可能从 3 列变 4 列）。这里量的是
/// SwiftUI 算完之后的实际几何——用户看到的那个。
@MainActor
final class PosterGridLayoutTests: XCTestCase {
    /// iPhone 16/17 Pro 逻辑宽 402pt（用户对照截图那台）。页面留白 22pt×2。
    private let phoneContentWidth = 402 - 2 * Metrics.compactContentInset

    func testCompactGridIsThreeColumnsOnPhoneWidth() throws {
        let columns = try measureColumns(compact: true, contentWidth: phoneContentWidth)
        XCTAssertEqual(columns.count, 3, "402pt 手机上必须是 3 列（对照 Rex 的媒体库版式）")
        for width in columns {
            XCTAssertEqual(width, 112.7, accuracy: 1.5, "单卡宽应落在 Rex 那档（≈113pt，实测 118pt）")
        }
    }

    /// 紧凑宽度不止手机：iPad 分屏 / 侧拉窗口窄到 320pt 时应退回 2 列而不是硬塞 3 列。
    func testCompactGridFallsBackToTwoColumnsInNarrowSplit() throws {
        let columns = try measureColumns(compact: true, contentWidth: 320 - 2 * Metrics.compactContentInset)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0], 133, accuracy: 1.5)
    }

    /// 常规宽度（macOS / iPad 全屏）不受这次改动影响：仍是「178pt 起、自适应铺开」。
    func testRegularGridKeepsAdaptivePosterColumns() throws {
        let columns = try measureColumns(compact: false, contentWidth: 1280)
        XCTAssertEqual(columns.count, 6, "1280pt 内容宽按 186pt 最小列宽铺 6 列")
        for width in columns {
            XCTAssertGreaterThanOrEqual(width, Metrics.posterWidth)
        }
    }

    /// 海报 Rail 的**高度是按紧凑卡宽算的**，所以紧凑端的海报卡宽不能漏传：
    /// 定宽 178 的卡（+ 间距 + 标题行 ≈ 292pt）塞进紧凑 Rail 的 267pt 框里，
    /// 标题行会被整条裁掉。
    ///
    /// 这条不变量此前没人钉住，于是「类似推荐」rail 在手机上一直漏传宽度
    /// （首页「最近添加」传了、它没传），卡比框高——正好是这次要修的
    /// 「手机上卡片太大」的同一族。漏传的那处已修（`DetailView.similarRail`）。
    func testPosterRailHeightOnlyFitsTheWidthItAssumes() {
        let box = Metrics.posterRailHeight(compact: true)
        // 卡总高 = 图区（宽 × 1.5）+ 间距 9 + 一行 footnote 标题（≈16pt）。
        let compactCard = Metrics.compactPosterWidth * 1.5 + 9 + 16
        let wideCard = Metrics.posterWidth * 1.5 + 9 + 16

        XCTAssertLessThanOrEqual(compactCard, box, "紧凑卡宽必须装得下")
        XCTAssertGreaterThan(wideCard, box, "178 的卡在紧凑框里必然被裁——所以紧凑端必须传 compactPosterWidth")
    }

    // MARK: - 量尺

    /// 把 12 张「黑卡」按给定列策略排进 `contentWidth`，渲染成位图，
    /// 再扫描第一行卡片中线的暗像素段 → 每段的宽度（pt）与段数。
    private func measureColumns(compact: Bool, contentWidth: CGFloat) throws -> [CGFloat] {
        let cardHeight: CGFloat = 150
        let grid = LazyVGrid(columns: PosterGrid.columns(compact: compact), spacing: PosterGrid.rowSpacing(compact: compact)) {
            ForEach(0..<12, id: \.self) { _ in
                Color.black.frame(height: cardHeight)
            }
        }
        .frame(width: contentWidth, alignment: .top)
        .background(Color.white)

        let scale: CGFloat = 2
        let renderer = ImageRenderer(content: grid)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出位图（无图形上下文？）")

        let pixels = try PixelGrid(image: image)
        // 第一行卡片竖直中线；卡片高 150pt，取 60pt 处保证落在卡内、避开上下缝。
        let y = Int(60 * scale)
        return pixels.darkRuns(y: y, threshold: 0.5)
            .map { CGFloat($0.count) / scale }
    }
}

/// CGImage → 按行读灰度的小工具（只够这个用例用）。
private struct PixelGrid {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PixelGridError.noContext
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    enum PixelGridError: Error { case noContext }

    /// 某一横排上连续的暗像素段（黑卡），按 x 升序。
    func darkRuns(y: Int, threshold: CGFloat) -> [Range<Int>] {
        guard y >= 0, y < height else { return [] }
        let cutoff = UInt8(threshold * 255)
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let luma = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
            let isDark = luma / 3 < Int(cutoff)
            if isDark, start == nil {
                start = x
            } else if !isDark, let s = start {
                runs.append(s..<x)
                start = nil
            }
        }
        if let s = start { runs.append(s..<width) }
        // 抗锯齿边缘会切出 1pt 级的碎段，合并忽略。
        return runs.filter { $0.count > 2 }
    }
}
