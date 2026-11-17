import AppDesignKit
import CoreModel
import ImageIO
import JellyfinKit
import SwiftUI
import XCTest

@testable import OcPlayer

/// 首页（紧凑宽度）的**实际渲染几何**：真 `HomeView` + 真 `AppModel` + 替身服务器，
/// 离线渲染成位图后从像素里量——每条栏位的卡片多大、栏位之间留多少空。
///
/// 为什么量像素而不是断言常量：这次的口径来自用户拿对照产品截的图
/// （「每个栏位之间间距没那么大」「最近添加比例较小」），判据是**用户看到的那些
/// 数字**——栏位间距与卡片画幅都是「好几个 token + 卡片内部留白 + 固定框高度」
/// 一起算出来的结果，断言单个常量挡不住「token 没动、观感却回去了」这类回归。
@MainActor
final class HomeLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        // 紧凑宽度（手机）版式是 iOS 专有路径：macOS 上 `horizontalSizeClass` 恒为
        // nil，AppShell 永远走常规版式（见 `AppShellView.contentLeading`）。
        #if !os(iOS)
        throw XCTSkip("紧凑宽度版式只在 iOS 上存在")
        #endif
    }

    /// iPhone 16/17 Pro（用户对照截图那台的量级）：402 × 874pt。
    private let screen = CGSize(width: 402, height: 874)
    private let scale: CGFloat = 2

    // MARK: - 用例

    /// 「最近添加」是 **16:9 横版小卡**（对照 Rex 的首页「最近更新」），不是海报卡、
    /// 也不是剧照卡：宽 `compactLatestWidth`、图高＝宽 × 9/16。
    /// 改之前这一栏是 2:3 海报卡（120 宽 / 180 高，面积是现在这张的两倍多）。
    func testLatestRailRendersLandscapeCardAtLatestWidth() throws {
        let bitmap = try renderHome()
        let rail = try XCTUnwrap(bitmap.rail(named: 1), "没渲染出「最近添加」栏")

        XCTAssertEqual(rail.cardWidth, Metrics.compactLatestWidth, accuracy: 2,
                       "「最近添加」卡宽应是最新那档（≈165pt），不是海报卡 120 / 剧照卡 240")
        XCTAssertEqual(rail.cardHeight / rail.cardWidth, 9.0 / 16.0, accuracy: 0.05,
                       "「最近添加」必须是 16:9 横版（对照 Rex「最近更新」）")
    }

    /// 「继续观看」「媒体库」仍是 16:9 剧照卡（240 宽）——这次只动「最近添加」。
    func testOtherRailsKeepStillCardWidth() throws {
        let bitmap = try renderHome()
        for index in [0, 2] {
            let rail = try XCTUnwrap(bitmap.rail(named: index), "没渲染出第 \(index + 1) 条栏位")
            XCTAssertEqual(rail.cardWidth, Metrics.compactStillWidth, accuracy: 2)
            XCTAssertEqual(rail.cardHeight / rail.cardWidth, 9.0 / 16.0, accuracy: 0.05)
        }
    }

    /// 栏位之间：上一条栏位**文案底** → 下一条栏位**标题 ink 顶**。
    ///
    /// 对照 Rex 的首页实测 ≈42pt（用户口径「间距没那么大」）；本 App 改之前是 60.5pt
    /// （用户截图那台机器更宽，量到 66–73pt）。实测现值 **42.5 / 42.0pt**——
    /// 与对照产品基本重合。老 token（悬停内边距 28 + 栏位顶距 24 + 标题间距 14）
    /// 会把这 +22pt 加回去：把三个 token 改回去，这条用例当场红（实测 60.5 / 60.0pt）。
    func testGapBetweenRailsStaysTight() throws {
        let bitmap = try renderHome()
        let gaps = try bitmap.gapsBetweenRails()
        XCTAssertEqual(gaps.count, 2, "三条栏位之间应有两段间距：量到 \(gaps)")
        for gap in gaps {
            XCTAssertGreaterThanOrEqual(gap, 26, "栏位之间太挤（\(gap)pt），标题会压到上一栏的卡片上")
            XCTAssertLessThanOrEqual(gap, 52, "栏位之间又松回 \(gap)pt 了（Rex ≈42pt、现在 42pt，改之前 60.5pt）")
        }
    }

    /// 栏位内部：标题 ink 底 → 封面框顶。实测现值 28.5pt（老实现 ≈45pt）。
    /// 比 Rex 的 ≈17pt 松一档是刻意的：卡片悬停会放大 1.055，贴太紧会打架。
    func testHeaderToCardGapIsTight() throws {
        let bitmap = try renderHome()
        let gaps = try bitmap.headerToCardGaps()
        XCTAssertEqual(gaps.count, 3, "三条栏位各应量到一段「标题 → 封面」：量到 \(gaps)")
        for gap in gaps {
            XCTAssertLessThanOrEqual(gap, 40, "标题 → 封面又松到 \(gap)pt 了（改之前 ≈45pt、现在 28.5pt）")
            XCTAssertGreaterThanOrEqual(gap, 18, "标题与封面贴到一起了（\(gap)pt）")
        }
    }

    // MARK: - 渲染

    private func renderHome() throws -> HomeBitmap {
        let app = AppModel()
        app.phase = .ready
        app.server = StubMediaServer()
        app.sessionGeneration = 1
        // 三条栏位：继续观看（2）→（接下来看空，不渲染）→ 最近添加（3）→ 媒体库（2）。
        // **卡片文案要按真实内容给全**（集号 + 剩余时长）：栏位的滚动框高是常量，
        // 卡片比框矮多少，那一截余量就落在栏位之间——文案缺一行会让量到的间距比
        // 真机上偏大十几 pt，而那正是这条用例要量的东西。
        app.home.resume = [
            resumeItem(id: "r1", name: "乱马 1/2", season: 3, episode: 25, year: 2024),
            resumeItem(id: "r2", name: "我的朋友很少", season: 1, episode: 6, year: 2023),
        ]
        app.home.latest = [
            MediaItem(id: "l1", name: "乱马 1/2", kind: .series, year: 2024, genres: ["喜剧"]),
            MediaItem(id: "l2", name: "学生会不会有洞!", kind: .series, year: 2026, genres: ["动画"]),
            MediaItem(id: "l3", name: "药屋少女的呢喃", kind: .series, year: 2023, genres: ["动画"]),
        ]
        app.libraries = [
            MediaLibrary(id: "lib-tv", name: "电视剧", collectionType: .tvshows),
            MediaLibrary(id: "lib-mv", name: "电影", collectionType: .movies),
        ]

        let view = HomeView()
            .environment(app)
            // 版面判据全由这三条环境值决定：紧凑宽度 / 页面留白 / 浅色
            // （占位灰是 primary.opacity(0.08)，深色下会变成「黑底上的黑」，量不出来）。
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.contentLeading, Metrics.compactContentInset)
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, scale)
            .frame(width: screen.width, height: screen.height)
            .background(Color.white)

        let image = try snapshot(view, size: screen)
        if let png = Self.pngData(from: image) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "home-compact.png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return try HomeBitmap(image: image, scale: scale)
    }

    /// 「继续观看」条目：集号 + 时长 + 已看进度都给全，`StillCard` 才会渲染
    /// 「S3E25 · 还剩 18 分钟」那一行副标题（真机上就是这样）。
    private func resumeItem(
        id: String,
        name: String,
        season: Int,
        episode: Int,
        year: Int
    ) -> MediaItem {
        MediaItem(
            id: id,
            name: name,
            kind: .episode,
            year: year,
            runtimeSeconds: 1440,
            seriesID: "series-\(id)",
            seriesName: name,
            seasonNumber: season,
            episodeNumber: episode,
            playState: MediaItem.PlayState(played: false, percentage: 0.25, positionSeconds: 360)
        )
    }

    /// 把真视图挂进离屏 `UIWindow` 布局一帧再画进位图。
    ///
    /// **不能用 `ImageRenderer`**：它渲染不了 `ScrollView` 的内容（滚动容器在离屏渲染里
    /// 拿不到视口），而首页整页都是 `ScrollView` + 横向 Rail。
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
        throw XCTSkip("紧凑宽度版式是 iOS 专有路径")
        #endif
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - 位图量尺

/// 「首页整页 → 每条栏位的卡片框 + 栏位间距」的量尺。
///
/// 判据用「白底上的非白像素」：卡片占位是 `primary.opacity(0.08)`（浅色下 ≈0.92
/// 亮度），文案更暗，页面底色是纯白。行分成两类：
/// - **卡片行**：某一行里最长的一段非白像素 ≥ 屏宽 30%（最小的「最近添加」卡是
///   165pt ≈ 41%，而文案行最长也就 8 个汉字 ≈23%）。
/// - **文案行**：其余的非白行。
private struct HomeBitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let scale: CGFloat
    /// 每一行的非白像素个数（懒算一次的代价：874 × 804 逐像素扫一遍，几十毫秒）。
    private let nonWhiteCounts: [Int]
    /// 卡片行判定：非白像素总跨度达不到这个比例的行是文案行。
    private let cardSpanFloor: CGFloat = 0.30
    /// 「非白」阈值：占位灰 ≈0.92 亮度，留一点余量挡抗锯齿。
    private let whiteCutoff: UInt8 = 250

    init(image: CGImage, scale: CGFloat) throws {
        width = image.width
        height = image.height
        self.scale = scale
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HomeBitmapError.noContext }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
        var counts = [Int](repeating: 0, count: height)
        let cutoff = Int(whiteCutoff)
        for row in 0..<height {
            var count = 0
            for x in 0..<width {
                let offset = (row * width + x) * 4
                let luma = (Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2])) / 3
                if luma < cutoff { count += 1 }
            }
            counts[row] = count
        }
        nonWhiteCounts = counts
    }

    enum HomeBitmapError: Error { case noContext }

    // MARK: 量

    /// 一条栏位：标题 ink 带、封面框、栏位的可视底（最后一行文案的下一行）。
    struct Rail {
        var header: Range<Int>
        var card: Range<Int>
        /// 本栏最后一行非白像素的下一行——栏位的可视底边。
        var bottom: Int
        var cardWidth: CGFloat
        var cardHeight: CGFloat
    }

    /// 第 `index` 条栏位（0 起，按渲染顺序）。
    func rail(named index: Int) throws -> Rail? {
        let rails = try railLayout()
        guard rails.indices.contains(index) else { return nil }
        return rails[index]
    }

    /// 栏位之间：上一条栏位的可视底（最后一行文案）→ 下一条栏位的第一行（标题）。
    /// 这正是用户说的「每个栏位之间间距」——它同时包含上下两条栏位各自的留白
    /// （悬停内边距、栏位顶距、标题间距）与滚动框里没用上的余量。
    func gapsBetweenRails() throws -> [CGFloat] {
        let rails = try railLayout()
        guard rails.count > 1 else { return [] }
        return zip(rails, rails.dropFirst()).map { previous, next in
            CGFloat(next.header.lowerBound - previous.bottom) / scale
        }
    }

    /// 栏位内部：标题 ink 底 → 封面框顶。
    func headerToCardGaps() throws -> [CGFloat] {
        try railLayout().map { rail in
            CGFloat(rail.card.lowerBound - rail.header.upperBound) / scale
        }
    }

    // MARK: 内部

    /// 整页 → 每条栏位。**不用白缝阈值切栏位**（那会变成「用要量的东西去量自己」）：
    /// 三条栏位里最大的两段块间白缝就是两条栏位间距，其余缝都在栏位内部。
    /// 先把非白行并成小块（缝 < 16pt：栏位内部的缝都 ≤ 10pt——图 → 进度条 6、
    /// 进度条 → 文案 10、标题 → 副标题 3），再看块与块之间的缝。
    private func railLayout() throws -> [Rail] {
        let blocks = contentBlocks(gapPT: 16)
        let gaps = (0..<(blocks.count - 1)).map { index in
            blocks[index + 1].lowerBound - blocks[index].upperBound
        }
        XCTAssertGreaterThanOrEqual(blocks.count, 4, "整页内容太少，切不出三条栏位")

        // 最大的两段缝 = 两条栏位间距（3 条栏位正好 2 段）。
        let gapIndices = gaps.indices.sorted { gaps[$0] > gaps[$1] }.prefix(2).sorted()
        XCTAssertEqual(gapIndices.count, 2, "切不出两条栏位间距")
        for index in gapIndices {
            XCTAssertGreaterThanOrEqual(
                gaps[index], Int(rhythmFloor * scale),
                "第 \(index) 段缝只有 \(CGFloat(gaps[index]) / scale)pt——栏位挤到一起了"
            )
        }

        let groups: [[Range<Int>]] = [
            Array(blocks[0...gapIndices[0]]),
            Array(blocks[(gapIndices[0] + 1)...gapIndices[1]]),
            Array(blocks[(gapIndices[1] + 1)...]),
        ]
        XCTAssertEqual(groups.count, 3)
        return try groups.map { blocks in
            let header = try XCTUnwrap(blocks.first, "栏位里没有内容")
            let card = try XCTUnwrap(
                blocks.compactMap { wideRun(in: $0) }.first,
                "栏位 \(header) 里没找到封面（宽行 ≥ 屏宽 30%）"
            )
            let bottom = try XCTUnwrap(blocks.last, "栏位里没有内容").upperBound
            let middle = card.lowerBound + card.count / 2
            let widest = nonWhiteRuns(inRow: middle).map(\.count).max() ?? 0
            return Rail(
                header: header,
                card: card,
                bottom: bottom,
                cardWidth: CGFloat(widest) / scale,
                cardHeight: CGFloat(card.count) / scale
            )
        }
    }

    /// 栏位间距的**下限**：低于它说明两条栏位糊成一片了（这时「最大的两段缝」
    /// 这套切法本身也不再成立，用例会在上面的断言里红）。
    private var rhythmFloor: CGFloat { 26 }

    /// 非白行按「中间白缝 < `gapPT`」并成块。
    private func contentBlocks(gapPT: CGFloat) -> [Range<Int>] {
        let maxGap = Int(gapPT * scale)
        var blocks: [Range<Int>] = []
        var start: Int?
        var last: Int?
        for row in nonWhiteRows {
            if let s = start, let l = last, row - l > maxGap {
                blocks.append(s..<(l + 1))
                start = row
            } else if start == nil {
                start = row
            }
            last = row
        }
        if let s = start, let l = last { blocks.append(s..<(l + 1)) }
        return blocks
    }

    private var nonWhiteRows: [Int] {
        (0..<height).filter { nonWhiteCounts[$0] > 0 }
    }

    /// 块里第一段「宽行」（非白跨度 ≥ 屏宽 30%），至少 6pt 高。
    /// 进度条那条细轨跨度也宽，但它与图之间隔着 6pt 白缝、且只有 1.5pt 高，
    /// 取「第一段 ≥ 6pt 的宽行」取到的就是图区。
    private func wideRun(in block: Range<Int>) -> Range<Int>? {
        let floor = Int(cardSpanFloor * CGFloat(width))
        var runs: [Range<Int>] = []
        var start: Int?
        for row in block {
            if nonWhiteCounts[row] >= floor {
                if start == nil { start = row }
            } else if let s = start {
                runs.append(s..<row)
                start = nil
            }
        }
        if let s = start { runs.append(s..<block.upperBound) }
        return runs.first { CGFloat($0.count) / scale >= 6 }
    }

    private func nonWhiteRuns(inRow row: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0..<width {
            let offset = (row * width + x) * 4
            let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
            let ink = luma < Int(whiteCutoff)
            if ink, start == nil {
                start = x
            } else if !ink, let s = start {
                runs.append(s..<x)
                start = nil
            }
        }
        if let s = start { runs.append(s..<width) }
        return runs
    }
}
