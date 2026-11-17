import CoreGraphics
import Foundation

/// 每张 tile 落在哪：`(列, 行)` 的**纯函数**。
///
/// 什么都不预计算、什么都不存，墙因此可以廉价地随窗口改尺寸：多要一列就多一列，
/// 已经在屏上的海报**不会重新洗牌**。而且 tile 数量由视口算出来
/// （见 `LoginWallLayout`），所以 App 永远只解码它真能显示的那些封面。
public enum LoginWallPlan {

    /// `Equatable` 是给渲染层用的：列内容靠值相等来跳过重绘（见 `LoginWallColumnContent`）。
    public struct Tile: Identifiable, Equatable, Hashable, Sendable {
        public let column: Int
        public let row: Int
        public let poster: LoginWallPoster
        /// 一丝旋转，像被手工钉上去的。
        public let tilt: Double
        /// 垂直微移，免得一行读成一条直线。
        public let offset: Double

        /// 用列行而不是海报做身份：海报少的时候（小媒体库），同一张在大窗口上
        /// 合法地出现在多处，用海报 id 会撞身份。
        public var id: String { "\(column)-\(row)" }
    }

    public struct Column: Identifiable, Equatable, Hashable, Sendable {
        public let index: Int
        public let tiles: [Tile]

        public var id: Int { index }
    }

    /// 列内行与行之间跨过的条目数。与任何现实的条目总数互质（条目数常见
    /// 20～2000），所以**同一列里不会重复同一张海报**，而可见的几行已经横跨
    /// 大半个库。
    static let rowStride = 23

    public static func posterIndex(column: Int, row: Int, catalogSize: Int) -> Int {
        guard catalogSize > 0 else { return 0 }
        return ((column + row * rowStride) % catalogSize + catalogSize) % catalogSize
    }

    /// 抖动是位置的纯函数，所以改窗口大小不会让墙抖一下。
    public static func tilt(column: Int, row: Int) -> Double {
        var rng = SeededRandom(seed: UInt64(column &* 73 &+ row &* 151 &+ 0x5EED))
        return rng.range(-1.6, 1.6)
    }

    public static func offset(column: Int, row: Int) -> Double {
        var rng = SeededRandom(seed: UInt64(column &* 197 &+ row &* 29 &+ 0xBEEF))
        return rng.range(-5, 5)
    }

    /// 正好造 `columns` × `rows` 张 tile。
    public static func make(catalog: [LoginWallPoster], columns: Int, rows: Int) -> [Column] {
        guard !catalog.isEmpty, columns > 0, rows > 0 else { return [] }

        return (0..<columns).map { column in
            let tiles = (0..<rows).map { row -> Tile in
                let index = posterIndex(column: column, row: row, catalogSize: catalog.count)
                return Tile(
                    column: column,
                    row: row,
                    poster: catalog[index],
                    tilt: tilt(column: column, row: row),
                    offset: offset(column: column, row: row)
                )
            }
            return Column(index: column, tiles: tiles)
        }
    }
}

/// 一个视口尺寸对应的静态几何，包括「盖住它最少要几张 tile」。
///
/// 纯值（`Hashable`）而不是视图状态：它可以在没有渲染的情况下断言，
/// 也是「窗口小墙就小」这条性能承诺唯一需要验证的地方。
public struct LoginWallLayout: Hashable, Sendable {
    public let viewport: CGSize
    public let columnWidth: CGFloat
    public let spacing: CGFloat
    public let columnCount: Int
    public let rowCount: Int

    public init(size: CGSize, catalogSize: Int) {
        let spacing = LoginWallStyle.itemSpacing
        // 屏幕口径的列数先除以墙的放大倍数，`visibleColumns` 才是「屏幕上看见几列」。
        let byWidth = size.width / LoginWallStyle.visibleColumns / LoginWallStyle.contentScale
        let width = min(max(byWidth, LoginWallStyle.minimumColumnWidth), LoginWallStyle.maximumColumnWidth)

        // 多两列、多两行：足够盖住透视在近端的扩散与取整误差，又不至于为两倍大的
        // 窗口造一整面墙。
        let columns = Int((size.width / LoginWallStyle.contentScale / (width + spacing)).rounded(.up)) + 2
        let rows = Int((size.height / LoginWallStyle.contentScale / ((width * LoginWallStyle.posterAspect).rounded() + spacing)).rounded(.up)) + 2

        self.viewport = size
        self.spacing = spacing
        self.columnWidth = width
        self.columnCount = max(1, columns)
        // 永远不造比条目总数还多的行：小库上重复得越少越好。
        self.rowCount = max(1, catalogSize > 0 ? min(rows, catalogSize) : rows)
    }

    public var tileHeight: CGFloat { (columnWidth * LoginWallStyle.posterAspect).rounded() }
    public var totalWidth: CGFloat { columnWidth * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1) }
    public var totalHeight: CGFloat { tileHeight * CGFloat(rowCount) + spacing * CGFloat(rowCount - 1) }

    /// 整面墙画布的点尺寸。合成图就是按这个尺寸画的（见 `LoginWallRasterizer`）。
    public var canvasSize: CGSize { CGSize(width: totalWidth, height: totalHeight) }

    /// 这面墙一共要画几张 tile。测试与性能断言都看它。
    public var tileCount: Int { columnCount * rowCount }
}
