import AppDesignKit
import MoviePilotKit
import SwiftUI
import XCTest
@testable import OcPlayer

/// MoviePilot 搜索结果卡的**几何回归钉子**（方案 A：紧凑档两段式）。
///
/// ## 为什么要钉几何，而不是钉像素
///
/// 线上那张截图（文字被压成 156pt 高的「竖条」、胶囊只剩 `+` / 放大镜）的根因是
/// 「动作区和文字列塞进同一个 `HStack`，负空间先压 `Text`」。这种结构性回归**不会
/// 报编译错、也不会让任何断言失败**，只会在真机上把中文压成竖排 —— 唯一稳定的判据
/// 是卡片在给定宽度下渲染出来的**尺寸**：
///
/// - 旧版（动作在信息行内）：文字被迫竖排，卡片被撑到 ≈262pt 高；
/// - 新版紧凑档：文字拿满 238pt，正文两行封顶，卡高回落到 ≈186pt；
/// - 新版常规档：动作留在行内，卡高 ≈142pt。
///
/// 这里用 `ImageRenderer`（同步、单帧）渲染真实卡片，量 `cgImage` 的宽高。
/// 不比对像素内容：Liquid Glass 的材质在不同系统版本上本来就会变，几何才是契约。
///
/// - Note: 液态玻璃在 `ImageRenderer` 里只画得出占位符（黄底红叉），所以这里的
///   快照**只适合量尺寸、不适合看版式**；要看真实观感用
///   `MoviePilotMediaCardSnapshotTests`（走 `UIWindow` + `drawHierarchy` 的真合成链路）。
///
/// - Note: 断言给的是**区间**而不是等值。Dynamic Type 的基准字号随系统设置浮动，
///   等值断言会在别人的机器上无故变红；判据的核心是「落在两段式的档位里」。
///
/// ## 反向验证（2026-10-27 实做过，不是推测）
///
/// 为了确认这些断言真的能抓住回归，做过一次注入实验：把紧凑档动作区**塞回信息行**
/// （只回退结构，保留 `fixedSize` + `FlowLayout` —— 这是未来最可能发生的重构形态），
/// 然后只跑本类。结果（`-only-testing:OcPlayerTests/MoviePilotMediaCardLayoutTests`）：
///
/// | 断言 | 形态②（只回退结构） |
/// | --- | --- |
/// | `testCompactCardShapeMatchesSparseContent` | **红**（极简 / 完整内容高度不再相等） |
/// | `testCompactCardHeightIndependentOfActionRowWidth` | **红**（两档绝对上界被突破） |
/// | `testCompactCardUsesTwoSectionLayoutHeight` | 绿（≈202 落在 200 边界外侧，**漏判**） |
/// | `testRegularCardKeepsSingleRowActions` | 绿 |
/// | `testSubscribedStateDoesNotChangeCardGeometry` | 绿 |
///
/// 结论：**形态② 由前两条兜住**；`height ≤ 200` 那条单独并不够（这也是上界从 240 收到
/// 200 之后仍然留不住它的原因——所以必须有 `testCompactCardShapeMatchesSparseContent`
/// 这条等式钉子）。整份回退到旧实现（chip 也退回裸 `HStack`）时卡高 ≈262，
/// `testCompactCardUsesTwoSectionLayoutHeight` 同样会红。
@MainActor
final class MoviePilotMediaCardLayoutTests: XCTestCase {

    // MARK: - 夹具

    /// 复刻用户截图里那条结果的字段形态（TMDB 源 + 完整四枚标签 + 一句话简介）。
    private static func media(
        overview: String? = "花街出身的药师少女猫猫被拐入后宫，凭药学知识破解宫中一桩桩悬案。"
    ) -> MPMediaInfo {
        var raw: [String: JSONValue] = [
            "media_source": .string("tmdb"),
            "type": .string("电视剧"),
            "title": .string("药屋少女的呢喃"),
            "year": .string("2023"),
            "media_id": .string("tmdb:209867"),
            "tmdb_id": .number(209_867),
            "vote_average": .number(8.7),
        ]
        if let overview { raw["overview"] = .string(overview) }
        return MPMediaInfo(raw: raw)
    }

    /// 极简字段：只有片名与来源，没有标签、没有评分、没有简介。
    private static func bareMedia() -> MPMediaInfo {
        MPMediaInfo(raw: [
            "media_source": .string("douban"),
            "title": .string("无标签条目"),
        ])
    }

    /// 裸卡片本体（不含外层 `frame` / `environment`）。
    ///
    /// 只给「要按具体形状操作卡片内部」的用例用——`card(...)` 返回的是 `some View`，
    /// 在它上面访问 `.compactActionRow` 是编译错误（`some View` 不暴露具体类型的成员），
    /// 而那行在 `#if os(iOS)` 里，只有 iOS 测试 target 会报错、macOS 看不出来。
    private func cardBody(
        media: MPMediaInfo? = nil,
        subscribed: Bool = false
    ) -> MoviePilotMediaGlassCard {
        MoviePilotMediaGlassCard(
            media: media ?? Self.media(),
            isSubscribed: subscribed,
            isAdding: false,
            onQuickSubscribe: {},
            onConfigureSubscribe: {},
            onOpenResource: {}
        )
    }

    /// 卡片本体（`contentLeading 22` 页面留白由调用方提供，这里只给卡宽）。
    private func card(
        width: CGFloat,
        sizeClass: UserInterfaceSizeClass,
        media: MPMediaInfo? = nil,
        subscribed: Bool = false,
        sizeCategory: DynamicTypeSize = .large
    ) -> some View {
        MoviePilotMediaGlassCard(
            media: media ?? Self.media(),
            isSubscribed: subscribed,
            isAdding: false,
            onQuickSubscribe: {},
            onConfigureSubscribe: {},
            onOpenResource: {}
        )
        .frame(width: width)
        .environment(\.horizontalSizeClass, sizeClass)
        .environment(\.dynamicTypeSize, sizeCategory)
        .environment(\.colorScheme, .dark)
        .background(Color.black)
    }

    /// 渲染一帧并返回像素尺寸（scale = 1，故 1px = 1pt）。
    ///
    /// 设了 `OCPLAYER_TEST_SNAPSHOT_DIR` 时顺带把位图写出去，供人工核对版式
    /// （几何断言过了但观感不对的情况，只有看图才发现得了）。
    private func renderedSize(
        _ view: some View,
        name: String = "card",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出位图", file: file, line: line)
        writeSnapshotIfRequested(image, name: name)
        return CGSize(width: image.width, height: image.height)
    }

    private func writeSnapshotIfRequested(_ image: CGImage, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OCPLAYER_TEST_SNAPSHOT_DIR"],
              !dir.isEmpty
        else { return }
        #if canImport(UIKit)
        let bitmap = UIImage(cgImage: image)
        guard let data = bitmap.pngData() else { return }
        #elseif canImport(AppKit)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        #endif
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    // MARK: - 紧凑档（iPhone 竖屏）

    /// 卡外宽 358pt（402 − 左右留白 22×2）时，卡片应落在**两段式**的档位。
    ///
    /// 高度可以逐项推导，不是拍脑袋的区间：
    /// `28(上下 padding 14×2) + 114(海报 76÷2×3) + 12(VStack spacing) + 32(胶囊) = 186`。
    /// 上界取 186 + 14 = **200**：留 14pt 给 Dynamic Type 默认档的字号浮动，但**不再给
    /// 「动作区塞回信息行」留余量**——那种形态下卡片会被顶到 ≈202 起，正是要靠这条拦住的。
    ///
    /// - Important: 这条只对「整份或结构性回退」有效。实测（见审查报告 §7）：
    ///   如果只把动作区塞回 `HStack`、**保留** `fixedSize` + `FlowLayout`，卡高 ≈202 落在
    ///   200 边界附近、可能漏判；那种形态由 `testCompactCardShapeMatchesSparseContent`
    ///   的等式钉子兜住。
    func testCompactCardUsesTwoSectionLayoutHeight() throws {
        let size = try renderedSize(card(width: 358, sizeClass: .compact), name: "compact")

        XCTAssertEqual(size.width, 358, accuracy: 1, "卡片没吃满给定宽度")
        XCTAssertLessThanOrEqual(
            size.height, 200,
            "紧凑档卡高 \(size.height)pt 超出推导值 186（+14 缓冲）：动作区多半又回到信息行里，"
                + "文字会被压成竖排 —— 线上那根「纺锤形竖条」就是这个成因"
        )
        XCTAssertGreaterThanOrEqual(size.height, 160, "紧凑档卡高 \(size.height)pt 过低，信息段可能被裁掉了")
    }

    /// 动作区在紧凑档必须**独占一行**：把动作条宽度收窄不会改变卡高（它本来就在独立一行），
    /// 但用更长的标题会让信息段变高。这里反向钉住「高度由信息段决定，而不是由动作区决定」。
    func testCompactCardHeightIndependentOfActionRowWidth() throws {
        // 卡宽 358 与 402 两个尺寸下，动作条都只是「一行放得下」的两枚胶囊，
        // 高度不应因为少 44pt 宽度而暴涨（暴涨 = 动作区被压到需要换行/堆叠）。
        let narrow = try renderedSize(card(width: 358, sizeClass: .compact))
        let wide = try renderedSize(card(width: 402, sizeClass: .compact))
        XCTAssertLessThanOrEqual(
            narrow.height, wide.height + 2,
            "窄 44pt 后卡高从 \(wide.height) 涨到 \(narrow.height)：动作条被压到堆叠档了"
        )
        // 光有相对比较是不够的：两档「同等程度」地坏掉时 `narrow ≤ wide + 2` 反而恒绿。
        // 各补一条绝对上界（同为推导值 186 + 14）。
        XCTAssertLessThanOrEqual(narrow.height, 200, "358pt 档绝对高度超标：\(narrow.height)pt")
        XCTAssertLessThanOrEqual(wide.height, 200, "402pt 档绝对高度超标：\(wide.height)pt")
    }

    // MARK: - 常规档（iPad / macOS）

    /// 常规档（iPad 834pt 全宽 / macOS 最小窗 960pt）动作留在信息行右侧，卡高应明显矮于紧凑档。
    func testRegularCardKeepsSingleRowActions() throws {
        let compact = try renderedSize(card(width: 358, sizeClass: .compact))
        let regular = try renderedSize(card(width: 792, sizeClass: .regular), name: "regular")

        XCTAssertLessThan(
            regular.height, compact.height,
            "常规档卡高 \(regular.height) 不低于紧凑档 \(compact.height)：动作区该留在信息行内，不该再占一整行"
        )
        // 上界收到 155（推导值 142 + 13）：200 是无效上界——常规档要是错成两段式（≈186）也照样绿。
        XCTAssertLessThanOrEqual(
            regular.height, 155,
            "常规档卡高 \(regular.height)pt 超出预期（推导值 142）：动作区可能被误移到了第二行"
        )
    }

    // MARK: - 大字号兜底

    /// AX3 超大字号下卡只会变高（`ViewThatFits` 降级到堆叠档），**不能**变矮 —— 变矮意味着文字被截。
    ///
    /// - Note: **只能在 iOS 上跑**。macOS 的 Dynamic Type 不驱动 AppKit 字体缩放（字号由
    ///   辅助功能里的「更大文字」单独控制，`dynamicTypeSize` 环境值不改系统字体），
    ///   所以同一张卡在 macOS 上 AX3 前后高度恒等。那是平台的真实行为，不是回归；
    ///   把它跑在 macOS 上只会得到一条假红（实测 182 → 182）。
    ///   运行环境没有 iOS 尺寸类这一说，所以按 `#if` 门控而不是按环境值判断。
    #if os(iOS)
    func testAccessibilitySizeGrowsCardInsteadOfTruncating() throws {
        let normal = try renderedSize(card(width: 358, sizeClass: .compact, sizeCategory: .large))
        let ax3 = try renderedSize(card(width: 358, sizeClass: .compact, sizeCategory: .accessibility3), name: "compact-ax3")

        XCTAssertGreaterThan(
            ax3.height, normal.height,
            "AX3 下卡高没变（\(normal.height) → \(ax3.height)）：动作条没有降级到堆叠档，文字多半被截了"
        )

        // 上面那条只证明「整卡变高」，而文字变大本身也会让卡变高 —— 它抓不住
        // 「ViewThatFits 被删成只剩第一档」。这里直接量动作条：降级到堆叠档后
        // 高度应接近翻倍。
        let row = cardBody().compactActionRow
        let rowHeight = try renderedSize(row.frame(width: 330), name: "action-row")
        let axRowHeight = try renderedSize(
            row.frame(width: 330).environment(\.dynamicTypeSize, .accessibility3),
            name: "action-row-ax3"
        )
        XCTAssertGreaterThan(
            axRowHeight.height, rowHeight.height * 1.5,
            "AX3 下动作条高度只从 \(rowHeight.height) 变到 \(axRowHeight.height)（应接近 2×）："
                + "ViewThatFits 的降级档没生效，两枚胶囊文案会在 330pt 里溢出玻璃边界"
        )
    }
    #endif

    // MARK: - 内容维度

    /// **形态探针**：卡片高度必须由「海报 / 动作条」这两个固定量决定，而**不该**被
    /// 文字内容的多少左右。
    ///
    /// ## 为什么这条比「卡高 ≤ 200」更能抓住回归
    ///
    /// 未来最可能发生的回归不是「整份退回旧文件」（那会先撞编译错），而是**只把动作区
    /// 塞回信息行、保留 `fixedSize` + `FlowLayout`**。那种形态下 chip 不再竖排，卡高
    /// 落在 180–202 一带，`height ≤ 200` 边界上会漏判；但它有一个破绽：
    ///
    /// - 新版：信息段高 = max(海报 114, 文字列)。**极简内容（只一行标题 ≈22）与完整内容
    ///   （标题 + 标签 + 两行简介）都吃不满 114**，两者卡高**完全相等**（实测都是 186）。
    /// - 回退形态：动作区回到信息行后，信息列与胶囊争宽，文字被压缩 → 极简内容与完整
    ///   内容的高度**不再相等**（差出十几到几十 pt）。
    ///
    /// 所以「极简 == 完整」这个等式是结构正确的直接证据，比任何绝对阈值都灵敏。
    func testCompactCardShapeMatchesSparseContent() throws {
        let rich = try renderedSize(card(width: 358, sizeClass: .compact), name: "compact")
        let bare = try renderedSize(
            card(width: 358, sizeClass: .compact, media: Self.bareMedia()),
            name: "compact-bare"
        )

        XCTAssertEqual(
            bare.height, rich.height, accuracy: 2,
            "极简内容卡高 \(bare.height) 与完整内容 \(rich.height) 不等：信息段高度被文字内容左右了 ——"
                + "说明文字列仍在参与横向宽度竞争（动作区多半又回到信息行里）。"
                + "结构正确的实现里，海报 114pt 恒定主导信息段，两种内容应当等高"
        )
    }

    /// 已订阅态：胶囊文案从「订阅」变「已订阅」（多一个字），不得让卡片结构变形。
    func testSubscribedStateDoesNotChangeCardGeometry() throws {
        let plain = try renderedSize(card(width: 358, sizeClass: .compact))
        let subscribed = try renderedSize(card(width: 358, sizeClass: .compact, subscribed: true), name: "compact-subscribed")

        XCTAssertEqual(
            subscribed.height, plain.height, accuracy: 1,
            "「已订阅」比「订阅」多一个字，却改变了卡高：胶囊仍在参与横向宽度竞争"
        )
    }
}
