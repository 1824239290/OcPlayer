import AppDesignKit
import SwiftUI
import XCTest

@testable import OcPlayer

/// 设置 hub 的**实际渲染几何**：真 `SettingsView` + 真协调器，离屏渲染成位图后从像素里量。
///
/// 为什么量像素而不是只断言常量：这一轮的口径来自用户拿对照产品（Rex）的设置页截图
/// 说的「我们的显得很粗糙」，逐像素量下来的差异里有两处是**渲染结果**而不是常量——
/// ① 卡片到底画出来没有（改前 `settingsCard()` 是 `listRowBackground(Color.clear)`，
///    **根本没有卡**）；② 行距到底是多少（常量给了 58，但 `.insetGrouped` 会不会照做
///    得渲染出来才知道）。常量写对不等于观感对。
///
/// 拍摄方式抄 `HomeLayoutTests`：**不能用 `ImageRenderer`**——它渲染不了
/// `Form`/`List` 的滚动内容（滚动容器在离屏渲染里拿不到视口）。挂进离屏
/// `UIWindow`、过一帧 runloop 再 `layer.render`。
@MainActor
final class SettingsLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        // 紧凑宽度（手机）版式是 iOS 专有路径：macOS 上 `horizontalSizeClass` 恒为 nil，
        // AppShell 永远走常规版式，而设置 hub 的卡底在 macOS 上是**刻意直通**的
        // （原生分组玻璃已是正确观感）——所以这套读数只在 iOS 上有意义。
        #if !os(iOS)
        throw XCTSkip("紧凑宽度版式只在 iOS 上存在")
        #endif
    }

    /// iPhone 16/17 Pro（用户对照截图那台的量级）：402 × 874pt。
    private let screen = CGSize(width: 402, height: 874)
    private let scale: CGFloat = 2

    /// 卡底必须**真的画出来了**：卡内比卡外亮。
    ///
    /// 改前这条必红——`settingsCard()` 那时是 `listRowBackground(Color.clear)`，
    /// 卡内卡外一样亮（行直接压在背景上）。
    func testCardsRenderBrighterThanPageBackground() throws {
        let bitmap = try renderHub(scheme: .dark)
        // 反向验证的落点：把 `settingsCard()` 改回 `Color.clear`（卡消失）时，
        // 这句 `XCTUnwrap` 会**失败**——刻意不许退化成 `XCTSkip`：skip 在 CI 里
        // 报的是 `TEST SUCCEEDED`，那就成了假通过（`Docs/AMBIENCE.md` 反复强调
        // 要防的那一类）。第一版这里抛的就是 XCTSkip，反向验证当场把它抓出来了。
        let contrast = try XCTUnwrap(
            bitmap.cardContrast(),
            "量不到卡片：卡内与卡外没有可分辨的亮度带——卡片根本没渲染出来")

        XCTAssertGreaterThanOrEqual(
            contrast, 8,
            "卡片与页面底的亮度差只有 \(contrast)（<8 看不出「一段一张卡」的分组结构，"
            + "就退回改前那种「行直接浮在背景上」的粗糙观感）")
        XCTAssertLessThanOrEqual(
            contrast, 60,
            "卡片与页面底的亮度差 \(contrast) 过大：卡底已经接近不透明白，"
            + "会把垫在页面里的氛围图盖死（见 settingsCard() 的注释）")
    }

    /// **亮色模式也要走一遍**：两条卡底不透明度里，亮色那档（0.75 白）与暗色那档
    /// （0.10 白）差了 7 倍，而它此前只在合成场景里验过（`SettingsRhythmTests` 那个
    /// 纯 `ZStack`），没在真 `Form` 上渲染过——`.light` 从没传给 `renderHub`，
    /// 于是那段 `-light.png` 附件分支压根不可达。
    ///
    /// 亮色是更容易出错的一档：页面底色本来就亮，卡底再叠 75% 白，边界很容易读不出来。
    func testLightModeCardStillShowsBoundary() throws {
        let bitmap = try renderHub(scheme: .light)
        let contrast = try XCTUnwrap(
            bitmap.cardContrast(),
            "亮色下量不到卡片：卡内与卡外没有可分辨的亮度带")

        XCTAssertGreaterThanOrEqual(
            contrast, 8,
            "亮色下卡片与页面底的亮度差只有 \(contrast)（<8 就分不出卡片边界；"
            + "亮色页面底色本就亮，卡底叠白后边界最容易糊掉）")
        // 亮色档刻意比暗色档"厚"（0.75 vs 0.10），但也不能厚到把氛围图按死——
        // 允许的上界比暗色松，因为亮色页面本身就是白雾。
        XCTAssertLessThanOrEqual(
            contrast, 72,
            "亮色下亮度差 \(contrast) 过大：卡底几乎不透明白，氛围图会被盖死")
    }

    /// 行距：同一张卡里相邻两行的**行心距**应为 58pt ± 2（对照产品实测 57.8pt）。
    ///
    /// 改前是 49.8pt（系统默认档）——这条会把「行高压回去了」当场量出来。
    func testRowPitchMatchesReferenceRhythm() throws {
        let bitmap = try renderHub(scheme: .dark)
        let pitches = bitmap.inkBandGaps()

        XCTAssertGreaterThanOrEqual(
            pitches.count, 2,
            "量不到足够的行间距（拿到 \(pitches.count) 段）：设置 hub 的 `.insetGrouped` "
            + "渲染可能变了，判据要跟着复核")

        // 取出现次数最多的一档：段间还有段标题/留白，它们不是行距。
        let reference = SettingsMetrics.rowPitch
        let matching = pitches.filter { abs($0 - reference) <= 2 }
        XCTAssertGreaterThanOrEqual(
            matching.count, 2,
            "应有至少两段行距 ≈ \(reference)pt（对照产品实测 57.8pt），"
            + "实测各段为 \(pitches.map { ($0 * 10).rounded() / 10 })")
    }

    /// 卡片左右边缘离屏缘的距离：系统 `insetGrouped` 的段边距——**实测 16pt**
    /// （与 Apple 自家 iOS 26 设置页的 16pt 一致）。
    /// 这条钉住「卡是一张卡」而不是「一条通铺到边的色带」——后者是 `listRowBackground`
    /// 在某些样式下的退化行为，也是本条最想拦下的失败模式。
    func testCardIsInsetFromScreenEdges() throws {
        let bitmap = try renderHub(scheme: .dark)
        let inset = try XCTUnwrap(
            bitmap.cardLeadingInset(),
            "找不到卡片左边缘：卡片根本没渲染出来")

        XCTAssertEqual(
            inset, 16, accuracy: 2,
            "卡片左边缘距屏缘实测 \(inset)pt（系统段边距 16pt）；"
            + "小于 10 说明行底退化成了通铺色带，明显大于 20 说明内容被挤窄了")
    }

    /// 分隔线必须停在**文字左缘**（对照产品与 Apple 自家设置页同款口径），
    /// 而不是停在图标左缘——停在图标下会把图标与文字在视觉上切开成两列。
    ///
    /// **这条是 `.alignmentGuide(.listRowSeparatorLeading)` 的真正落点**：实测两者
    /// 落点相同（去掉导轨也是 69pt，因为 iOS 16 起系统就按首个文字对齐），所以导轨
    /// 本身不是当下生效的修复。钉住**结果**而不是钉住「挂了哪一行修饰符」——结果才是
    /// 用户看得见的东西。
    func testSeparatorStopsAtLabelLeading() throws {
        let bitmap = try renderHub(scheme: .dark)
        let separator = try XCTUnwrap(
            bitmap.separatorLeading(),
            "没量到分隔线（行底与分隔线可能一起没了——卡片根本没渲染出来）")

        // 文字左缘 = 屏缘→卡缘 16pt（系统段边距，已由上面两条用例钉住）
        //          + 行内容距卡缘 rowLeadingInset + 图标列 + 图标文字间距
        let expected = 16 + SettingsMetrics.rowLeadingInset
            + SettingsMetrics.iconColumnWidth + SettingsMetrics.iconLabelSpacing
        XCTAssertEqual(
            separator, expected, accuracy: 3,
            "分隔线起点实测 \(separator)pt，按分量算应为 \(expected)pt"
            + "（卡缘 16 + 行内缩 \(SettingsMetrics.rowLeadingInset)"
            + " + 图标列 \(SettingsMetrics.iconColumnWidth)"
            + " + 图标文字间距 \(SettingsMetrics.iconLabelSpacing)）；"
            + "若明显偏小，说明分隔线退回了图标左缘")
    }

    // MARK: - 令牌的具体值（只有 iOS 跑得到这里）

    /// 行距 58pt = 内容高 44 + 上下内边距各 7。
    ///
    /// **这些数值只能钉在这里**：`Packages/AppDesignKit` 的包测试在 CI 里只以
    /// `swift test --package-path` 跑在 macOS 上，`#if os(iOS)` 的分支根本不执行
    /// （独立复核实测：把 iOS 的 `rowContentMinHeight` 改成 0（行距掉回 30pt），
    /// 包测试 78 条依然全绿）。所以 iOS 的具体数值全部收在本文件。
    func testRowMetricsMatchReferenceRhythmOnIOS() {
        XCTAssertEqual(
            SettingsMetrics.rowContentMinHeight, 44, accuracy: 0.01,
            "内容高 = HIG 最小点击区：Button 的 frame 就是热区，"
            + "低于 44 会出现「行看着很高、点在空白处没反应」")
        XCTAssertEqual(SettingsMetrics.rowVerticalInset, 7, accuracy: 0.01)
        XCTAssertEqual(
            SettingsMetrics.rowLeadingInset, 16, accuracy: 0.01,
            "声明 listRowInsets 会把系统的横向内边距一起替换掉，所以必须照抄 16pt")
        XCTAssertEqual(
            SettingsMetrics.rowPitch, 58, accuracy: 0.01,
            "44 + 7×2 = 58（对照产品 Rex 实测 57.8pt）")
    }

    /// 分隔线对齐位的**绝对值**。
    ///
    /// 这条不能写成 `separatorLeading == iconColumnWidth + iconLabelSpacing`——那是
    /// 它的定义本身，断言恒真。独立复核抓出原版正是这么写的（注释还声称
    /// 「两个分量任一被改，这条会亮」，而它永远不会亮）。所以这里钉绝对值，
    /// 并且两个分量各自单独钉住：改分量、改定义，都会红。
    func testSeparatorLeadingMatchesTheMeasuredValue() {
        XCTAssertEqual(SettingsMetrics.iconColumnWidth, 22, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.iconLabelSpacing, 15, accuracy: 0.01)
        XCTAssertEqual(
            SettingsMetrics.separatorLeading, 37, accuracy: 0.01,
            "绝对值 37pt（= 22 + 15）；这条对着定义写就没有意义了")
    }

    /// hub **最底部**必须有 TMDb 署名（官方字标 + 官方那句英文）。
    ///
    /// 判据是「从整页底部往上扫，能找到一块大幅亮于背景的图 + 多行文字」——
    /// 只在**拉长到 1400pt** 的画布上量（`Form` 装得下全部内容才不滚动，
    /// 页脚才在树里；固定 874pt 的其它用例会把它推到屏幕外）。
    ///
    /// 背景给**深灰**：字标是彩色（`#90cea1 → #00b3e5` 渐变），深底上「有彩色」
    /// 就是它在了——这条同时钉住「署名没被误做成模板渲染（那会变纯白单色）」。
    func testTMDbAttributionRendersAtPageBottom() throws {
        let app = AppModel()
        app.phase = .ready
        let tall = CGSize(width: screen.width, height: 1400)
        let view = SettingsView()
            .environment(app)
            .environment(BangumiCoordinator())
            .environment(MoviePilotCoordinator())
            .environment(DanmakuModel())
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, scale)
            .frame(width: tall.width, height: tall.height)
            .background(Color(white: 0.20))

        let image = try snapshot(view, size: tall)
        let bitmap = try SettingsBitmap(image: image, scale: scale)
        // 「应用」段之后就是页脚：在页脚区间里找彩色像素（品牌字标）。
        let chroma = try bitmap.maxChromaBelow(fraction: 0.62)
        XCTAssertGreaterThanOrEqual(
            chroma, 40,
            "页面下方找不到 TMDb 字标的彩色（最大色度 \(chroma)）："
            + "署名要么没挂上，要么被 `.renderingMode(.template)` 洗成了单色——"
            + "官方字标必须保持品牌配色。")
    }

    /// **三个品牌行图标都必须是单色**——和 SF Symbol 行图标同色（`.primary`）。
    ///
    /// 用户口径（2026-10-13）：「把 tmdb 元数据补充的那个 logo 改成和 bangumi、
    /// moviepilot 的一样的颜色」。TMDb 那份资产是**官方彩色渐变字标**（绿→蓝），
    /// 它自己在 imageset 里**没有** `template-rendering-intent`，所以只要
    /// `SettingsRowIcon` 漏掉 `.renderingMode(.template)`，这一行的图标就会是
    /// 一行彩色、跟旁边两行不是一回事——正是用户指出的那个不一致。
    ///
    /// 用受控的 `List` 而不是真 hub：真 hub 的卡片是半透明的，氛围底的彩色会透进来，
    /// 「图标框里有没有饱和色」就量不准了（会误报）。这里把底固定成中性灰，
    /// 图标框内任何明显色偏都只可能来自图标本身。
    func testBrandRowIconsAreMonochrome() throws {
        // `.listStyle(.insetGrouped)` 在 macOS 上**不可用**（是编译期错误，不是运行期
        // 才失败）。本文件其余用例靠 `setUpWithError` 里的 `XCTSkip` 挡 macOS，
        // 但那是**运行期**的、挡不住编译——所以这段必须显式包在 `#if os(iOS)` 里，
        // 否则整个 macOS 测试 target 编译失败（实测踩过：macOS 全量测试报
        // `'insetGrouped' is unavailable in macOS`，然后 Testing cancelled）。
        #if os(iOS)
        let rows: [SettingsSubpage] = [.bangumi, .moviepilot, .tmdb]
        let list = List {
            Section {
                ForEach(rows, id: \.self) { subpage in
                    SettingsNavRow(title: subpage.title, icon: subpage.icon) {}
                        .settingsRowInsets()
                }
            }
            .settingsCard()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.colorScheme, .dark)
        .frame(width: screen.width, height: 400)
        .background(Color(white: 0.20))

        let image = try snapshot(list, size: CGSize(width: screen.width, height: 400))
        let spreads = try SettingsBitmap(image: image, scale: scale)
            .iconColumnChannelSpreads(rowCount: rows.count)

        XCTAssertEqual(spreads.count, rows.count, "应量到 \(rows.count) 行的图标")
        for (index, spread) in spreads.enumerated() {
            XCTAssertLessThan(
                spread, 24,
                "「\(rows[index].title)」的行图标色偏是 \(spread)（应 <24，单色）："
                + "它还是品牌原色——`SettingsRowIcon` 的 `.brand` 分支漏了 "
                + "`.renderingMode(.template)`，或这一行的图标没走 `SettingsNavRow`。")
        }
        #endif
    }

    // MARK: - 渲染



    /// 把真设置 hub 挂进离屏 `UIWindow` 布局一帧再画进位图。
    ///
    /// 背景给**已知中灰**，而且**跟着外观走**：判据是「卡内比卡外亮多少」，底必须是
    /// 已知量；但底不能两种外观共用同一个值——真机的页面底色本身就是随外观变的
    /// （`Color.pageBackground` 日间近白、夜间近黑），底写死 0.20 再跑亮色，量到的
    /// 就只是「白卡叠在暗底上」，那个 145 的差值是**测试脚手架造出来的**，不是产品问题
    /// （第一版就是这么写的，亮色用例当场报 145 > 72）。
    /// 真机上垫的是模糊氛围图、亮度不固定，所以这里量的是**卡底叠加本身**。
    private func renderHub(scheme: ColorScheme) throws -> SettingsBitmap {
        let app = AppModel()
        app.phase = .ready

        let pageBase: Color = scheme == .dark ? Color(white: 0.20) : Color(white: 0.78)

        let view = SettingsView()
            .environment(app)
            .environment(BangumiCoordinator())
            .environment(MoviePilotCoordinator())
            .environment(DanmakuModel())
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.colorScheme, scheme)
            .environment(\.displayScale, scale)
            .frame(width: screen.width, height: screen.height)
            .background(pageBase)

        let image = try snapshot(view, size: screen)
        if let png = Self.pngData(from: image) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "settings-hub-\(scheme == .dark ? "dark" : "light").png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return try SettingsBitmap(image: image, scale: scale)
    }

    private func snapshot(_ view: some View, size: CGSize) throws -> CGImage {
        #if os(iOS)
        let controller = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // SwiftUI 的首帧要过一次 runloop 才会把内容放上图层树。
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        return try XCTUnwrap(image.cgImage, "快照没产出位图")
        #else
        throw XCTSkip("设置 hub 的卡底是 iOS 专有路径")
        #endif
    }

    private static func pngData(from image: CGImage) -> Data? {
        #if os(iOS)
        return UIImage(cgImage: image).pngData()
        #else
        return nil
        #endif
    }
}

// MARK: - 量尺

/// 一张设置 hub 位图上的读数（单位一律 pt）。
private struct SettingsBitmap {
    let image: CGImage
    let scale: CGFloat

    /// 相邻「文字/图标 ink 带」的行心距（pt），按从上到下排列。
    ///
    /// ink 判据取**高阈值**（亮像素）：行标题是 `.primary`（暗色 = 近白），
    /// 而段标题是 `.secondary` 灰、卡底是半透明叠加——两者都比行标题暗一档，
    /// 高阈值正好把它们排除在带外。
    func inkBandGaps() -> [CGFloat] {
        let (bytes, width, height) = pixels()
        var rowInk = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                if luma > 190 { count += 1 }
            }
            rowInk[y] = count
        }
        // 分带：连续有 ink 的行归一带；空档 ≥ 4px（2pt）才算断开。
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        var lastInk = -100
        for y in 0..<height {
            if rowInk[y] > 0 {
                if start == nil { start = y }
                lastInk = y
            } else if let s = start, y - lastInk > 4 {
                bands.append(s...lastInk)
                start = nil
            }
        }
        if let s = start { bands.append(s...lastInk) }

        // 太薄的带（分隔线残留、抗锯齿碎片）不参与。
        let centers = bands
            .filter { $0.upperBound - $0.lowerBound >= 4 }
            .map { CGFloat($0.lowerBound + $0.upperBound) / 2 / scale }
        return zip(centers, centers.dropFirst()).map { $1 - $0 }
    }

    /// 分隔线的起点（pt，距屏缘）——取最靠上那条能整条量到的细线。
    ///
    /// 判据：分隔线是「比上邻行亮一点点、且横向贯穿得很长」的一条。用 `luma > 上邻 + 2`
    /// 找候选点、并要求该行有 250pt 以上宽度的连续候选，才能把「文字的一横」滤掉。
    func separatorLeading() throws -> CGFloat? {
        let (bytes, width, height) = pixels()

        func luma(_ x: Int, _ y: Int) -> Double {
            let offset = (y * width + x) * 4
            return Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
        }

        for y in Int(150 * scale)..<min(height, Int(620 * scale)) where y >= 3 {
            var firstX: Int?
            var bright = 0
            for x in Int(20 * scale)..<Int(382 * scale) {
                if luma(x, y) > luma(x, y - 3) + 2 {
                    if firstX == nil { firstX = x }
                    bright += 1
                }
            }
            if bright > Int(250 * scale), let fx = firstX {
                return CGFloat(fx) / scale
            }
        }
        return nil
    }

    /// 卡内与卡外的平均亮度差（只取**确实落在卡片里**的那些行）。
    func cardContrast() throws -> Double? {
        let (bytes, width, _) = pixels()
        guard let band = try insideCardRowBand() else { return nil }
        let edge = Int(8 * scale)          // 屏缘到卡外采样带
        let insideMargin = Int(24 * scale) // 卡内采样带距屏缘（跳过卡边抗锯齿）

        var insideTotal = 0.0, insideCount = 0
        var outsideTotal = 0.0, outsideCount = 0
        for y in band.lowerBound...band.upperBound {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                if x >= insideMargin, x < width - insideMargin {
                    insideTotal += luma; insideCount += 1
                } else if x < edge || x >= width - edge {
                    outsideTotal += luma; outsideCount += 1
                }
            }
        }
        guard insideCount > 0, outsideCount > 0 else { return nil }
        return insideTotal / Double(insideCount) - outsideTotal / Double(outsideCount)
    }

    /// 卡片左边缘距屏缘（pt）：在**确知在卡内**的那条行带上横扫，找第一条比卡外亮的列。
    ///
    /// 为什么必须先定行带：hub 有三张卡，卡与卡之间是页面底色（实测 51 vs 卡内 72）。
    /// 一开始沿整个纵向扫描、按「该列大多数行都比卡外亮」判卡边，结果量到 33.5pt——
    /// 因为采样带跨过了段间空隙，空隙那些行把真正的卡边（16pt）投成了少数派。
    /// 先锁定一条卡内的行带，横向边界就唯一了。
    func cardLeadingInset() throws -> CGFloat? {
        let (bytes, width, _) = pixels()
        guard let band = try insideCardRowBand() else { return nil }
        let outside = try outsideLuminance(band: band)
        let threshold = outside + 4

        for x in 0..<width {
            var above = 0
            for y in band.lowerBound...band.upperBound {
                let offset = (y * width + x) * 4
                let luma = Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                if luma > threshold { above += 1 }
            }
            // 该列里**每一行**都比卡外亮 → 这一列整列在卡内（行带本身就是卡内的，
            // 所以不必留容差；留容差反而会把卡边外的抗锯齿列算进来）。
            if above == band.count {
                return CGFloat(x) / scale
            }
        }
        return nil
    }

    /// 一条**确定落在卡片内部**的连续行带（取中间半数，避开卡片上下圆角）。
    ///
    /// 判据：在 x = 30pt（远超系统的 16pt 段边距，必然在卡内）处逐行看亮度——
    /// 比卡外基准亮 ≥8 的连续行就是卡片。取最长的这样一段，再各砍掉 1/4。
    ///
    /// **为什么必须砍掉两端**：`insetGrouped` 的卡是圆角的（iOS 26 实测 ≈21pt），
    /// 靠边的列在卡片顶/底那十几 pt 里落在圆角弧线之外。不砍的话，「最左那一列在
    /// 整个行带里都比卡外亮」这个判据会被圆角弧线否掉，卡边一路右移到 24pt
    /// （实测踩过：先量到 33.5pt，改完带内判据又量到 24pt，都是圆角干的）。
    /// 只取中段之后，渐变的边缘不在采样范围里，卡边唯一。
    private func insideCardRowBand() throws -> ClosedRange<Int>? {
        let (bytes, width, height) = pixels()
        let probeX = min(Int(30 * scale), width - 1)

        func luma(_ x: Int, _ y: Int) -> Double {
            let offset = (y * width + x) * 4
            return Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
        }

        // 卡外基准：屏幕底部那一小块的亮度（页面底色 / 我们铺的已知灰）。
        var outsideTotal = 0.0, outsideCount = 0
        for y in Int(Double(height) * 0.90)..<height {
            for x in 0..<Int(6 * scale) {
                outsideTotal += luma(x, y); outsideCount += 1
            }
        }
        guard outsideCount > 0 else { return nil }
        let outside = outsideTotal / Double(outsideCount)

        var best: ClosedRange<Int>?
        var start: Int?
        for y in 0..<height {
            if luma(probeX, y) > outside + 8 {
                if start == nil { start = y }
            } else if let s = start {
                let band = s...(y - 1)
                if band.count > (best?.count ?? 0) { best = band }
                start = nil
            }
        }
        if let s = start {
            let band = s...(height - 1)
            if band.count > (best?.count ?? 0) { best = band }
        }
        // 找不到卡内行带 = **卡片根本没渲染出来**，这是失败而不是「测不了」——
        // 返回 nil 让调用方 `XCTUnwrap` 判失败。第一版这里抛的是 `XCTSkip`，
        // 结果把 `settingsCard()` 改回 `Color.clear`（卡消失）时用例只报
        // 「skipped」、CI 照样 `TEST SUCCEEDED`——**假通过**，正是本仓
        // `Docs/AMBIENCE.md` 里反复强调要防的那一类。反向验证就是这么发现的。
        guard let band = best, band.count >= Int(40 * scale) else { return nil }
        // 各砍掉 1/4：剩下的中段离卡片上下圆角足够远，横向边界唯一。
        let quarter = band.count / 4
        return (band.lowerBound + quarter)...(band.upperBound - quarter)
    }

    private func outsideLuminance(band: ClosedRange<Int>) throws -> Double {
        let (bytes, width, _) = pixels()
        var total = 0.0, count = 0
        for y in band {
            for x in 0..<Int(4 * scale) {
                let offset = (y * width + x) * 4
                total += Double(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return total / Double(count)
    }

    /// 每行**图标框内**的最大通道极差（单色 → 接近 0）。
    ///
    /// 图标框横向：卡缘 16 + 行内缩 `rowLeadingInset` = x 起 32pt，宽 `iconColumnWidth`
    /// ——这一侧是确定的（有专门的用例钉住）。
    ///
    /// 纵向**不假设行位置**，而是按「ink 带」切：`insetGrouped` 的段顶留白、段标题、
    /// 行内边距都不是我们说了算的，硬算行距会错（第一版按 `rowPitch` 累加，
    /// 结果 3 行只量到 2 行）。扫一列 ink 剖面、把连续 ink 归成带，就是「有几行图标」。
    func iconColumnChannelSpreads(rowCount: Int) throws -> [Int] {
        let (bytes, width, height) = pixels()
        let x0 = Int((16 + SettingsMetrics.rowLeadingInset) * scale)
        let x1 = min(x0 + Int(SettingsMetrics.iconColumnWidth * scale), width)

        func channelSpread(_ x: Int, _ y: Int) -> Int? {
            let o = (y * width + x) * 4
            let r = Int(bytes[o]), g = Int(bytes[o + 1]), b = Int(bytes[o + 2])
            // 底色是中性灰（0.20 ≈ 51），图标 ink 明显更亮（暗色下近白）。
            guard (r + g + b) / 3 > 110 else { return nil }
            return max(abs(r - g), max(abs(g - b), abs(r - b)))
        }

        // 逐行找 ink 带：带内取最大的通道极差。
        var spreads: [Int] = []
        var bandSpread: Int?
        var blankRun = 0
        for y in 0..<height {
            var rowMax: Int?
            for x in x0..<x1 {
                if let spread = channelSpread(x, y) {
                    rowMax = max(rowMax ?? 0, spread)
                }
            }
            if let rowMax {
                bandSpread = max(bandSpread ?? 0, rowMax)
                blankRun = 0
            } else {
                blankRun += 1
                // 连续 4px 以上空白才算这一行图标结束（抗锯齿的碎行不算新行）。
                if blankRun > 4, let spread = bandSpread {
                    spreads.append(spread)
                    bandSpread = nil
                }
            }
        }
        if let spread = bandSpread { spreads.append(spread) }
        return spreads
    }

    /// 指定纵向比例以下的**最大色度**（找彩色元素用；字标是彩色的，文字不是）。
    func maxChromaBelow(fraction: Double) throws -> Double {
        let (bytes, width, height) = pixels()
        var best = 0.0
        // 只扫横向中段：避开氛围底在左右边缘的强色（那是背景本身）。
        for y in Int(Double(height) * fraction)..<height {
            for x in Int(Double(width) * 0.25)..<Int(Double(width) * 0.75) {
                let o = (y * width + x) * 4
                let r = Double(bytes[o]), g = Double(bytes[o + 1]), b = Double(bytes[o + 2])
                let c = max(r, max(g, b)) - min(r, min(g, b))
                if c > best { best = c }
            }
        }
        return best
    }

    private func pixels() -> ([UInt8], Int, Int) {
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
        ) else { return ([], 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }
}
