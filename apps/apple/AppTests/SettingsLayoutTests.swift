import AppDesignKit
import SwiftUI
import XCTest

@testable import OcPlayer

/// 设置 hub 的**实际渲染几何**：真 `SettingsView` + 真协调器，离屏渲染成位图后从像素里量。
///
/// ## 这一轮为什么整份重写（2026-10-22，B 方案）
///
/// 设置页刚从 `Form` 换成 `ScrollView` + 玻璃卡片流（`SettingsGlassPage` /
/// `SettingsGlassSection` / `SettingsGlassCard`），旧判据的三条前提全部消失：
/// ① 卡底由 `Form` 的 `insetGrouped` 段背景提供 → 现在是 `glassEffect` + 0.5pt 描边；
/// ② 行距由 `listRowInsets` 给 → 现在由 `SettingsCardRowLayout` 给（44 + 7×2）；
/// ③ 系统分隔线停在文字左缘 → 现在是自己画的 `SettingsGlassDivider`（停在
///    卡内文字左缘 = `iconColumnWidth + iconLabelSpacing`）。
/// 所以判据必须重写，但**作风不变：量渲染结果，不只断言常量**。
///
/// ## 测量路线：为什么量「描边线」而不是「卡内外亮度差」
///
/// 先验证了 `layer.render`（离屏）到底能不能把 `glassEffect` 画出来——结果是
/// **画不出来**：`glassEffect` 是窗口合成器的效果，离屏 `CALayer.render(in:)`
/// 拿不到真实别层，卡内与页面底注入色**逐像素相同**（`cardEdges` 会打印
/// `interiorΔ`，实测恒为 **0.0**；而卡缘描边同时量到 ±15.8 luma，说明渲染管线
/// 本身是通的、只是玻璃不出图）。因此「卡内比卡外亮」这条旧判据在新实现上
/// **恒为 0**，继续用它只会测试脚手架。
///
/// 改用：给渲染环境注入**已知深/浅底色**（页面底在测试里是 `.background(pageBase)`），
/// 然后量 `liquidGlassCard` 的那条 0.5pt 描边（`Color.primary.opacity(0.08)`）——
/// 它是**普通 SwiftUI 绘制**，离屏一定能画出来，且叠在已知底色上的亮度阶跃可以精确
/// 预期（深色底 0.20 上叠 8% 白 ≈ +16 luma；浅色底 0.78 上叠 8% 黑 ≈ −16 luma）。
/// 用「卡缘处的一条亮/暗线」替代表达「卡真的画出来了」。
///
/// 这条判据的反向验证落点：删掉 `.liquidGlassCard(...)`（不画卡）时，卡缘线消失，
/// `XCTUnwrap` 会**失败**。刻意**不许**退化成 `XCTSkip`：skip 在 CI 里报的是
/// `TEST SUCCEEDED`，那是假通过（本仓 `Docs/AMBIENCE.md` 反复强调要防的那一类）。
@MainActor
final class SettingsLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        // 紧凑宽度（手机）版式是 iOS 专有路径：macOS 上 `horizontalSizeClass` 恒为 nil，
        // AppShell 永远走常规版式，设置 hub 的留白/卡片流是 iOS 专有读数。
        #if !os(iOS)
        throw XCTSkip("紧凑宽度版式只在 iOS 上存在")
        #endif
    }

    /// iPhone 16/17 Pro（用户对照截图那台的量级）：402 × 874pt。
    private let screen = CGSize(width: 402, height: 874)
    private let scale: CGFloat = 2

    /// 测试**显式注入**的页面横向留白。
    ///
    /// 产品里由 `AppShellView` 按尺寸类注入（compact = 22 / 常规 = 52），默认值是
    /// `Metrics.contentInset`（52）。这里注入一个**与产品任何取值都不重合、也不是旧
    /// `Form` 行内边距**的数字：
    ///
    /// * 取 16 是错的（2026-10-22 review 抓出）：16 恰好是改造前 `Form` 的行内容内边距、
    ///   `cardContentInset` 也是 16，于是「读到了注入的 `contentLeading`」与「某处硬编码
    ///   了 16」在这条判据上**无法区分**——判据看起来在验 env，实际可能什么都没验。
    /// * 取 **37**：不等于 16 / 22 / 52 / 任何一个卡内边距或图标列宽，卡缘只要等于 37
    ///   就只可能是真的读了环境值。
    private let contentLeading: CGFloat = 37

    /// 测试注入的页面底色（离屏玻璃不出图，见类注释：底色是已知量才能量描边）。
    private var pageBaseDark: Color { Color(white: 0.20) }
    private var pageBaseLight: Color { Color(white: 0.78) }

    // MARK: - 卡片存在（深 / 亮两档）

    /// 卡片**真的画出来了**：卡缘处有一条 0.5pt 描边形成的亮度阶跃。
    ///
    /// 深色档：`Color.primary` = 白，0.20 灰底上叠 8% 白 ≈ +16 luma；实测取
    /// 卡缘列相对页面底的最大偏差，断言 ≥6（留抗锯齿/缩放余量）。
    /// 同时要求这条线在纵向连续出现（≥100pt 高），排除「某一行文字恰好在卡缘上」的巧合。
    func testDarkCardBoundaryRendersOnKnownPageBase() throws {
        let bitmap = try renderHub(scheme: .dark)
        let edges = try XCTUnwrap(
            bitmap.cardEdges(expectedLeading: contentLeading),
            "找不到卡片描边：卡片根本没渲染出来（或卡缘不在注入的 contentLeading 处）")

        XCTAssertGreaterThanOrEqual(
            edges.leadingSigned, 6,
            "深色卡左缘的描边**没有比页面底更亮**（实测 \(edges.leadingSigned) luma）："
            + "0.20 灰底上 8% 白描边应约 +16。<=0 说明 `liquidGlassCard` 的描边没画出来")
        XCTAssertGreaterThanOrEqual(
            edges.trailingSigned, 6,
            "深色卡右缘的描边没有更亮（实测 \(edges.trailingSigned) luma，应约 +16）")
        XCTAssertGreaterThanOrEqual(
            edges.lineHeight, 100,
            "卡缘线只连续出现了 \(edges.lineHeight)pt（应 ≥100pt）："
            + "卡片可能没铺满内容列，或描边被别的东西盖住")
        print("[SettingsLayoutTests] dark: leadingΔ=\(edges.leadingSigned) "
            + "trailingΔ=\(edges.trailingSigned) lineHeight=\(edges.lineHeight)pt "
            + "interiorΔ=\(edges.interiorDelta)")
    }

    /// **亮色模式也要走一遍**：描边色是 `Color.primary.opacity(0.08)`，亮色下是
    /// 「8% 黑」——方向与深色相反（−16 luma），最容易写反的一档；亮色页面底色本就亮，
    /// 边界也最容易糊掉。旧版测试的教训：亮色档曾经整条不可达。
    func testLightCardBoundaryRendersOnKnownPageBase() throws {
        let bitmap = try renderHub(scheme: .light)
        let edges = try XCTUnwrap(
            bitmap.cardEdges(expectedLeading: contentLeading),
            "亮色下找不到卡片描边：卡片没渲染出来")

        // 亮色档的量级同样 ≥6，但**方向必须相反**：`Color.primary` 在亮色下是黑，
        // 描边是「8% 黑」→ 卡缘比页面底更**暗**。只判绝对值会漏掉「动态色没跟着
        // 外观翻」这类缺陷（那时亮色下描边会变亮，方向反了却仍然 ≥6 通过）。
        XCTAssertLessThanOrEqual(
            edges.leadingSigned, -6,
            "亮色卡左缘的描边没有比页面底更暗（实测 \(edges.leadingSigned) luma，"
            + "应约 −16）：`Color.primary` 没跟着外观翻，或描边没画出来")
        XCTAssertLessThanOrEqual(
            edges.trailingSigned, -6,
            "亮色卡右缘的描边没有更暗（实测 \(edges.trailingSigned) luma，应约 −16）")
        print("[SettingsLayoutTests] light: leadingΔ=\(edges.leadingSigned) "
            + "trailingΔ=\(edges.trailingSigned) lineHeight=\(edges.lineHeight)pt "
            + "interiorΔ=\(edges.interiorDelta)")
    }

    // MARK: - 行距

    /// 行距：同一张卡里相邻两行的**行心距** = `cardRowMinHeight + rowVerticalInset×2`
    /// = 44 + 7×2 = **58pt ± 2**（对照产品实测 57.8pt）。
    ///
    /// 改前（Form 承载）靠系统 `listRowInsets`；B 方案靠 `SettingsCardRowLayout`。
    /// 这条会把「行高压回去了 / 行被挤成自然高」当场量出来——例如漏掉
    /// `SettingsCardRowLayout` 时 Toggle 行只有 ~22pt。
    func testRowPitchMatchesReferenceRhythm() throws {
        let bitmap = try renderHub(scheme: .dark)
        let pitches = bitmap.inkBandGaps()

        XCTAssertGreaterThanOrEqual(
            pitches.count, 8,
            "量不到足够的行间距（拿到 \(pitches.count) 段）：hub 有 10 行导航行，"
            + "卡内应有 7 段 58pt 行距 + 跨卡 2 段；拿到 \(pitches.map { ($0 * 10).rounded() / 10 })")

        let reference = SettingsMetrics.rowPitch
        let matching = pitches.filter { abs($0 - reference) <= 2 }
        XCTAssertGreaterThanOrEqual(
            matching.count, 6,
            "应有至少 6 段行距 ≈ \(reference)pt（3 张卡共 10 行 → 卡内 7 段），"
            + "实测各段为 \(pitches.map { ($0 * 10).rounded() / 10 })")
        print("[SettingsLayoutTests] row pitches(pt)=\(pitches.map { ($0 * 10).rounded() / 10 }) "
            + "reference=\(reference) matching=\(matching.count)/\(pitches.count)")
    }

    // MARK: - 几何

    /// 卡左右缘 = 注入的 `contentLeading`（±2），即 **16 / 386pt**；卡宽 = 屏宽 − 2×16。
    ///
    /// 这条钉住「卡是一张卡」而不是「一条通铺到边的色带」——后者在
    /// `SettingsGlassPage` 漏掉横向 padding 时会立刻出现（卡缘会量到 0 / 402）。
    func testCardEdgesSitAtInjectedContentLeading() throws {
        let bitmap = try renderHub(scheme: .dark)
        let edges = try XCTUnwrap(
            bitmap.cardEdges(expectedLeading: contentLeading),
            "找不到卡缘：卡片根本没渲染出来")

        XCTAssertEqual(
            edges.leading, contentLeading, accuracy: 2,
            "卡左缘实测 \(edges.leading)pt（注入 contentLeading = \(contentLeading)）")
        XCTAssertEqual(
            edges.trailing, screen.width - contentLeading, accuracy: 2,
            "卡右缘实测 \(edges.trailing)pt（应为 \(screen.width - contentLeading)）")
        XCTAssertEqual(
            edges.width, screen.width - contentLeading * 2, accuracy: 4,
            "卡宽实测 \(edges.width)pt（应为 \(screen.width - contentLeading * 2)）："
            + "卡没有吃满内容列，或卡片流被居中窄列二次收窄")
        print("[SettingsLayoutTests] card edges leading=\(edges.leading) trailing=\(edges.trailing) "
            + "width=\(edges.width) strokeCancel=\(String(format: "%.1f", edges.leadingContrast)) "
            + "interiorΔ=\(String(format: "%.1f", edges.interiorDelta)) "
            + "lineHeight=\(edges.lineHeight)")
    }

    /// 分隔线停在**卡内文字左缘**：卡缘 + `cardContentInset` + `iconColumnWidth`
    /// + `iconLabelSpacing` = 16 + 16 + 22 + 15 = **69pt**（±3）。
    ///
    /// B 方案的分隔线是 `SettingsGlassDivider` 自己画的 1 物理像素线，leading 由
    /// `.padding(.leading, iconColumnWidth + iconLabelSpacing)` 相对**卡内容左缘**给定。
    /// 停在图标下会把图标与文字在视觉上切开成两列——这条同时钉住绝对对齐位与
    /// 两个分量的**绝对值**（对着定义写会恒真，那没有意义）。
    func testSeparatorStopsAtLabelLeading() throws {
        let bitmap = try renderHub(scheme: .dark)
        let separator = try XCTUnwrap(
            bitmap.separatorLeading(),
            "没量到分隔线（卡内 1px 线可能在离屏渲染里丢了，或卡片根本没画出来）")

        // 分量必须钉**绝对值**：`separatorLeading == iconColumnWidth + iconLabelSpacing`
        // 是定义本身，只断言它会恒真（旧版被独立复核抓过这一点）。
        XCTAssertEqual(SettingsMetrics.iconColumnWidth, 22, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.iconLabelSpacing, 15, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.separatorLeading, 37, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.cardContentInset, 16, accuracy: 0.01)

        let expected = contentLeading + SettingsMetrics.cardContentInset
            + SettingsMetrics.iconColumnWidth + SettingsMetrics.iconLabelSpacing
        print("[SettingsLayoutTests] separator leading=\(separator)pt expected=\(expected)pt")
        XCTAssertEqual(
            separator, expected, accuracy: 3,
            "分隔线起点实测 \(separator)pt，按分量算应为 \(expected)pt"
            + "（卡缘 \(contentLeading) + 卡内容内缩 \(SettingsMetrics.cardContentInset)"
            + " + 图标列 \(SettingsMetrics.iconColumnWidth)"
            + " + 图标文字间距 \(SettingsMetrics.iconLabelSpacing)）；"
            + "若明显偏小，说明分隔线退回了图标左缘（甚至卡缘）")
    }

    // MARK: - 令牌的具体值（只有 iOS 跑得到这里）

    /// 行距模型：**内容高** 44（= HIG 最小点击区）+ 上下内边距各 7 = 58。
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
        XCTAssertEqual(SettingsMetrics.rowLeadingInset, 16, accuracy: 0.01)
        XCTAssertEqual(
            SettingsMetrics.cardRowMinHeight, 44, accuracy: 0.01,
            "B 方案下卡内操作行的最小高（= 整行热区）也必须 ≥44；"
            + "它和 rowContentMinHeight 是同一个 44，改一个另一个应同步")
        XCTAssertEqual(
            SettingsMetrics.rowPitch, 58, accuracy: 0.01,
            "B 方案行距 = cardRowMinHeight 44 + rowVerticalInset 7×2 = 58"
            + "（对照产品 Rex 实测 57.8pt，渲染实测见 testRowPitchMatchesReferenceRhythm）")
    }

    /// B 方案新原语的具体数值：卡片内边距 / 圆角 / 段间距 / 页面内边距 / 内容列宽。
    ///
    /// 这些值决定「和 MoviePilot 下载页同一套玻璃」这条用户口径的**一致性**：
    /// 卡内边距与下载任务卡同档 16、圆角同档 16、描边同档 0.5pt（描边在
    /// `liquidGlassCard` 里，由渲染用例覆盖）。容器宽度 720 是「iPhone 上是 no-op、
    /// iPad 全屏不横铺」的上限。
    func testGlassCardMetricsMatchDownloadPageGlass() {
        XCTAssertEqual(SettingsMetrics.cardContentInset, 16, accuracy: 0.01,
                       "卡内横向留白（与下载任务卡同档）")
        XCTAssertEqual(SettingsMetrics.cardContentVerticalInset, 6, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.cardCornerRadius, 16, accuracy: 0.01,
                       "卡圆角（与下载任务卡同档 16）")
        XCTAssertEqual(SettingsMetrics.sectionHeaderSpacing, 8, accuracy: 0.01,
                       "段标题 → 卡顶 8pt")
        XCTAssertEqual(SettingsMetrics.sectionHeaderInset, 4, accuracy: 0.01)
        XCTAssertEqual(SettingsMetrics.pageTopInset, 16, accuracy: 0.01)
        // **iOS 是 96，不是 56**：iOS 26 的标签栏是悬浮玻璃胶囊，它压住的视觉浮层
        // 不一定算进 `safeAreaInsets`——只留 56 时设置页最后一张卡（「应用」段）
        // 会被压进 Tab 栏底下（iPhone 17 Pro 模拟器截图已确认）。96 = 胶囊高 +
        // 与内容之间一档呼吸位。macOS 没有悬浮 Tab 栏，那边仍是 56。
        // 这条钉 iOS 的绝对值：它是「末卡不被压住」这条观感契约的量化落点。
        XCTAssertEqual(
            SettingsMetrics.pageBottomInset, 96, accuracy: 0.01,
            "iOS 页面底部内边距应为 96（悬浮 Tab 栏会压住末卡；56 是 macOS 的值）")
        XCTAssertEqual(SettingsMetrics.pageMaxContentWidth, 720, accuracy: 0.01,
                       "iOS 内容列上限 720（iPhone 402pt 上是 no-op，iPad 全屏才生效）")
    }

    /// hub **最底部**必须有 TMDB 署名（官方字标 + 官方那句英文）。
    ///
    /// 判据是「页面下方能找到一块大幅亮于背景的**彩色**像素」——字标是官方渐变
    /// （`#90cea1 → #00b3e5`），深灰底上「有彩色」就是它在了；同时钉住
    /// 「署名没被误做成模板渲染（那会变纯白单色）」。
    ///
    /// 画布拉长到 1400pt：`ScrollView` 承载下内容不滚动才能保证页脚在树里/画面内
    /// （固定 874pt 的其它用例会把它推到屏幕外——同样场景旧版用 1400pt 解决）。
    func testTMDbAttributionRendersAtPageBottom() throws {
        let tall = CGSize(width: screen.width, height: 1400)
        let bitmap = try renderHub(scheme: .dark, size: tall, base: Color(white: 0.20))

        // 页脚在内容流末尾：10 行卡之后。整页高度 1400 里它落在下半段（实测 ≈0.58–0.66），
        // 取 0.55 以下扫描既避开卡片，又完整包含页脚。
        let chroma = bitmap.maxChromaBelow(fraction: 0.50)
        print("[SettingsLayoutTests] TMDb footer maxChroma(below 50%)=\(chroma)")
        XCTAssertGreaterThanOrEqual(
            chroma, 40,
            "页面下方找不到 TMDB 字标的彩色（最大色度 \(chroma)）："
            + "署名要么没挂上，要么被 `.renderingMode(.template)` 洗成了单色——"
            + "官方字标必须保持品牌配色。")
    }

    /// **三个品牌行图标都必须是单色**——和 SF Symbol 行图标同色（`.primary`）。
    ///
    /// 用户口径（2026-10-13）：「把 tmdb 元数据补充的那个 logo 改成和 bangumi、
    /// moviepilot 的一样的颜色」。TMDB 那份资产是**官方彩色渐变字标**（绿→蓝），
    /// 它自己在 imageset 里**没有** `template-rendering-intent`，所以只要
    /// `SettingsRowIcon` 的 `.brand` 分支漏掉 `.renderingMode(.template)`，这一行的
    /// 图标就会是一行彩色、跟旁边两行不是一回事——正是用户指出的那个不一致。
    ///
    /// **为什么用受控的三行小卡而不是真 hub**：离屏 `layer.render` 拿不到
    /// `glassEffect` 的真实合成环境，真 hub 的第二、三张卡里的行内容会按 UIKit 的
    /// 默认 trait 解析动态色（实测暗色截图里那些行整行是黑的，见本文件顶部「测量
    /// 路线」）。这条用例要钉的是**品牌资产是否模板渲染**，与玻璃合成无关，所以
    /// 用 B 方案自己的原语搭一张只装三行品牌行的小卡、垫**中灰**（0.5）底：
    /// 白色与黑色 ink 都能被检出，任何饱和色也藏不住。
    func testBrandRowIconsAreMonochrome() throws {
        let rows: [SettingsSubpage] = [.bangumi, .moviepilot, .tmdb]
        let base = Color(white: 0.5)
        let canvas = CGSize(width: screen.width, height: 400)

        let page = SettingsGlassPage {
            SettingsGlassSection {
                ForEach(rows, id: \.self) { subpage in
                    SettingsNavRow(title: subpage.title, icon: subpage.icon) {}
                    SettingsGlassDivider()
                }
            }
        }
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.contentLeading, contentLeading)
        .environment(\.colorScheme, .dark)
        .environment(\.displayScale, scale)
        .frame(width: canvas.width, height: canvas.height)
        .background(base)

        let image = try snapshot(page, size: canvas, scheme: .dark)
        let bitmap = try SettingsBitmap(image: image, scale: scale)
        let spreads = bitmap.iconColumnChannelSpreads(
            contentLeading: contentLeading, baseOverride: 128)

        XCTAssertEqual(
            spreads.count, rows.count,
            "图标列应量到 \(rows.count) 条行图标（三行品牌行各一个），实际 \(spreads.count) 条："
            + "行距/图标列位置或卡片布局变了，判据要跟着复核（量到的色偏：\(spreads)）")
        print("[SettingsLayoutTests] brand icon spreads=\(spreads)")
        for (index, spread) in spreads.enumerated() where index < rows.count {
            XCTAssertLessThan(
                spread, 24,
                "「\(rows[index].title)」的行图标色偏是 \(spread)（应 <24，单色）："
                + "它还是品牌原色——`SettingsRowIcon` 的 `.brand` 分支漏了 "
                + "`.renderingMode(.template)`，或这一行的图标没走 `SettingsNavRow`。")
        }
    }

    // MARK: - 反向对照（证明量尺不是「对什么页面都报数」）

    /// **反向对照**：同样的页面承载、同样的已知底色，但**不装玻璃卡**、不画分隔线时，
    /// 两条量尺必须都量不到东西。
    ///
    /// 为什么需要这条：正向用例只能证明「量到了」，证明不了「量到的就是卡的描边」。
    /// 本仓的老教训是判据会悄悄变成恒真（分隔线绝对值那条就曾被写成定义本身）。
    /// 这里用**同一套脚手架**渲染一个没有 `SettingsGlassCard`、没有
    /// `SettingsGlassDivider` 的页面：若 `cardEdges` / `separatorLeading` 仍返回
    /// 非 nil，说明它们量的是别的东西（例如页面底色噪声、文字横线），正向用例的
    /// 结论就不成立。容器用的是真 `SettingsGlassPage`（共享字号/留白/行距），
    /// 只是把「卡」这一层拿掉。
    func testDetectorsRejectPageWithoutGlassCard() throws {
        let canvas = CGSize(width: screen.width, height: 700)
        let base = Color(white: 0.20)

        let page = SettingsGlassPage {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardRowMinHeight) {
                ForEach(SettingsHub.groups.flatMap(\.subpages), id: \.self) { subpage in
                    Text(subpage.title).foregroundStyle(.primary)
                }
            }
        }
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.contentLeading, contentLeading)
        .environment(\.colorScheme, .dark)
        .environment(\.displayScale, scale)
        .frame(width: canvas.width, height: canvas.height)
        .background(base)

        let image = try snapshot(page, size: canvas, scheme: .dark)
        let bitmap = try SettingsBitmap(image: image, scale: scale)

        XCTAssertNil(
            bitmap.cardEdges(expectedLeading: contentLeading),
            "没有玻璃卡却量到了「卡缘描边」：卡片判据在任何页面上都会成立，正向用例无意义")
        XCTAssertNil(
            bitmap.separatorLeading(),
            "没有分隔线却量到了「分隔线」：分隔线判据在文字横线上也会成立")
    }

    // MARK: - 渲染

    /// 把真设置 hub 挂进离屏 `UIWindow` 布局一帧再画进位图。
    ///
    /// 背景给**已知**底色（深 0.20 / 亮 0.78）：判据是「卡缘描边相对页面底的亮度阶跃」，
    /// 底必须是已知量。底跟着外观走，而不是两档共用一个值——产品里页面底色本身就随
    /// 外观变，写死深底再跑亮色会量出测试脚手架造出来的差值（旧版踩过：亮色报 145）。
    private func renderHub(
        scheme: ColorScheme,
        size: CGSize? = nil,
        base: Color? = nil
    ) throws -> SettingsBitmap {
        let app = AppModel()
        app.phase = .ready
        let canvas = size ?? screen
        let pageBase = base ?? (scheme == .dark ? pageBaseDark : pageBaseLight)

        let view = SettingsView()
            .environment(app)
            .environment(BangumiCoordinator())
            .environment(MoviePilotCoordinator())
            .environment(DanmakuModel())
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.contentLeading, contentLeading)
            .environment(\.colorScheme, scheme)
            .environment(\.displayScale, scale)
            .frame(width: canvas.width, height: canvas.height)
            .background(pageBase)

        let image = try snapshot(view, size: canvas, scheme: scheme)
        if let png = Self.pngData(from: image) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "settings-hub-\(scheme == .dark ? "dark" : "light").png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return try SettingsBitmap(image: image, scale: scale)
    }

    private func snapshot(_ view: some View, size: CGSize, scheme: ColorScheme) throws -> CGImage {
        #if os(iOS)
        let controller = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        // **必须把窗口的 trait 也钉成同一档**：`.environment(\.colorScheme, …)` 只改
        // SwiftUI 环境，`Color.primary` / 模板图标的 tint 是**动态颜色**，最终按
        // UIKit trait 解析。只注入 environment 时，离屏 `layer.render` 里玻璃卡内容
        // 会按窗口（默认 light）解析，暗色截图里出现「标题是黑的」——量到的不是产品。
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // SwiftUI 的首帧要过一次 runloop 才会把内容放上图层树。玻璃卡的内容是
        // 异步合成的，跑两轮并在中间再布局一次，免得截到只画了一半的中间帧。
        for _ in 0..<2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

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

    struct CardEdges {
        /// 卡左/右缘（pt，距屏缘）。
        let leading: CGFloat
        let trailing: CGFloat
        /// 卡缘描边相对页面底的**有符号**亮度差（描边是 `Color.primary.opacity(0.08)`：
        /// 深色底为正、亮色底为负）——方向钉住「`Color.primary` 跟着外观翻」。
        let leadingSigned: Double
        let trailingSigned: Double
        /// 上面两者的绝对值：只判「描边画出来没有」，与外观无关。
        var leadingContrast: Double { abs(leadingSigned) }
        var trailingContrast: Double { abs(trailingSigned) }
        /// 两缘同时成立的行数（pt）：证明描边是纵向连续的线，不是一次巧合。
        let lineHeight: CGFloat
        var width: CGFloat { trailing - leading }
        /// 卡内背景相对页面底的亮度差——**玻璃在离屏渲染里出不出图的证据**。
        /// 出图则 ≠0；不出图则 ≈0（这时卡的可见性完全由描边承担）。
        let interiorDelta: Double
    }

    /// 找卡片左右缘：在注入留白附近逐行找「相对页面底 ≥4 luma 的亮度阶跃」，
    /// 取出现次数最多的列作为卡缘，并要求两缘同时成立。
    func cardEdges(expectedLeading: CGFloat) -> CardEdges? {
        let (bytes, width, height) = pixels()
        guard width > 0, height > 0 else { return nil }
        let base = pageBaseLuminance()

        func luma(_ x: Int, _ y: Int) -> Double {
            let o = (y * width + x) * 4
            return Double(Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2])) / 3
        }

        let radius = Int(3 * scale)
        let leftCenter = Int(expectedLeading * scale)
        let rightCenter = width - Int(expectedLeading * scale)
        let step = 4.0
        var leftCounts: [Int: Int] = [:]
        var rightCounts: [Int: Int] = [:]
        var leftSums: [Int: Double] = [:]
        var rightSums: [Int: Double] = [:]
        var edgeRows: [Int] = []

        for y in 0..<height {
            var left: (x: Int, dev: Double)?
            for x in (leftCenter - radius)...(leftCenter + radius) where x >= 0 && x < width {
                let dev = luma(x, y) - base
                if abs(dev) >= step, abs(dev) > abs(left?.dev ?? 0) { left = (x, dev) }
            }
            var right: (x: Int, dev: Double)?
            for x in (rightCenter - radius)...(rightCenter + radius) where x >= 0 && x < width {
                let dev = luma(x, y) - base
                if abs(dev) >= step, abs(dev) > abs(right?.dev ?? 0) { right = (x, dev) }
            }
            guard let l = left, let r = right else { continue }
            leftCounts[l.x, default: 0] += 1
            rightCounts[r.x, default: 0] += 1
            leftSums[l.x, default: 0] += l.dev
            rightSums[r.x, default: 0] += r.dev
            edgeRows.append(y)
        }

        guard edgeRows.count >= Int(100 * scale),
              let leftPx = leftCounts.max(by: { $0.value < $1.value })?.key,
              let rightPx = rightCounts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        // 卡内背景亮度：在两缘都成立的行上，取中线列亮度；取低分位避开文字/图标 ink。
        let centerX = width / 2
        var interior: [Double] = edgeRows.map { luma(centerX, $0) }
        interior.sort()
        let interiorBg = interior.isEmpty ? base : interior[interior.count / 10]

        return CardEdges(
            leading: CGFloat(leftPx) / scale,
            trailing: CGFloat(rightPx) / scale,
            leadingSigned: (leftSums[leftPx] ?? 0) / Double(leftCounts[leftPx] ?? 1),
            trailingSigned: (rightSums[rightPx] ?? 0) / Double(rightCounts[rightPx] ?? 1),
            lineHeight: CGFloat(edgeRows.count) / scale,
            interiorDelta: interiorBg - base
        )
    }

    /// 相邻「文字/图标 ink 带」的行心距（pt），按从上到下排列。
    ///
    /// ink 判据取**高阈值**（亮像素）：行标题是 `.primary`（暗色 = 近白），
    /// 而段标题是 `.secondary` 灰、卡底/描边都比行标题暗一档，高阈值正好把
    /// 它们排除在带外。
    func inkBandGaps() -> [CGFloat] {
        let (bytes, width, height) = pixels()
        var rowInk = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width {
                let o = (y * width + x) * 4
                let luma = (Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2])) / 3
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
    /// 找候选点、并要求该行有 250pt 以上宽度的候选（= 卡的横向描边线也会满足长度，
    /// 所以另外要求起点 >50pt：卡顶/底描边从卡缘 ~16pt 开始，分隔线从 69pt 开始），
    /// 才能把「文字的一横」和卡框线都滤掉。
    func separatorLeading() -> CGFloat? {
        let (bytes, width, height) = pixels()

        func luma(_ x: Int, _ y: Int) -> Double {
            let o = (y * width + x) * 4
            return Double(Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2])) / 3
        }

        for y in Int(100 * scale)..<min(height, Int(800 * scale)) where y >= 3 {
            var firstX: Int?
            var bright = 0
            for x in Int(20 * scale)..<Int(382 * scale) {
                if luma(x, y) > luma(x, y - 3) + 2 {
                    if firstX == nil { firstX = x }
                    bright += 1
                }
            }
            if bright > Int(250 * scale), let fx = firstX, fx > Int(50 * scale) {
                return CGFloat(fx) / scale
            }
        }
        return nil
    }

    /// 每行**图标框内**的最大通道极差（单色 → 接近 0）。
    ///
    /// 图标框横向：卡缘 `contentLeading` + 卡内容内缩 `cardContentInset` 起，宽
    /// `iconColumnWidth`——这一侧是确定的（有专门的用例钉住卡缘与卡内边距）。
    ///
    /// 纵向**不假设行位置**，而是按「ink 带」切：卡内行距/段间距都不是这条要钉的，
    /// 扫一列 ink 剖面、把连续 ink 归成带，就是「有几行图标」。
    func iconColumnChannelSpreads(
        contentLeading: CGFloat,
        baseOverride: Double? = nil
    ) -> [Int] {
        let (bytes, width, height) = pixels()
        let x0 = min(Int((contentLeading + SettingsMetrics.cardContentInset) * scale), width - 1)
        let x1 = min(x0 + Int(SettingsMetrics.iconColumnWidth * scale), width)
        // ink 判据用「与底色偏差」而不是「比底色亮」：模板图标在暗色下是白、
        // 亮色下是黑，两种都得算 ink。底色默认取页面底实测值。
        let base = baseOverride ?? pageBaseLuminance()

        func channelSpread(_ x: Int, _ y: Int) -> Int? {
            let o = (y * width + x) * 4
            let r = Int(bytes[o]), g = Int(bytes[o + 1]), b = Int(bytes[o + 2])
            let luma = Double(r + g + b) / 3
            guard abs(luma - base) > 45 else { return nil }
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
    func maxChromaBelow(fraction: Double) -> Double {
        let (bytes, width, height) = pixels()
        var best = 0.0
        // 只扫横向中段：避开页面底在左右边缘的色（那是背景本身）。
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

    /// 页面底（卡外）的亮度基准：取左边缘 `0…(contentLeading−4)pt` 那几列的均值
    /// ——卡缘描边带在注入留白处，避开它；整列全是注入的纯色底。
    private func pageBaseLuminance() -> Double {
        let (bytes, width, height) = pixels()
        guard width > 0, height > 0 else { return 0 }
        var total = 0.0, count = 0
        let margin = min(Int(8 * scale), width)
        for y in 0..<height {
            for x in 0..<margin {
                let o = (y * width + x) * 4
                total += Double(Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2])) / 3
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
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

// MARK: - 跨平台常量（不受 iOS-only 类级 skip 影响）

/// 常量级断言：**两个平台都能跑**，所以单独开一个类。
///
/// 为什么不挂在 `SettingsLayoutTests` 里：那个类的 `setUpWithError` 在 macOS 上整份
/// `XCTSkip`（那 10 条渲染判据用的是紧凑版式，macOS 走常规版式、读数不同）。XCTest 的
/// 类级 skip 会**连坐该类所有用例**，于是「macOS 的行模型常量」放进去就永远不执行——
/// 2026-10-22 review 正是抓到 macOS 侧（30 / 6 / 42 / 780 / 56）零断言。
@MainActor
final class SettingsGlassMetricsTests: XCTestCase {
    /// macOS 的行模型：卡内操作行 30 + 上下各 6 = 行距 42；内容列上限 780；底部 56。
    ///
    /// 这些数只被 `SettingsCardRowLayout` 消费，改坏了没有渲染用例能发现（macOS 端
    /// 的渲染判据不在本仓测试里），所以这里把绝对值钉死。
    func testMacRowModelMatchesTheDocumentedNumbers() {
        #if os(macOS)
        XCTAssertEqual(SettingsMetrics.cardRowMinHeight, 30, accuracy: 0.01,
                       "macOS 卡内操作行最小高 30（比原表单行 28 略松）")
        XCTAssertEqual(SettingsMetrics.rowVerticalInset, 6, accuracy: 0.01,
                       "macOS 行上下内边距 6（`Form` 时代是 0——行距由系统给）")
        XCTAssertEqual(
            SettingsMetrics.rowPitch, 42, accuracy: 0.01,
            "macOS 行距 = 30 + 6×2 = 42：`Form` 时代实测 28，玻璃卡里 42 才有下载页那种量感")
        XCTAssertEqual(SettingsMetrics.pageMaxContentWidth, 780, accuracy: 0.01,
                       "macOS 设置页内容列上限 780：窗口再宽也不横铺")
        XCTAssertEqual(SettingsMetrics.pageBottomInset, 56, accuracy: 0.01)
        #else
        XCTAssertEqual(SettingsMetrics.pageMaxContentWidth, 720, accuracy: 0.01)
        #endif
    }

    /// 「内容卡必须是玻璃，不能退回 material / 实底」——**源码级守卫**。
    ///
    /// 为什么需要它：退役的 `testCardFillStaysTranslucent` 原本量「氛围图透出度」
    /// （亮 ≥0.60 / 暗 ≥0.80），换成玻璃后那条**无法**用像素方式重建——`glassEffect`
    /// 需要窗口合成器，离屏 `layer.render` 里画不出来（见 `SettingsLayoutTests` 类注释）。
    /// 于是「卡是不是玻璃」这件事在离屏测试里**完全没有守卫**：把 `liquidGlassCard()`
    /// 换成 `.background(.regularMaterial)`，10 条渲染用例照样全绿。
    ///
    /// 折中的守卫：**全仓内容卡不许再出现 material 底**。
    /// * `App/Shared/Features` 下 `ultraThinMaterial` / `thinMaterial` / `regularMaterial`
    ///   / `thickMaterial` 计数必须为 0（2026-10-22 收编后实际就是 0，只剩注释提及）；
    /// * 允许扫到注释里的历史说明（`// … .ultraThinMaterial …`），因为那是记录而不是用法。
    ///
    /// 边界：抓不到「换成 `.background(Color.white)`」这种非 material 的实底——所以
    /// **真机截图的视觉终审仍是唯一完整闸门**，这条只是拦住最可能的重构回退。
    func testNoMaterialCardBackgroundsRemainInFeatures() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppTests/
            .deletingLastPathComponent()   // repo root
        let features = repoRoot.appendingPathComponent("App/Shared/Features")

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil),
            "扫不到 App/Shared/Features：路径变了，这条守卫要跟着改")

        // 覆盖 `.bar` 与全部 material 档：**只列 `ultraThinMaterial` 会漏掉
        // `.background(.bar)` 这类「同属材质、写法不同」的退路**（2026-10-22 复审指出）。
        let banned = [
            "ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial",
            "ultraThickMaterial", ".bar)",
        ]
        // 显式豁免：**chrome（浮动/吸附控件）不是内容卡**，用材质是正当的。
        // 在那一行前面加 `// glass-guard-exempt: <理由>` 即可（必须写理由，方便以后复核）。
        let exemptMarker = "glass-guard-exempt:"
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                XCTFail("读不到 \(file.lastPathComponent)：守卫失效，别让它静默跳过")
                continue
            }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 注释里提到旧材质名是**记录**，不是用法。
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                    continue
                }
                guard let hit = banned.first(where: { trimmed.contains($0) }) else { continue }
                // 豁免有两种写法，都认：
                //  ① **同行尾部注释**：`.background(.bar)   // glass-guard-exempt: 理由`
                //  ② **上方连续注释块**：豁免说明写在用法正上方（可能好几行）
                // 为什么要支持两种：① 最不容易失效（链式调用中间常隔着实参行，
                // 向上扫会在那里断掉——2026-10-22 review 就复现了这次失败）；
                // ② 便于写多行理由。
                if line.contains(exemptMarker) { continue }
                var scan = index - 1
                var exempted = false
                while scan >= 0 {
                    let above = lines[scan].trimmingCharacters(in: .whitespaces)
                    if above.isEmpty {
                        scan -= 1
                        continue
                    }
                    guard above.hasPrefix("//") || above.hasPrefix("*") || above.hasPrefix("/*")
                    else { break }
                    if above.contains(exemptMarker) { exempted = true; break }
                    scan -= 1
                }
                if exempted { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1) 用了 \(hit)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "内容卡必须走玻璃原语（`liquidGlassCard` / `glassPanel` / `hoverRowHighlight`），"
            + "不许退回 material。发现 \(offenders.count) 处：\n" + offenders.joined(separator: "\n"))
    }

    /// 玻璃原语仍在被广泛使用（防止「没人用但测试还绿」）。
    ///
    /// 与上一条互补：上一条防「退回 material」，这一条防「玻璃调用点被整体删掉/替换成
    /// 纯色」——只要全仓玻璃调用点数量掉下地板就红。地板取 24（2026-10-22 实测 32，
    /// 留 8 个的余量给以后可能的重构删减），不是精确值，所以刻意设成 `<` 而不是 `==`。
    func testGlassPrimitiveCallSitesDoNotRegress() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDir = repoRoot.appendingPathComponent("App")

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        var count = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                // **要数全「玻璃原语」这一族**，不能只数两个（2026-10-22 review 指出）：
                // 只数 `liquidGlassCard` / `liquidGlassCapsule` 的话，把 Bangumi 行卡
                // （`hoverRowHighlight`）、登录面板（`glassPanel`）、HUD（裸 `glassEffect`）
                // 全改回纯色，这条守卫依然绿。地板同步抬到 40（实测 32 card/capsule
                // + 2 hoverRowHighlight + 1 glassPanel + 11 裸 glassEffect ≈ 46）。
                let isGlassCall = trimmed.contains(".liquidGlassCard(")
                    || trimmed.contains(".liquidGlassCapsule(")
                    || trimmed.contains(".hoverRowHighlight(")
                    || trimmed.contains(".glassPanel(")
                    || trimmed.contains(".glassEffect(")
                if isGlassCall { count += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(
            count, 40,
            "全仓玻璃原语调用点只剩 \(count) 处（地板 40）：内容卡可能被换回了纯色/material。"
            + "UI 统一成液态玻璃是 2026-10-22 的用户口径，别默默回退。")
        // 上界只作提示不当断言：玻璃数量应随功能增长，涨了不该红。
    }
}
