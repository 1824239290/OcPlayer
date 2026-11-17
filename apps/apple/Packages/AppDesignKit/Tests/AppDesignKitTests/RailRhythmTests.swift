import SwiftUI
import XCTest

@testable import AppDesignKit

/// 首页栏位**纵向节奏**的回归：用户口径是「Rex 那种每个栏位之间间距没那么大」。
///
/// 对照截图（2026-10-11，430pt 宽的机器）像素实测：Rex 从「上一栏卡片底」到
/// 「下一栏标题 ink 顶」≈42pt；我们的首页当时是 66–73pt（同样按 ink 量）。
/// 差的那 20 多 pt 全在三个留白 token 上：悬停内边距、栏位顶部内边距、标题到内容
/// 的间距（见 `Metrics.railHoverPadding` 的注释）。
///
/// 这条用例量的是**包在真 Rail 里**的那两段（卡片按滚动框满高摆放），所以绝对值比
/// 真机小几 pt；`AppTests/HomeLayoutTests` 另外量了一遍真 `HomeView` 的整页
/// （现值 42.5 / 42.0pt）。两边一个量 token 的账、一个量用户眼里的账。
///
/// 这里量的是**真 Rail / 真 SkeletonRail 被 SwiftUI 排完之后的高度与标题 ink 位置**，
/// 不是 token 值自己：`ImageRenderer` 会把 Rail 的 ScrollView 按真实几何摆好（内容
/// 不绘制、几何照算），所以「标题 ink 底 → 封面框顶」「卡片框底 → 下一栏标题 ink 顶」
/// 这两段用户真正看到的留白可以直接从像素上量出来。
///
/// 两段都用**卡片填满滚动框**这个模型（卡片高度取
/// `*RailHeight - 2 × railHoverPadding`）——真实首页里卡片内容比框矮几 pt。
/// 模型一致，判定「松了还是紧了」的结论一致；这里守的是 token 别回退。
@MainActor
final class RailRhythmTests: XCTestCase {
    private let phoneWidth: CGFloat = 402
    private let scale: CGFloat = 2

    private struct Row: Identifiable { let id: Int }

    /// 卡片内容是 `AnyView`（`Color.black.frame(...)` 是 `_Frame` 不是 `Color`）。
    private typealias TestRail = Rail<Row, AnyView>
    private let rows = (0..<3).map { Row(id: $0) }

    // MARK: - 栏位间距（用户看到的那两段留白）

    /// 「标题 ink 底 → 封面框顶」：应落在 20…34pt。
    /// 原实现（标题间距 14 + 悬停内边距 28）在这套模型下是 45pt（把 token 改回去实测过）。
    func testHeaderToCardGapIsTight() throws {
        let rhythm = try measureRhythm(first: .still, second: .latest)
        XCTAssertGreaterThanOrEqual(rhythm.headerToCard, 20, "标题与封面贴到一起了")
        XCTAssertLessThanOrEqual(
            rhythm.headerToCard, 34,
            "标题 → 封面超过 34pt（原实现 45pt：14 + 28），栏位内部又松回去了"
        )
    }

    /// 「上一条 Rail 的卡片框底 → 下一条 Rail 的标题 ink 顶」：应落在 26…45pt。
    /// 原实现（28 + 24）在这套模型下是 55pt；真机整页上现值 42.5pt。
    func testSectionGapIsTight() throws {
        let rhythm = try measureRhythm(first: .still, second: .latest)
        XCTAssertGreaterThanOrEqual(rhythm.sectionGap, 26, "两条栏位贴在一起了，标题会压到上一栏的卡片上")
        XCTAssertLessThanOrEqual(
            rhythm.sectionGap, 45,
            "栏位之间超过 45pt（原实现 55pt、真机整页 60.5pt；Rex ≈42pt）"
        )
    }

    // MARK: - Rail 与骨架的几何

    /// Rail 的总高必须**恰好**等于「顶部内边距 + 标题行高 + 标题间距 + 内容框高」。
    /// 这条同时钉住三件事：Rail 用的是这三个 token（写回字面量 14 / 24 会立刻炸）、
    /// 内容框高按 `kind.scrollHeight` 走、没有多出来的隐藏留白。
    func testRailHeightComposesFromRhythmTokens() throws {
        let titleHeight = try measuredTitleHeight()
        for kind in [TestRail.Kind.still, .latest, .poster] {
            let height = try measuredHeight(rail(kind))
            let expected = Metrics.railTopInset + titleHeight + Metrics.railHeaderSpacing + scrollHeight(kind)
            XCTAssertEqual(height, expected, accuracy: 1, "\(kind) Rail 的总高与节奏 token 对不上")
        }
    }

    /// 「最近添加」比「继续观看」矮一档，差值必须**等于 token 差值**——新加的
    /// `.latest` 档就是靠这个矮下来的（16:9 小卡 + 没有进度轨）。
    func testLatestRailIsShorterThanStillByTokenDelta() throws {
        let still = try measuredHeight(rail(.still))
        let latest = try measuredHeight(rail(.latest))
        XCTAssertEqual(
            still - latest,
            Metrics.stillRailHeight(compact: isCompact) - Metrics.latestRailHeight(compact: isCompact),
            accuracy: 1
        )
        XCTAssertLessThan(latest, still)
    }

    /// 骨架撤掉换成真实内容时，整条 Rail 的**高度必须一致**（差 ≤1pt），否则首屏
    /// 加载完会跳一下——那正是骨架屏要消掉的东西。骨架曾经把 `spacing: 14` /
    /// `.padding(.top, 24)` 抄成字面量、与 Rail 各写一份，现在两边读同一组 token，
    /// 这条守住别再分叉。
    func testSkeletonRailMatchesRealRailHeight() throws {
        for (real, skeleton) in [
            (TestRail.Kind.still, SkeletonRail.RailKind.still),
            (.latest, .latest),
            (.poster, .poster),
        ] {
            let realHeight = try measuredHeight(rail(real))
            let skeletonHeight = try measuredHeight(SkeletonRail(title: "继续观看", kind: skeleton))
            XCTAssertEqual(
                skeletonHeight, realHeight, accuracy: 1,
                "\(real) 的骨架高 \(skeletonHeight) 与真实 Rail 高 \(realHeight) 对不上，加载完会跳"
            )
        }
    }

    // MARK: - 量尺

    private var isCompact: Bool { false }

    private func scrollHeight(_ kind: TestRail.Kind) -> CGFloat {
        kind.scrollHeight(compact: isCompact) ?? 0
    }

    /// 一条真 Rail：卡片高度取「内容框高 − 上下悬停内边距」，让卡片填满滚动框
    /// （见类型注释里对测量模型的说明）。
    private func rail(_ kind: TestRail.Kind) -> some View {
        let height = scrollHeight(kind) - 2 * Metrics.railHoverPadding
        return TestRail("继续观看", kind: kind, items: rows) { _ in
            AnyView(Color.black.frame(width: Metrics.compactStillWidth, height: height))
        }
    }

    private func context(_ view: some View) -> some View {
        view
            .frame(width: phoneWidth, alignment: .leading)
            .background(Color.white)
            .environment(\.contentLeading, Metrics.compactContentInset)
    }

    /// 两条真 Rail 上下叠（VStack spacing 0），从像素上量两段留白。
    private func measureRhythm(
        first: TestRail.Kind,
        second: TestRail.Kind
    ) throws -> (headerToCard: CGFloat, sectionGap: CGFloat) {
        let composition = context(
            VStack(alignment: .leading, spacing: 0) {
                rail(first)
                rail(second)
            }
        )
        let bands = RenderedImage.darkBands(in: try render(composition), scale: scale)
        XCTAssertEqual(bands.count, 2, "两条 Rail 各应有一段标题 ink：量到 \(bands)")
        let ink1 = try XCTUnwrap(bands.first)
        let ink2 = try XCTUnwrap(bands.last)

        // ScrollView 的内容不参与绘制，只有标题文字是暗像素；但整条 Rail 的几何
        // 照排——所以第一条 Rail 的高度可以直接量出来。
        let firstRailHeight = try measuredHeight(rail(first))
        let titleHeight = try measuredTitleHeight()
        let firstCardTop = Metrics.railTopInset + titleHeight + Metrics.railHeaderSpacing
            + Metrics.railHoverPadding
        let firstCardBottom = firstRailHeight - Metrics.railHoverPadding

        return (
            headerToCard: firstCardTop - ink1.upperBound,
            sectionGap: ink2.lowerBound - firstCardBottom
        )
    }

    private func measuredHeight(_ view: some View) throws -> CGFloat {
        CGFloat(try render(context(view)).height) / scale
    }

    /// 标题行自己的盒高（同一字体、同一字号独占一行量出来的）。
    private func measuredTitleHeight() throws -> CGFloat {
        try measuredHeight(Text("继续观看").font(.title3.weight(.bold)))
    }

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出位图（无图形上下文？）")
    }
}

/// 「每一行里暗像素的连续区间」——标题文字的 ink 带（pt）。
enum RenderedImage {
    static func darkBands(in image: CGImage, scale: CGFloat) -> [ClosedRange<CGFloat>] {
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
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func darkCount(row y: Int) -> Int {
            var count = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                if luma < 128 { count += 1 }
            }
            return count
        }

        var bands: [ClosedRange<CGFloat>] = []
        var start: Int?
        for y in 0..<height {
            if darkCount(row: y) > 0, start == nil {
                start = y
            } else if darkCount(row: y) == 0, let s = start {
                bands.append(CGFloat(s) / scale...CGFloat(y - 1) / scale)
                start = nil
            }
        }
        if let s = start { bands.append(CGFloat(s) / scale...CGFloat(height - 1) / scale) }
        // 抗锯齿切出的单行碎带并进相邻带。
        return bands.filter { $0.upperBound - $0.lowerBound >= 1 }
    }
}
