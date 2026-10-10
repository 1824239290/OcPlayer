import AppDesignKit
import CoreModel
import ImageIO
import JellyfinKit
import SwiftUI
import XCTest

@testable import OcPlayer

/// 手机（紧凑宽度）媒体库海报墙的**实际渲染几何**：真 `LibraryView` + 真 `AppModel`
/// + 替身服务器，离线渲染成位图后从像素里量——排了几列、卡片多宽、列缝多宽、
/// 标题区是不是两行居中。
///
/// 为什么量像素而不是断言常量：这次要的判据就是用户看到的那些数字
/// （402pt 手机上 **3 列 × ≈113pt**，对照隔壁 Rex 的媒体库 ≈118pt × 3 列；
/// 改之前是 2 列 × 178pt）。列数是 `PosterGrid` 的 `.adaptive` 与可用宽度一起
/// 算出来的结果，断言常量挡不住「token 没动、列数变了」这类回归。
@MainActor
final class LibraryGridLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        // 紧凑宽度（手机）版式是 iOS 专有路径：macOS 上 `horizontalSizeClass` 恒为
        // nil，AppShell 永远走常规版式（见 `AppShellView.contentLeading`）。列策略
        // 本身的跨平台覆盖在 `AppDesignKitTests/PosterGridLayoutTests`。
        #if !os(iOS)
        throw XCTSkip("紧凑宽度版式只在 iOS 上存在")
        #endif
    }

    /// iPhone 16/17 Pro（用户对照截图那台的量级）：402 × 874pt。
    private let screen = CGSize(width: 402, height: 874)
    private let scale: CGFloat = 2
    /// 单卡宽 = (402 − 22×2 − 10×2) / 3。
    private let compactCardWidth: CGFloat = 112.67

    // MARK: - 用例

    func testCompactLibraryWallIsThreeColumnsOnPhone() throws {
        let bitmap = try render(items: sampleItems(), compact: true)
        let artwork = try XCTUnwrap(bitmap.wideBands().first, "整页没渲染出海报行")
        let columns = bitmap.runs(inRow: artwork.lowerBound + Int(40 * scale), minLength: 20)

        XCTAssertEqual(columns.count, 3, "402pt 手机上必须是 3 列（对照 Rex 的媒体库版式）")
        for column in columns {
            XCTAssertEqual(CGFloat(column.count) / scale, compactCardWidth, accuracy: 2,
                           "单卡宽应和 Rex 同档（≈113pt）")
        }
        let gaps = zip(columns, columns.dropFirst()).map { CGFloat($1.lowerBound - $0.upperBound) / scale }
        XCTAssertEqual(gaps.count, 2)
        for gap in gaps {
            XCTAssertEqual(gap, Metrics.compactGridColumnSpacing, accuracy: 1.5)
        }
        XCTAssertEqual(CGFloat(columns[0].lowerBound) / scale, Metrics.compactContentInset, accuracy: 1.5)
        XCTAssertEqual(CGFloat(bitmap.width - columns[2].upperBound) / scale, Metrics.compactContentInset, accuracy: 2)
    }

    /// 标题区两行：标题一行、年份一行（Rex 的版式），而且**居中**在卡片里。
    /// 改之前是「标题 + 年份同一行、左对齐」：113pt 的卡上只装得下 5 个汉字。
    func testCompactCardMetaIsTwoLinesCenteredInColumn() throws {
        let bitmap = try render(items: sampleItems(), compact: true)
        let artwork = try XCTUnwrap(bitmap.wideBands().first)
        let lines = bitmap.textLines(after: artwork)

        XCTAssertEqual(lines.count, 2, "标题与年份应各占一行（Rex 的版式）")
        // 上行是标题（footnote ≈12pt 墨高）、下行是年份（caption2 ≈9pt）。
        let heights = lines.map { CGFloat($0.count) / scale }
        XCTAssertEqual(heights[0], 12, accuracy: 2)
        XCTAssertEqual(heights[1], 9, accuracy: 2)

        let firstColumn = try XCTUnwrap(bitmap.runs(inRow: artwork.lowerBound + Int(40 * scale), minLength: 20).first)
        let columnCenter = CGFloat(firstColumn.lowerBound + firstColumn.upperBound) / 2
        for line in lines {
            // 取该行的中间一行量水平范围（首行可能只有几个字的笔画尖，范围偏窄）。
            let ink = bitmap.runs(
                inRow: line.lowerBound + line.count / 2,
                minLength: 1,
                from: firstColumn.lowerBound,
                to: firstColumn.upperBound
            )
            let inkStart = try XCTUnwrap(ink.first), inkEnd = try XCTUnwrap(ink.last)
            let center = CGFloat(inkStart.lowerBound + inkEnd.upperBound) / 2
            XCTAssertEqual(center, columnCenter, accuracy: 4 * scale, "标题/年份应在卡片内居中（不是左对齐）")
        }
    }

    /// 常规宽度（iPad 全屏 / macOS）保持原样：178pt 定宽卡、标题与年份同一行。
    /// 改动的边界就在这条上——紧凑端调版式，常规端一个像素都不该动。
    func testRegularWidthWallKeepsSingleLineMetaAndFixedCardWidth() throws {
        let bitmap = try render(items: sampleItems(), compact: false, size: CGSize(width: 1024, height: 768))
        let artwork = try XCTUnwrap(bitmap.wideBands().first, "整页没渲染出海报行")

        let columns = bitmap.runs(inRow: artwork.lowerBound + Int(40 * scale), minLength: 20)
        XCTAssertGreaterThanOrEqual(columns.count, 4, "1024pt 宽至少排得下 4 张 178pt 卡")
        for column in columns {
            XCTAssertEqual(CGFloat(column.count) / scale, Metrics.posterWidth, accuracy: 2,
                           "常规宽度仍是 178pt 定宽卡")
        }

        let lines = bitmap.textLines(after: artwork)
        XCTAssertEqual(lines.count, 1, "常规宽度的标题与年份仍在同一行")
    }

    // MARK: - 渲染

    /// 骨架卡与真实卡片**同宽同位**：`PosterCard` 的卡宽语义改了一档，骨架必须跟着
    /// 走——否则「骨架撤掉、真实卡上位」那一瞬间整墙会跳，而那正是骨架屏要消掉的东西
    /// （`SkeletonPosterCard` 的类型注释里写着这条约定）。
    func testCompactSkeletonCardMatchesRealCardGeometry() throws {
        let size = CGSize(width: screen.width, height: 560)
        let image = try snapshot(
            ScrollView {
                LazyVGrid(columns: PosterGrid.columns(compact: true),
                          spacing: PosterGrid.rowSpacing(compact: true)) {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonPosterCard(width: PosterGrid.cardWidth(compact: true))
                    }
                }
                .padding(.horizontal, Metrics.compactContentInset)
            }
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
            .background(Color.white),
            size: size
        )
        let bitmap = try PixelGrid(image: image)
        let block = try XCTUnwrap(bitmap.wideBands().first, "骨架没渲染出图块")
        let columns = bitmap.runs(inRow: block.lowerBound + Int(40 * scale), minLength: 20)

        XCTAssertEqual(columns.count, 3)
        for column in columns {
            XCTAssertEqual(CGFloat(column.count) / scale, compactCardWidth, accuracy: 2)
        }
        XCTAssertEqual(
            CGFloat(block.count) / scale,
            compactCardWidth / Metrics.posterFallbackRatio, accuracy: 2,
            "骨架图块要跟兜底海报比例一致（多数派 0.70），否则骨架撤掉那一下会跳"
        )
    }

    private func sampleItems() -> [MediaItem] {
        // 7–8 字的剧名（Rex 截图里那种长度）：旧版式在 113pt 卡上必被截断。
        [
            MediaItem(id: "1", name: "药屋少女的呢喃", kind: .series, year: 2023),
            MediaItem(id: "2", name: "凡人修仙传", kind: .series, year: 2020),
            MediaItem(id: "3", name: "乱马 1/2", kind: .series, year: 2024),
            MediaItem(id: "4", name: "学生会不会有洞!", kind: .series, year: 2026),
            MediaItem(id: "5", name: "二十世纪电气目录", kind: .series, year: 2026),
            MediaItem(id: "6", name: "FX 战士久留美", kind: .series, year: 2026),
        ]
    }

    private func render(
        items: [MediaItem],
        compact: Bool,
        size: CGSize? = nil,
        pipeline: ImagePipeline? = nil
    ) throws -> PixelGrid {
        let size = size ?? screen
        let app = AppModel()
        app.phase = .ready
        app.server = StubMediaServer()
        app.sessionGeneration = 1
        app.cacheLibraryPage(
            AppModel.LibraryPage(
                items: items,
                totalCount: items.count,
                nextStartIndex: items.count,
                lastPageWasFull: false
            ),
            for: "lib-tv"
        )

        let view = LibraryView(library: MediaLibrary(id: "lib-tv", name: "电视剧", collectionType: .tvshows))
            .environment(app)
            // 版面判据全由这三条环境值决定：紧凑宽度 / 页面留白 / 浅色（占位灰是
            // primary.opacity(0.08)，深色下会变成「白底上的白」，量不出来）。
            .environment(\.horizontalSizeClass, compact ? .compact : .regular)
            .environment(\.contentLeading, compact ? Metrics.compactContentInset : Metrics.contentInset)
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, scale)
            .frame(width: size.width, height: size.height)
            .background(Color.white)

        // 图片管道按需注入：不注入的条目没有图片地址（`StubMediaServer` 的条目不带
        // `primaryImageTag`）走占位；注入时用**合成海报**走真实加载链。
        let rendered = pipeline.map { AnyView(view.environment(\.imagePipeline, $0)) } ?? AnyView(view)
        let image = try snapshot(rendered, size: size)
        let bitmap = try PixelGrid(image: image)
        if let png = Self.pngData(from: image) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return bitmap
    }

    /// 把真视图挂进一个离屏 `UIWindow` 里布局一帧，再把图层树画进位图。
    ///
    /// **不能用 `ImageRenderer`**：它渲染不了 `ScrollView`——滚动容器在离屏渲染里
    /// 拿不到视口，实测整个页面出来是一张纯白（`maxCoverage == 0`，连 LazyVGrid 的
    /// 行都没实例化）。`LibraryView` 的真身就是「ScrollView + LazyVGrid」，只能走
    /// 真层级快照。
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

/// 按行读图的小工具：够这个用例量列、量文案行就行。
///
/// 判据用「白底上的非白像素」：海报占位是 `primary.opacity(0.08)`（浅色下 ≈0.92
/// 亮度），文案更暗，页面底色是纯白。
private struct PixelGrid {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    /// 文案行最多也就占屏宽的 40%（一整行 8 个汉字 ≈23%）；超过它的是海报块。
    private let inkCeiling: CGFloat = 0.4
    /// 海报行至少要占屏宽 60%（402pt 手机上 3 列占 89%，1280pt 上 5 列占 70%）。
    private let artworkFloor: CGFloat = 0.6
    private let whiteCutoff: CGFloat = 0.985

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

    private func luma(x: Int, y: Int) -> CGFloat {
        let offset = (y * width + x) * 4
        return CGFloat(Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3 / 255
    }

    /// 一行里连续的「非白」段（海报块 / 文案），按 x 升序。
    func runs(inRow y: Int, minLength: Int, from: Int = 0, to: Int? = nil) -> [Range<Int>] {
        let lower = max(0, from)
        let upper = min(width, to ?? width)
        guard y >= 0, y < height, lower < upper else { return [] }
        var result: [Range<Int>] = []
        var start: Int?
        for x in lower..<upper {
            if luma(x: x, y: y) < whiteCutoff {
                if start == nil { start = x }
            } else if let s = start {
                result.append(s..<x)
                start = nil
            }
        }
        if let s = start { result.append(s..<upper) }
        return result.filter { $0.count >= minLength }
    }

    // MARK: 图片定位（「不裁切」那组用例用）

    /// 图片像素＝深底或饱和色（红框）。
    ///
    /// 只在**中线/中列扫描**里用它：那条线只穿过图片，不经过下方的标题文字，
    /// 所以「认深」不会把黑字圈进来。定位用的是红框（见 `redBounds`），不是深色。
    private func isArtwork(x: Int, y: Int) -> Bool {
        let i = (y * width + x) * 4
        let r = Double(bytes[i]) / 255
        let g = Double(bytes[i + 1]) / 255
        let b = Double(bytes[i + 2]) / 255
        // 深底或红框都算图片；中性灰占位（≈0.92 亮度、零饱和）两者都不是。
        return max(r, max(g, b)) - min(r, min(g, b)) > 0.15 || (r + g + b) / 3 < 0.5
    }

    /// 在给定列区间里，第一行「不是纯白」的 y —— 也就是卡片图区的上沿。
    ///
    /// 判据用白底：卡片图区由 `RemoteImage` 的占位灰（`primary.opacity(0.08)`，浅色下
    /// ≈0.92 亮度）铺满，因此「图区上沿」一定在图片上沿之上或与它重合。**两者之间的
    /// 距离就是留边的高度**（剧照卡的图区没有别的东西，紧贴卡顶）。
    func firstNonWhiteRow(inColumns columns: ClosedRange<Int>) -> Int? {
        for y in 0..<height {
            for x in columns.clamped(to: 0...(width - 1)) where luma(x: x, y: y) < 0.985 {
                return y
            }
        }
        return nil
    }

    /// 合成图的红框：R 明显高于 G、B。
    func isRed(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        let i = (y * width + x) * 4
        let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
        return r > 90 && r > g + 50 && r > b + 50
    }

    /// 全页红框像素的外接矩形。用红框定位而不是「深色」，是因为卡片标题的黑字也够深，
    /// 认深会把文字圈进来（实测因此把 0.702 量成 0.88）。
    func redBounds() -> ArtworkRegion? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where isRed(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return ArtworkRegion(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 在给定的 x 区间里找红框外接矩形——按网格列分别量的入口。
    ///
    /// 比「整页扫一遍再切分」稳：整页扫描要靠列缝把卡片分开，而边框被缩放后
    /// 抗锯齿会削弱个别列的红色（实测把一张卡切成好几段，量出 2.5pt 的假宽度）。
    func redBounds(inColumnRange range: some RangeExpression<Int>) -> ArtworkRegion? {
        let bounds = range.relative(to: 0..<width)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in bounds where isRed(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return ArtworkRegion(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 所有红框（每个连通块一个外接矩形），按 x 升序。
    ///
    /// 用列扫描而不是连通域标记：同一行的卡片在水平方向被列缝分开，逐列累积红像素
    /// 的上下界即可分开（本用例的卡片不会重叠）。
    func allRedBoxes() -> [ArtworkRegion] {
        var columns: [(minY: Int, maxY: Int)] = Array(repeating: (Int.max, -1), count: width)
        for x in 0..<width {
            for y in 0..<height where isRed(x: x, y: y) {
                columns[x].minY = min(columns[x].minY, y)
                columns[x].maxY = max(columns[x].maxY, y)
            }
        }
        var boxes: [ArtworkRegion] = []
        var start: Int?
        var minY = Int.max, maxY = -1
        for x in 0..<width {
            let has = columns[x].maxY >= 0
            if has {
                if start == nil { start = x }
                minY = min(minY, columns[x].minY)
                maxY = max(maxY, columns[x].maxY)
            } else if let s = start {
                boxes.append(ArtworkRegion(x: s, y: minY, width: x - s, height: maxY - minY + 1))
                start = nil
                minY = Int.max; maxY = -1
            }
        }
        if let s = start {
            boxes.append(ArtworkRegion(x: s, y: minY, width: width - s, height: maxY - minY + 1))
        }
        return boxes
    }

    /// 红框内部的几何：宽高 + 四条边中点是否还有红。
    /// 红框贴着图片四边，所以它的外接矩形＝图片范围；边中点离圆角最远，不受圆角影响。
    func redGeometry(_ box: ArtworkRegion) -> (width: Int, height: Int, hasRedOnAllFourEdges: Bool)? {
        guard box.width > 10, box.height > 10 else { return nil }
        let inset = 4                     // 红框宽 8px：往里 4px 仍落在框上
        let midX = box.x + box.width / 2
        let midY = box.y + box.height / 2
        let all = isRed(x: box.x + inset, y: midY)
            && isRed(x: box.x + box.width - 1 - inset, y: midY)
            && isRed(x: midX, y: box.y + inset)
            && isRed(x: midX, y: box.y + box.height - 1 - inset)
        return (box.width, box.height, all)
    }

    /// 某一行上图片像素（深底或红框）的第一段连续区间。`start` 只在进入连续段时置位。
    func imageRun(inRow y: Int) -> ClosedRange<Int>? {
        guard y >= 0, y < height else { return nil }
        var start: Int?
        for x in 0..<width {
            if isArtwork(x: x, y: y) {
                if start == nil { start = x }
            } else if let s = start {
                return s...(x - 1)
            }
        }
        return start.map { $0...(width - 1) }
    }

    /// 某一列上图片像素的第一段连续区间。
    func imageRun(inColumn x: Int) -> ClosedRange<Int>? {
        guard x >= 0, x < width else { return nil }
        var start: Int?
        for y in 0..<height {
            if isArtwork(x: x, y: y) {
                if start == nil { start = y }
            } else if let s = start {
                return s...(y - 1)
            }
        }
        return start.map { $0...(height - 1) }
    }

    private func inkCoverage(inRow y: Int) -> CGFloat {
        CGFloat(runs(inRow: y, minLength: 1).reduce(0) { $0 + $1.count }) / CGFloat(width)
    }

    /// 所有「几乎铺满一行」的横带（= 海报图区），按 y 升序。
    func wideBands() -> [Range<Int>] {
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0..<height {
            if inkCoverage(inRow: y) >= artworkFloor {
                if start == nil { start = y }
            } else if let s = start {
                bands.append(s..<y)
                start = nil
            }
        }
        if let s = start { bands.append(s..<height) }
        return bands
    }

    /// 海报行下方的**标题行**（每行一个 y 区间），按 y 升序。
    ///
    /// 两条判据缺一不可：① 一行文案是一串连续的「有墨」行，行与行之间靠**空档**
    /// 断开（容差 3pt：同一行内部墨行必然相连，而两行标题之间隔着 4–5pt）；
    /// ② 只认**海报行下方 40pt 内**的簇——meta 最多两行（标题 12pt + 年份 9pt +
    /// 行距），再往下就是下一行海报卡；而下一行卡不一定是「宽行」（窗口窄、最后
    /// 一行只剩两张卡时覆盖率可能只有 0.17），指望它被 `artworkFloor` 排除不可靠，
    /// 它的顶边会变成一条假「标题行」。
    func textLines(after artwork: Range<Int>, maxMetaHeight: CGFloat = 40) -> [Range<Int>] {
        let gapTolerance = Int(3 * 2)      // 3pt @2x
        let windowEnd = min(height, artwork.upperBound + Int(maxMetaHeight * 2))
        var lines: [Range<Int>] = []
        var start: Int?
        var lastInk = 0
        func flush() {
            if let s = start { lines.append(s..<lastInk) }
            start = nil
        }
        for y in artwork.upperBound..<windowEnd {
            if inkCoverage(inRow: y) > 0.001 {
                if let s = start {
                    if y - lastInk > gapTolerance {
                        flush()
                        start = y
                    }
                } else {
                    start = y
                }
                lastInk = y
            }
        }
        flush()
        return lines
    }
}

// MARK: - 真实图片下的「四边贴死」（端到端）

/// 媒体库墙在**真的加载到图片**之后「四边贴死」——这条走的是用户屏幕上那条路：
/// 紧凑网格的自适应列 → `PosterCard`（把服务端 `PrimaryImageAspectRatio` 交给图区）
/// → `MediaArtwork`（先 `onGeometryChange` 量列宽，再起图）→ `RemoteImage` → `ImagePipeline`。
///
/// 包内的 `ArtworkScalingTests` 只测得到定宽盒子（`ImageRenderer` 是同步渲染、不会触发
/// 几何回调），**自适应列这条只能在这里测**。
///
/// 夹具：一张「深底 + 四边红框」的合成海报，尺寸 400×570＝本机库主流比例（0.702）。
/// 红框贴着图片四边，裁哪条就量不到红；红框外接矩形＝图片范围，跟列宽比就是「有没有贴死」。
@MainActor
final class LibraryArtworkScalingTests: XCTestCase {
    private let screen = CGSize(width: 402, height: 874)
    private let scale: CGFloat = 2
    /// 402pt 手机上紧凑网格的列宽：(402 − 22×2 − 10×2) / 3。
    private let columnWidth: CGFloat = 112.67

    override func setUpWithError() throws {
        #if !os(iOS)
        throw XCTSkip("紧凑宽度版式只在 iOS 上存在")
        #endif
    }

    #if os(iOS)
    /// 只放一条内容：整页就这一张海报，红框外接矩形＝这张海报，量起来没有歧义。
    func testCompactWallHugsServerAspectRatioOnAllFourSides() async throws {
        // 服务端给的服务端比例：这里刻意用 0.75（阿松 / Re:0 那种宽海报）——
        // 它离 2:3 最远，写死框时裁得最多，最能验出「框跟着图走」。
        try await assertHugs(serverRatio: 0.75, pixelSize: CGSize(width: 400, height: 533))
    }

    /// 主流比例（本机 22/26 部剧集）：同样贴死。
    func testCompactWallHugsCommonPosterRatio() async throws {
        try await assertHugs(serverRatio: 0.7013, pixelSize: CGSize(width: 400, height: 570))
    }

    /// 服务端**没给**比例时：先按兜底比例铺满（`.fill`，绝不流缝），等位图到手再按真实
    /// 比例校正一次——最终仍然四边贴死。这条覆盖老服务器 / 外部入库条目。
    func testCompactWallHugsWhenServerOmitsRatio() async throws {
        try await assertHugs(serverRatio: nil, pixelSize: CGSize(width: 400, height: 570))
    }

    private func assertHugs(
        serverRatio: Double?,
        pixelSize: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let pipeline = try makePipeline(pixelSize: pixelSize)
        let items = [
            MediaItem(
                id: "1", name: "药屋少女的呢喃", kind: .series, year: 2023,
                primaryImageTag: "tag1", primaryImageAspectRatio: serverRatio
            )
        ]

        let app = AppModel()
        app.phase = .ready
        app.server = StubMediaServer()
        app.sessionGeneration = 1
        app.cacheLibraryPage(
            AppModel.LibraryPage(
                items: items, totalCount: 1, nextStartIndex: 1, lastPageWasFull: false
            ),
            for: "lib-tv"
        )

        let view = LibraryView(library: MediaLibrary(id: "lib-tv", name: "电视剧", collectionType: .tvshows))
            .environment(app)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.contentLeading, Metrics.compactContentInset)
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, scale)
            .environment(\.imagePipeline, pipeline)

        let image = try await snapshotAfterLoad(view)
        if let png = Self.pngData(from: image) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let bitmap = try PixelGrid(image: image)
        let ring = try XCTUnwrap(bitmap.redBounds(), "整页没加载出带红框的海报", file: file, line: line)
        let geometry = try XCTUnwrap(
            bitmap.redGeometry(ring), "红框太小，量不出边", file: file, line: line
        )

        XCTAssertTrue(
            geometry.hasRedOnAllFourEdges,
            "四条边的红框必须都在——缺一条就是图片被裁了", file: file, line: line
        )
        XCTAssertEqual(
            CGFloat(geometry.width) / scale, columnWidth, accuracy: 2,
            "图片宽度应贴死网格列宽（\(columnWidth)pt）", file: file, line: line
        )
        XCTAssertEqual(
            Double(geometry.width) / Double(geometry.height), pixelSize.width / pixelSize.height,
            accuracy: 0.02,
            "图片范围应是它自己的比例（\(pixelSize.width/pixelSize.height)）——"
                + "留灰边或裁切都会让这个比例对不上", file: file, line: line
        )
    }

    // MARK: - 横版（剧照 / 库卡）：16:9 资产必须铺满，不出灰条

    /// **用户报的「横着的那些有问题」的回归**：剧照卡拿到 16:9 的图时，必须原样铺满
    /// 16:9 的框——上下不许露灰条。
    ///
    /// 为什么只能在 App 层测：框比例一旦被「位图实测」那条路改写，要**过一拍 runloop**
    /// 才在下一帧生效；包内的 `ImageRenderer` 是单帧同步渲染，看不到那个中间态——
    /// 缺陷当初就是从包内用例底下溜过去的（根因是比例闸门写死上界 1.6，把 16:9 的
    /// 1.7778 夹变形了）。
    func testLandscapeStillCardFillsItsBoxOnRealLayout() async throws {
        let pixelSize = CGSize(width: 640, height: 360)          // 16:9：实测全部剧照资产
        let width = Metrics.stillWidth                            // 328pt
        let pipeline = try makePipeline(bytes: [Self.syntheticBorderedPNG(size: pixelSize)])
        let item = MediaItem(
            id: "movie", name: "年会不能停！2", kind: .movie, year: 2024,
            // 刻意给一个**竖版**的 primary 比例：剧照卡显示的是 Thumb，不是 Primary。
            // 把 primary 比例套到剧照上正是要防的错（实测「年会不能停！2」就是
            // primary=0.667 而它的 thumb 是 16:9）。
            primaryImageAspectRatio: 0.6667,
            thumbImageTag: "thumb-tag", backdropImageTag: "bd-tag"
        )
        _ = try await pipeline.load(
            stillURL(itemID: item.id, type: "Thumb"), authHeader: nil,
            maxPixelSize: ArtworkMetrics.pixelBudget(
                boxWidth: width, heightRatio: 9.0 / 16.0, scale: scale)
        )

        let card = StillCard(item: item, server: StubMediaServer(), actionIcon: "play.fill", width: width) {}
            .environment(\.displayScale, scale)
            .environment(\.imagePipeline, pipeline)
            .environment(\.colorScheme, .light)

        let image = try await snapshotAfterLoad(card, size: CGSize(width: width + 40, height: 420))
        let bitmap = try PixelGrid(image: image)
        let ring = try XCTUnwrap(bitmap.redBounds(), "剧照卡没加载出图")
        let geometry = try XCTUnwrap(bitmap.redGeometry(ring))

        XCTAssertEqual(
            Double(geometry.width) / Double(geometry.height), 16.0 / 9.0, accuracy: 0.03,
            "剧照应保持 16:9——被挤变形就会露灰条"
        )
        XCTAssertEqual(
            CGFloat(geometry.height) / scale, width * 9 / 16, accuracy: 2,
            "高度应贴死 16:9（灰条会让它小于这个值）"
        )
        XCTAssertTrue(geometry.hasRedOnAllFourEdges, "四条边都该在——缺一条就是被裁了")

        // **留边检测**：图区上沿到图片上沿之间若有一截灰，就是上下留边的灰条
        //（用户报的「横着的那些有问题」）。只量图片外接矩形看不见它——图片永远保持
        // 自己的比例，被挤变形的是**框**。
        let areaTop = try XCTUnwrap(
            bitmap.firstNonWhiteRow(inColumns: ring.x...(ring.x + ring.width - 1)),
            "没找到图区上沿"
        )
        XCTAssertLessThanOrEqual(
            ring.y - areaTop, 2,
            "图区上沿(\(areaTop))到图片上沿(\(ring.y))之间不该有灰带——那就是留边"
        )
    }

    /// 库卡（首页「媒体库」栏）同样是横版：16:9 封面铺满 16:9 框。
    func testLandscapeLibraryCardFillsItsBoxOnRealLayout() async throws {
        let pixelSize = CGSize(width: 720, height: 405)          // 16:9
        let width = Metrics.stillWidth
        let pipeline = try makePipeline(bytes: [Self.syntheticBorderedPNG(size: pixelSize)])
        let library = MediaLibrary(
            id: "lib-tv", name: "电视剧", collectionType: .tvshows, primaryImageTag: "cover"
        )
        _ = try await pipeline.load(
            stillURL(itemID: library.id), authHeader: nil,
            maxPixelSize: ArtworkMetrics.pixelBudget(
                boxWidth: width, heightRatio: 9.0 / 16.0, scale: scale)
        )

        let card = LibraryCard(library: library, server: StubMediaServer(), width: width) {}
            .environment(\.displayScale, scale)
            .environment(\.imagePipeline, pipeline)
            .environment(\.colorScheme, .light)

        let image = try await snapshotAfterLoad(card, size: CGSize(width: width + 40, height: 460))
        let bitmap = try PixelGrid(image: image)
        let ring = try XCTUnwrap(bitmap.redBounds(), "库卡没加载出封面")
        let geometry = try XCTUnwrap(bitmap.redGeometry(ring))

        XCTAssertEqual(
            CGFloat(geometry.height) / scale, width * 9 / 16, accuracy: 2,
            "16:9 封面应铺满 16:9 的框（灰条会让高度小于它）"
        )
        XCTAssertTrue(geometry.hasRedOnAllFourEdges)

        let areaTop = try XCTUnwrap(
            bitmap.firstNonWhiteRow(inColumns: ring.x...(ring.x + ring.width - 1)),
            "没找到图区上沿"
        )
        XCTAssertLessThanOrEqual(ring.y - areaTop, 2, "库卡封面也不该留边")
    }

    /// 横版取图地址（`StubMediaServer.imageURL` 同形）。
    private func stillURL(itemID: String, type: String = "Primary") -> URL {
        URL(string: "http://stub.local:8096/Items/\(itemID)/Images/\(type)?maxWidth=720&tag=t")!
    }

    /// **同一行里比例不同的三张卡**（本机库里就是这种混排：0.667 / 0.70 / 0.75）：
    /// 各自贴死自己的比例、顶部对齐成一排，谁也不裁、谁也不留边。
    ///
    /// 这条是「框跟着图走」最容易出洋相的地方——三张卡高度不同，逐列量能同时钉住
    /// 「每张都按自己的比例」与「同一行顶部对齐」。
    func testRowWithMixedRatiosHugsEachOwnRatio() async throws {
        let specs: [(ratio: Double, size: CGSize)] = [
            (0.6667, CGSize(width: 400, height: 600)),
            (0.7013, CGSize(width: 400, height: 570)),
            (0.7500, CGSize(width: 400, height: 533)),
        ]
        let pipeline = try makePipeline(bytes: specs.map { Self.syntheticBorderedPNG(size: $0.size) })
        var items: [MediaItem] = []
        for (index, spec) in specs.enumerated() {
            items.append(MediaItem(
                id: "\(index)", name: "剧集 \(index + 1)", kind: .series, year: 2023,
                primaryImageTag: "tag\(index)", primaryImageAspectRatio: spec.ratio
            ))
        }

        let app = AppModel()
        app.phase = .ready
        app.server = StubMediaServer()
        app.sessionGeneration = 1
        app.cacheLibraryPage(
            AppModel.LibraryPage(items: items, totalCount: 3, nextStartIndex: 3, lastPageWasFull: false),
            for: "lib-tv"
        )
        let view = LibraryView(library: MediaLibrary(id: "lib-tv", name: "电视剧", collectionType: .tvshows))
            .environment(app)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.contentLeading, Metrics.compactContentInset)
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, scale)
            .environment(\.imagePipeline, pipeline)

        let image = try await snapshotAfterLoad(view)
        if let png = Self.pngData(from: image) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let bitmap = try PixelGrid(image: image)

        // 三列的 x 区间由同一套 token 推出（页面留白 + 列宽 + 列距），逐列量。
        let inset = Metrics.compactContentInset
        let spacing = Metrics.compactGridColumnSpacing
        let columnWidth = (screen.width - 2 * inset - 2 * spacing) / 3
        var tops: [Int] = []
        for (index, spec) in specs.enumerated() {
            let left = inset + CGFloat(index) * (columnWidth + spacing)
            let range = Int(left * scale)..<Int((left + columnWidth) * scale)
            let box = try XCTUnwrap(
                bitmap.redBounds(inColumnRange: range),
                "第 \(index + 1) 列没找到红框（列区间 \(range)）"
            )
            XCTAssertEqual(
                CGFloat(box.width) / scale, columnWidth, accuracy: 2,
                "第 \(index + 1) 列的图片宽度应贴死列宽"
            )
            XCTAssertEqual(
                Double(box.width) / Double(box.height), spec.ratio, accuracy: 0.02,
                "第 \(index + 1) 列应贴死自己的比例 \(spec.ratio)"
            )
            tops.append(box.y)
        }
        XCTAssertEqual(Set(tops).count, 1, "同一行的卡片顶部必须对齐（实测 \(tops.sorted())）")
    }

    /// 等图片真的加载完再快照：`.task` 要过若干主线程 runloop 才把位图放上图层树，
    /// 而比例校正（服务端没给比例时）还要再多一拍。
    private func snapshotAfterLoad(_ view: some View, size requestedSize: CGSize? = nil) async throws -> CGImage {
        let size = requestedSize ?? screen
        let controller = UIHostingController(
            rootView: AnyView(view.frame(width: size.width, height: size.height).background(Color.white))
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        // `RunLoop.current.run(until:)` 在 async 上下文里不可用（编译器直接拦），
        // 改用主 actor 上的 `Task.sleep` 让出线程、让主 runloop 转起来。
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(80))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func makePipeline(pixelSize: CGSize) throws -> ImagePipeline {
        try makePipeline(bytes: [Self.syntheticBorderedPNG(size: pixelSize)])
    }

    /// 多张图：按 URL 里的序号发对应的那张（混排用例要三种比例同时在场）。
    private func makePipeline(bytes: [Data]) throws -> ImagePipeline {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryArtwork-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // ⚠️ `@Sendable` 不能省：`MockURLProtocol.handler` 的类型不是 `@Sendable`，
        // 直接写字面量会让闭包**继承外层 `@MainActor` 测试类的隔离**，而 URLSession 是在
        // 后台线程调它的 → main-actor 断言失败、SIGTRAP（实测崩溃，栈顶正是
        // `_dispatch_assert_queue_fail` ← `startLoading` ← 这个闭包）。
        MockURLProtocol.handler = { @Sendable request in
            // 用 URL 里的条目 id 选图（`StubMediaServer.imageURL` 拼的是
            // `/Items/{itemID}/Images/Primary?...`，条目 id 就是 "0"/"1"/"2"）。
            let itemIndex = request.url.flatMap { url -> Int? in
                let parts = url.absoluteString.split(separator: "/")
                guard let i = parts.firstIndex(of: "Items"), i + 1 < parts.count else { return nil }
                return Int(parts[i + 1])
            } ?? 0
            // 只有一张图时（单图用例）无论哪个条目都发同一张。
            let index = bytes.count == 1 ? 0 : itemIndex
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, bytes[min(max(index, 0), bytes.count - 1)])
        }
        return ImagePipeline(cacheDirectory: dir, protocolClasses: [MockURLProtocol.self])
    }

    private static func syntheticBorderedPNG(size: CGSize) -> Data {
        let width = Int(size.width), height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let border: CGFloat = 8
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: border))
        context.fill(CGRect(x: 0, y: size.height - border, width: size.width, height: border))
        context.fill(CGRect(x: 0, y: 0, width: border, height: size.height))
        context.fill(CGRect(x: size.width - border, y: 0, width: border, height: size.height))

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
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
    #endif
}

/// 图片在渲染结果里的矩形范围（像素坐标）。
struct ArtworkRegion {
    let x: Int, y: Int, width: Int, height: Int
}
