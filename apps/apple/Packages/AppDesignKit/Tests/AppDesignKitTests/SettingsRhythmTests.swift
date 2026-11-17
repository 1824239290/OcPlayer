import SwiftUI
import XCTest

@testable import AppDesignKit

/// 设置页**节奏令牌**与**行件渲染**的回归：口径来自对照产品 Rex 的逐像素实测。
///
/// 2026-10-13 拿两张截图量出来的差异只有四处（字号 / 文字 leading / 图标-文字间距 /
/// 分隔线对齐**本来就一致**），这份用例钉的是其余四处：
///   ① 行距 57.8pt（Rex 的卡高 173.3pt ÷ 3 行）——我们改前 49.8pt；
///   ② 卡底填充（Rex 反解 `白 ≈10%` 叠在氛围图上）——我们改前**完全没有卡**（全透）；
///   ③ 图标是**单色**——Rex 白色 glyph 直接坐在卡上，没有色块 tile（实测无字形列
///      lum 77.3 ≈ 卡底 79.0）；我们改前用系统强调色蓝；
///   ④ 分隔线停在**文字**左缘。
///
/// ## 平台口径：别在这里写 `#if os(iOS)` 的期望值
///
/// 本文件是 **package 测试**，CI 里只以 `swift test --package-path` 跑在 macOS 上
/// （iOS scheme 的测试 target 是 AppTests，不含包测试）。所以：
/// * 与平台相关的**具体数值**（44 / 58 / 37 这些）钉在
///   `AppTests/SettingsLayoutTests`——那边真的跑在 iOS 模拟器上；
/// * 这里只钉**与平台无关的东西**：两侧之间的算术关系、渲染出来的几何关系、颜色。
///
/// 这条纪律是独立复核抓出来的：本文件原先有几条 `#if os(iOS)` 断言，在 macOS 上
/// **一次都没执行过**——把 `rowContentMinHeight` 改成 0（行距掉回 30pt）本文件依然
/// 全绿。在只有 macOS 会跑的文件里写 `#if os(iOS)` 的期望值，等于写死代码。
@MainActor
final class SettingsRhythmTests: XCTestCase {
    private let scale: CGFloat = 2

    // MARK: - 令牌之间的关系（与平台无关）

    /// **iOS 档位的三个数**：内容高 44（HIG 最小点击区）、上下内边距各 7、横向内缩 16。
    ///
    /// 断言的是 `iOS*` 那组**与平台无关的真值常量**，不是平台计算属性——包测试在 CI 里
    /// 只跑在 macOS 上，iOS 分支不执行；断言常量才能让「改坏 iOS 档位」在 macOS 上就红
    /// （独立复核实测：原先直接断言计算属性，把 iOS 分支改成 0 时 78 条包用例全绿）。
    /// 「iOS 构建确实用了这几个常量」由 `AppTests/SettingsLayoutTests` 在模拟器上验。
    func testIOSRowTiersMatchTheReferenceRhythm() {
        XCTAssertEqual(SettingsMetrics.iOSRowContentMinHeight, 44, accuracy: 0.01,
                       "内容高 = HIG 最小点击区：Button 的 frame 就是热区")
        XCTAssertEqual(SettingsMetrics.iOSRowVerticalInset, 7, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.iOSRowLeadingInset, 16, accuracy: 0.01,
                       "声明 listRowInsets 会替换系统的横向内边距，必须照抄 16pt")
        XCTAssertEqual(
            SettingsMetrics.iOSRowContentMinHeight + SettingsMetrics.iOSRowVerticalInset * 2,
            58, accuracy: 0.01,
            "44 + 7×2 = 58（对照产品 Rex 实测 57.8pt）")
    }

    /// 行距 = 卡内行最小高 + 上下内边距——**两个平台各自的绝对值**。
    ///
    /// 这条本意是「算式本身」（两侧同源、单看恒真），所以它**不能**当验证用；
    /// 真正管用的是下面分平台的绝对值断言 + `AppTests` 里量真像素的那条。
    ///
    /// **2026-10-22 review 抓出的坑**：这条原来写的是 `rowContentMinHeight +
    /// rowVerticalInset*2`。macOS 的 `rowContentMinHeight` 是 0（Form 时代「交给系统撑」
    /// 的语义），于是包测试在 macOS 上算出 **12**，而产品实际行距是 `cardRowMinHeight`
    /// (30) + 6×2 = **42**——两边都不报错，因为断言自己就用了错的基准。
    func testRowPitchComposesFromCardRowHeightAndInsets() {
        XCTAssertEqual(
            SettingsMetrics.rowPitch,
            SettingsMetrics.cardRowMinHeight + SettingsMetrics.rowVerticalInset * 2,
            accuracy: 0.01,
            "行距必须由「内容高 + 上下内边距」算出来，不能另写一个数")
    }

    /// 卡内行模型的**分平台绝对值**。
    ///
    /// 这两组数决定「一行看起来多高」：iOS 44 + 7×2 = 58（对照产品 Rex 实测 57.8）、
    /// macOS 30 + 6×2 = 42（Form 时代实测 28，玻璃卡里 42 才有下载页的量感）。
    /// 包测试在 CI 里只跑 macOS，所以 **macOS 那组必须在这里钉死**——否则改坏了
    /// 只有肉眼能发现（`AppTests` 的渲染判据是 iOS-only）。
    func testCardRowTierMatchesEachPlatform() {
        #if os(macOS)
        XCTAssertEqual(SettingsMetrics.cardRowMinHeight, 30, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.rowVerticalInset, 6, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.rowPitch, 42, accuracy: 0.01)
        #else
        XCTAssertEqual(SettingsMetrics.cardRowMinHeight, 44, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.rowVerticalInset, 7, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.rowPitch, 58, accuracy: 0.01)
        #endif
    }

    /// 内容高不能低于最小点击区，内边距不能为 0。
    ///
    /// 两件事**不能互相顶替**——正是复核抓出的缺陷：曾经行距 58 而内容高只有 28，
    /// 于是「看着 58pt 高、只有中间 28pt 点得着」，当时的用例却拿行距去断言
    /// 「满足最小点击区」。断言放在 iOS 常量上，所以 macOS 跑也管用。
    func testTapTargetIsCarriedByContentHeightNotPitch() {
        XCTAssertGreaterThanOrEqual(
            SettingsMetrics.iOSRowContentMinHeight, 44,
            "内容高就是热区，低于 44pt 不满足 HIG")
        XCTAssertGreaterThan(
            SettingsMetrics.iOSRowVerticalInset, 0,
            "内边距为 0 时行距等于内容高，无法同时满足「够高」与「热区够大」")
    }

    /// 系统自带行内边距是**历史观测值**（我们声明 `listRowInsets` 之后它已被替换）。
    ///
    /// 留着它是因为「为什么改成 44+14」靠它解释：**44 + 14 = 58 = 28 + 30**——
    /// 行距分毫未动，只是把「系统的内边距」换成了「我们自己内容的热区」。
    /// 谁想改这个数，先读 `SettingsMetrics.systemRowInsets` 的注释。
    func testSystemRowInsetsStaysAsTheRecordedHistory() {
        XCTAssertEqual(
            SettingsMetrics.systemRowInsets, 30, accuracy: 0.01,
            "这是改前实测的系统内边距（44+14=58=28+30 这条等式靠它成立）")
    }

    // MARK: - 真渲染

    /// 一行真行件渲染出来：图标从行内容左缘起排、文字排在图标右侧。
    /// 量像素而不是只断言常量——`HStack` 的对齐与 `Image` 的实际宽度都会挪位置。
    func testRowIconAndLabelRenderInOrder() throws {
        let row = SettingsNavRow(
            title: "数据与资源", systemImage: "square.stack", value: nil
        ) {}
        .frame(width: 300, alignment: .leading)
        .environment(\.colorScheme, .dark)

        let image = try render(row)
        let ink = try XCTUnwrap(RenderedRow.inkProfile(in: image, scale: scale))

        XCTAssertGreaterThan(
            ink.labelMinX, ink.iconMaxX,
            "文字左缘（\(ink.labelMinX)）必须排在图标右缘（\(ink.iconMaxX)）之后")
        // 图标在列里**居中**（`frame(width:)` 的默认对齐），所以 ink 起点是
        // (列宽 − 符号宽)/2，不是 0——别断言 `== 0`，那在 macOS 的窄列上必红
        // （16pt 列装 13pt glyph，实测 ink 起点 2.5pt）。真正要守的是两件事：
        // ① 不往左溢出到行内容之外；② 不把右边那一列（标题）挤走。
        XCTAssertGreaterThanOrEqual(
            ink.iconMinX, 0,
            "图标往左溢出了行内容左缘（实测 \(ink.iconMinX)pt）")
        // macOS 的列更窄（16pt 装 13pt glyph，宽符号会略微溢出），iOS 的 22pt 列
        // 是按最宽的符号留的——容差按平台给，原因写在这里。
        #if os(macOS)
        let overflowTolerance: CGFloat = 4
        #else
        let overflowTolerance: CGFloat = 1
        #endif
        XCTAssertLessThanOrEqual(
            ink.iconMaxX, SettingsMetrics.iconColumnWidth + overflowTolerance,
            "图标溢出了自己的列太多（列宽 \(SettingsMetrics.iconColumnWidth)）："
            + "宽符号会把旁边那一列挤走，文字 leading 就不齐了")
    }

    /// **图标必须是单色**（③ 的核心交付物）。
    ///
    /// 这条是补的：整份用例集原先**没有任何一条**钉住颜色——独立复核把图标改成
    /// `.yellow`（一个完全饱和的色）时 78 条包用例**全绿**。当时的判定只读亮度、
    /// 对颜色是瞎的；改 `.blue` 之所以会红，还是因为蓝的亮度掉到阈值以下、把
    /// **标题文字**误判成了图标（连带把失败信息也说错了原因）。所以这里显式量色偏。
    func testRowIconIsMonochrome() throws {
        let row = SettingsNavRow(
            title: "一", systemImage: "square.stack", value: nil
        ) {}
        .frame(width: 300, alignment: .leading)
        .environment(\.colorScheme, .dark)

        let image = try render(row)
        let spread = try XCTUnwrap(
            RenderedRow.inkChannelSpread(in: image, scale: scale),
            "量不到图标 ink（图标可能没渲染出来）")

        // 白色 ink 的三通道差 ≈0：抗锯齿只是把它与灰底按比例混合，底色本身中性，
        // 混合后仍中性。任何有彩色相的 tint 都会把这个差拉大——实测 `.blue` ≈ 110、
        // `.yellow` ≈ 190，离阈值 24 都很远。
        XCTAssertLessThan(
            spread, 24,
            "图标 ink 的通道极差是 \(spread)，说明它不是单色（`.primary` 应为近白）："
            + "对照产品的行图标是白色单色，用系统强调色是「看着廉价」的直接来源之一")
    }

    // MARK: - 品牌图缩放（纯函数）

    /// 品牌图在图标框里**保比例**：宽高各试一遍，取更紧的那一维。
    ///
    /// 三个品牌图的宽高比差 2.7 倍（Bangumi 0.94 / MoviePilot 0.86 / TMDB 2.33），
    /// 所以「按哪一维约束」是必须算准的一步：TMDB 的官方字标若按高约束，
    /// 22pt 的框里会算出 42pt 宽——**溢出图标列、把标题挤走**。
    func testBrandIconFittedSizePreservesAspect() {
        let box = CGSize(width: 22, height: 18)

        // 方形 logo：按高约束（18 高 → 约 17 宽），不吃满列宽。
        let square = SettingsRowIcon.fittedSize(aspect: 0.94, in: box)
        XCTAssertEqual(square.height, 18, accuracy: 0.01)
        XCTAssertEqual(square.width, 18 * 0.94, accuracy: 0.01)
        XCTAssertLessThanOrEqual(square.width, box.width)

        // 字标（2.33:1）：按**宽**约束（22 宽 → 约 9.4 高），不会溢出。
        let wordmark = SettingsRowIcon.fittedSize(aspect: 2.33, in: box)
        XCTAssertEqual(wordmark.width, 22, accuracy: 0.01)
        XCTAssertEqual(wordmark.height, 22 / 2.33, accuracy: 0.01)
        XCTAssertLessThanOrEqual(wordmark.height, box.height)

        // 极端比例也不许越界（用户可能换资产）。
        for aspect in [0.1, 0.5, 1.0, 3.0, 10.0] as [CGFloat] {
            let size = SettingsRowIcon.fittedSize(aspect: aspect, in: box)
            XCTAssertLessThanOrEqual(size.width, box.width + 0.01, "aspect=\(aspect) 宽度越界")
            XCTAssertLessThanOrEqual(size.height, box.height + 0.01, "aspect=\(aspect) 高度越界")
            XCTAssertEqual(size.width / size.height, aspect, accuracy: 0.01, "aspect=\(aspect) 比例被改")
        }

        // 非法比例不崩、原样回框（资产坏掉时不该让布局炸掉）。
        XCTAssertEqual(SettingsRowIcon.fittedSize(aspect: 0, in: box), box)
        XCTAssertEqual(SettingsRowIcon.fittedSize(aspect: -1, in: box), box)
    }

    // MARK: - 量尺

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出位图（无图形上下文？）")
    }
}

/// 位图里的行件几何（pt）。
struct RowInk {
    var iconMinX: CGFloat
    var iconMaxX: CGFloat
    var labelMinX: CGFloat
}

enum RenderedRow {
    /// 把一行里「图标」与「文字」的 ink 横向区间量出来。
    ///
    /// 判据：按列统计暗底上的亮像素数。行件在**暗色**下渲染，所以 ink 是亮像素
    /// （`.primary` 在暗色 = 白）。列剖面会出现两簇：图标列（较窄）与文字列（较宽）。
    ///
    /// **阈值 140 有个已知边界**：它同时充当「是不是 ink」的判据，于是亮度低但饱和的
    /// 颜色（`.blue` 的 lum ≈126）会整簇消失、把后面的标题误判成图标。颜色由
    /// `inkChannelSpread` 单独量，别指望这里的阈值兼职。
    static func inkProfile(in image: CGImage, scale: CGFloat) throws -> RowInk? {
        let (bytes, width, height) = try pixels(image)
        var columnInk = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                if luma > 140 { columnInk[x] += 1 }
            }
        }
        // 分簇：空档 > 3px（1.5pt）才算断开。
        var clusters: [ClosedRange<Int>] = []
        var start: Int?
        var lastInk = -100
        for x in 0..<width {
            if columnInk[x] > 0 {
                if start == nil { start = x }
                lastInk = x
            } else if let s = start, x - lastInk > 3 {
                clusters.append(s...lastInk)
                start = nil
            }
        }
        if let s = start { clusters.append(s...lastInk) }
        guard clusters.count >= 2 else { return nil }

        let icon = clusters[0]
        // 文字是**第一簇之后**所有簇的并集（一个中文词可能被笔画切出多簇）。
        let labelMin = clusters[1].lowerBound
        return RowInk(
            iconMinX: CGFloat(icon.lowerBound) / scale,
            iconMaxX: CGFloat(icon.upperBound) / scale,
            labelMinX: CGFloat(labelMin) / scale
        )
    }

    /// 所有 ink 像素里最大的**通道极差** max(|R−G|, |G−B|, |R−B|)。
    ///
    /// 单色（白 / 灰 / 黑）≈ 0；任何有彩色相的 tint 都会把它拉大。
    /// 用**最大值**而不是平均值：图标笔画只占这一小块的一小部分，平均值会被底色稀释
    /// （实测 `.yellow` 的平均值远小于最大值）。
    static func inkChannelSpread(in image: CGImage, scale: CGFloat) throws -> Int? {
        let (bytes, width, height) = try pixels(image)
        var spread = 0
        var sawInk = false
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                guard (r + g + b) / 3 > 140 else { continue }
                sawInk = true
                spread = max(spread, max(abs(r - g), max(abs(g - b), abs(r - b))))
            }
        }
        return sawInk ? spread : nil
    }

    private static func pixels(_ image: CGImage) throws -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("拿不到位图上下文") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }
}
