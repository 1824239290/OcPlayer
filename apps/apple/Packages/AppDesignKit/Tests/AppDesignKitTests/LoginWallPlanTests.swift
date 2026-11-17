import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import AppDesignKit

/// 海报墙布局的回归测试。
///
/// **存在的意义**：墙的两条承诺都只在几何里成立，而且静态看不出来——
/// 1.「窗口小墙就小」（只解码该显示的封面，这是它不吃内存的唯一理由）；
/// 2.「改窗口大小墙不洗牌」（同一格永远同一张海报，否则每拉一下窗口整面墙都在闪）。
/// 两者都不是 token 值，是 `LoginWallLayout` / `LoginWallPlan` 算出来的结果。
final class LoginWallPlanTests: XCTestCase {

    private func catalog(_ count: Int) -> [LoginWallPoster] {
        (0..<count).map { index in
            LoginWallPoster(id: "p-\(index)", art: LoginWallArt.make(seed: UInt64(index)))
        }
    }

    // MARK: 布局

    /// 小窗口造一面小墙。这条是「按视口算 tile 数」的全部意义：
    /// 固定 16×10 的旧做法在 960×640 上多造一倍有余的 tile，也就要多解码一倍封面。
    func testTileCountFollowsViewport() {
        let small = LoginWallLayout(size: CGSize(width: 960, height: 640), catalogSize: 200)
        let medium = LoginWallLayout(size: CGSize(width: 1320, height: 840), catalogSize: 200)
        let large = LoginWallLayout(size: CGSize(width: 2560, height: 1440), catalogSize: 200)

        XCTAssertLessThan(small.tileCount, medium.tileCount)
        XCTAssertLessThan(medium.tileCount, large.tileCount)

        // 常见 1320×840 窗口：8 列 × 6 行上下，不该出现 160 张那种量级。
        XCTAssertLessThanOrEqual(medium.tileCount, 80)
        XCTAssertGreaterThanOrEqual(medium.tileCount, 40)
    }

    /// 列宽被夹在上下限之间，且**窗口变宽不会让列宽无限变大**。
    func testColumnWidthIsClamped() {
        let tiny = LoginWallLayout(size: CGSize(width: 320, height: 480), catalogSize: 200)
        XCTAssertGreaterThanOrEqual(tiny.columnWidth, LoginWallStyle.minimumColumnWidth)

        let huge = LoginWallLayout(size: CGSize(width: 6000, height: 3000), catalogSize: 200)
        XCTAssertLessThanOrEqual(huge.columnWidth, LoginWallStyle.maximumColumnWidth)
    }

    /// 行数不超过条目总数：小库上重复得越少越好。
    func testRowCountIsCappedByCatalogSize() {
        let layout = LoginWallLayout(size: CGSize(width: 2560, height: 1440), catalogSize: 3)
        XCTAssertEqual(layout.rowCount, 3)
    }

    /// 空库不崩，也不造出负数列数。
    func testEmptyCatalogStillYieldsUsableLayout() {
        let layout = LoginWallLayout(size: CGSize(width: 1320, height: 840), catalogSize: 0)
        XCTAssertGreaterThanOrEqual(layout.columnCount, 1)
        XCTAssertGreaterThanOrEqual(layout.rowCount, 1)
        XCTAssertTrue(LoginWallPlan.make(catalog: [], columns: layout.columnCount, rows: layout.rowCount).isEmpty)
    }

    // MARK: 洗牌

    /// **改窗口大小不洗牌**：同一 (列, 行) 永远同一张海报。
    ///
    /// 这条决定了拖窗口时墙是「边缘补几格」还是「整面重排」。后者视觉上就是闪。
    func testLayoutChangeDoesNotReshuffleExistingTiles() {
        let catalog = catalog(139)
        let before = LoginWallPlan.make(catalog: catalog, columns: 8, rows: 6)
        let after = LoginWallPlan.make(catalog: catalog, columns: 11, rows: 7)

        for column in 0..<8 {
            for row in 0..<6 {
                XCTAssertEqual(
                    before[column].tiles[row].poster.id,
                    after[column].tiles[row].poster.id,
                    "(\(column),\(row)) 换了海报 = 窗口一动整面墙重排"
                )
            }
        }
    }

    /// 一列之内不重复同一张海报。
    ///
    /// `rowStride` 与条目数互质才成立。不互质时一列里会自己重复，
    /// 而「同一张海报竖着排两次」在墙上是看得出来的。
    func testNoPosterRepeatsWithinAColumn() {
        for catalogSize in [7, 12, 24, 47, 72, 139, 200] {
            let columns = LoginWallPlan.make(
                catalog: catalog(catalogSize), columns: 4, rows: min(6, catalogSize)
            )
            for column in columns {
                let ids = column.tiles.map(\.poster.id)
                XCTAssertEqual(Set(ids).count, ids.count, "catalogSize=\(catalogSize) 的某一列里出现了重复")
            }
        }
    }

    /// 抖动是位置的纯函数：同样的输入永远同样的输出，且落在预期幅度内。
    func testJitterIsDeterministicAndBounded() {
        for column in 0..<12 {
            for row in 0..<8 {
                XCTAssertEqual(LoginWallPlan.tilt(column: column, row: row),
                               LoginWallPlan.tilt(column: column, row: row))
                XCTAssertEqual(LoginWallPlan.offset(column: column, row: row),
                               LoginWallPlan.offset(column: column, row: row))
                XCTAssertLessThanOrEqual(abs(LoginWallPlan.tilt(column: column, row: row)), 1.6)
                XCTAssertLessThanOrEqual(abs(LoginWallPlan.offset(column: column, row: row)), 5)
            }
        }
    }

    /// 同一行相邻两列不总是同一张（否则墙上会出现横向条纹）。
    func testAdjacentColumnsDifferWithinARow() {
        let columns = LoginWallPlan.make(catalog: catalog(139), columns: 6, rows: 5)
        for row in 0..<5 {
            let ids = columns.map { $0.tiles[row].poster.id }
            XCTAssertEqual(Set(ids).count, ids.count, "第 \(row) 行出现了横向重复")
        }
    }

    /// tile 身份用列行而不是海报：小库上同一张海报合法地出现在多处，
    /// 用海报 id 当身份会在 `ForEach` 里撞身份、整面墙渲染错乱。
    func testTileIdentityIsPositionNotPoster() {
        let columns = LoginWallPlan.make(catalog: catalog(2), columns: 4, rows: 2)
        let allIDs = columns.flatMap { $0.tiles.map(\.id) }
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "tile id 撞了")
    }
}
