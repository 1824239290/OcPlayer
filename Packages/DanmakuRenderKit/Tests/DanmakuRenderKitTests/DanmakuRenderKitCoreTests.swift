import Foundation
import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import DanmakuRenderKit

/// 弹幕渲染层纯逻辑测试：轨道追击判定 / 队列轮询 / 轨道选择 / 复用池。
/// 全部 macOS 离屏运行，不碰 GPU、网络与 UIKit（GIF 侧是 `#if canImport(UIKit)`，
/// 本包测试只覆盖 macOS 可测的部分）。
///
/// 测试访问依赖两处纯访问级别放宽（见 PROVENANCE.md）：
/// - `DanmakuView` 的 `private extension` → `extension`（轨道选择/复用池方法 internal）
/// - 其余类型本就是 internal/public，`@testable` 可见。
final class DanmakuRenderKitCoreTests: XCTestCase {

    /// 轨道持 weak view——离屏建的 NSView 必须有人在用例存活期间顶着，否则 shoot 里
    /// `view!` 立刻空指针。tearDown 统一释放。
    private var retainedViews: [NSView] = []

    override func tearDown() {
        retainedViews.removeAll()
        super.tearDown()
    }

    // MARK: - 素材

    private struct TestModel: DanmakuCellModel {
        var cellClass: DanmakuCell.Type { DanmakuCell.self }
        var size: CGSize
        var track: UInt?
        var displayTime: Double
        var type: DanmakuCellType = .floating
        var identifier = UUID().uuidString

        func isEqual(to cellModel: DanmakuCellModel) -> Bool {
            identifier == cellModel.identifier
        }
    }

    private func floatingModel(width: CGFloat, displayTime: Double) -> TestModel {
        TestModel(size: CGSize(width: width, height: 20), displayTime: displayTime)
    }

    private func makeView(width: CGFloat = 800) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        retainedViews.append(view)
        return view
    }

    private func makeFloatingTrack(viewWidth: CGFloat = 800) -> DanmakuFloatingTrack {
        DanmakuFloatingTrack(view: makeView(width: viewWidth))
    }

    @discardableResult
    private func placePreviousCell(
        in track: DanmakuFloatingTrack,
        width: CGFloat,
        x: CGFloat,
        displayTime: Double
    ) -> DanmakuCell {
        let cell = DanmakuCell(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        cell.model = TestModel(size: CGSize(width: width, height: 20), displayTime: displayTime)
        track.shoot(danmaku: cell)
        // 离屏没有 presentation layer，realFrame 回退到 frame；直接摆位置。
        cell.frame = NSRect(x: x, y: 10, width: width, height: 20)
        return cell
    }

    // MARK: - 漂浮轨道追击判定（canShoot 纯数学）

    /// 下一条更慢（永远追不上前一条）→ 可以发。
    func testFloatingCanShootWhenNextCanNeverCatchUp() {
        let track = makeFloatingTrack()
        // viewWidth 800：preWidth = 1000, preV ≈ 166.7；nextWidth = 1200, nextV = 120
        // nextV - preV ≤ 0 → 永远追不上 → true
        placePreviousCell(in: track, width: 200, x: 100, displayTime: 6)
        XCTAssertTrue(track.canShoot(danmaku: floatingModel(width: 400, displayTime: 10)))
    }

    /// 前一条刚发（还没离开右缘）→ 不让追尾，false。
    func testFloatingCanShootRejectsFreshlyShotCell() {
        let track = makeFloatingTrack()
        // preRight = 900 → distance = 800 - 900 - 10 < 0 → false
        placePreviousCell(in: track, width: 200, x: 700, displayTime: 6)
        XCTAssertFalse(track.canShoot(danmaku: floatingModel(width: 400, displayTime: 10)))
    }

    /// 下一条明显更快且会追尾（追击时间 < 前一条剩余运动时间）→ false。
    func testFloatingCanShootRejectsCollision() {
        let track = makeFloatingTrack()
        // viewWidth 800：cell w=100 x=10 → preRight=110, distance=680, preV=150；
        // next w=300 displayTime=0.5 → nextV=2200；time=680/2050≈0.33 < preCellTime≈0.73 → false
        placePreviousCell(in: track, width: 100, x: 10, displayTime: 6)
        XCTAssertFalse(track.canShoot(danmaku: floatingModel(width: 300, displayTime: 0.5)))
    }

    /// 重叠模式放行一切。
    func testFloatingCanShootAllowsWhenOverlap() {
        let track = makeFloatingTrack()
        track.isOverlap = true
        placePreviousCell(in: track, width: 100, x: 10, displayTime: 6)
        XCTAssertTrue(track.canShoot(danmaku: floatingModel(width: 300, displayTime: 0.5)))
    }

    /// 空轨道直接放行。
    func testFloatingCanShootAllowsWhenEmpty() {
        let track = makeFloatingTrack()
        XCTAssertTrue(track.canShoot(danmaku: floatingModel(width: 200, displayTime: 5)))
    }

    // MARK: - 垂直轨道（顶部/底部）判定

    func testVerticalCanShootOnlyWhenEmpty() {
        let track = DanmakuVerticalTrack(view: makeView())
        XCTAssertTrue(track.canShoot(danmaku: floatingModel(width: 100, displayTime: 5)))

        let cell = DanmakuCell(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        cell.model = TestModel(size: CGSize(width: 100, height: 20), displayTime: 5)
        track.cells.append(cell)
        XCTAssertFalse(track.canShoot(danmaku: floatingModel(width: 100, displayTime: 5)))

        track.isOverlap = true
        XCTAssertTrue(track.canShoot(danmaku: floatingModel(width: 100, displayTime: 5)))
    }

    // MARK: - 队列池轮询

    func testQueuePoolRoundRobins() {
        let pool = DanmakuQueuePool(name: "test", queueCount: 2, qos: .utility)
        let q0 = pool.queue
        let q1 = pool.queue
        XCTAssertTrue(q0 !== q1, "相邻两次取队列要交替")
        XCTAssertTrue(pool.queue === q0, "第三个取回第一个")
        XCTAssertTrue(pool.queue === q1, "第四个取回第二个")
    }

    // MARK: - 轨道选择（空视图：均分轨取第一条、适配轨取第一条、同步轨取第一条）

    func testTrackSelectionOnEmptyView() {
        let view = DanmakuView(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
        view.play()  // canShoot 需要播放态

        XCTAssertTrue(view.canShoot(danmaku: floatingModel(width: 200, displayTime: 5)))

        // 全部轨道都空 → 均分轨/适配轨/同步轨都选第一条（index 0）
        XCTAssertEqual(view.findLeastNumberDanmakuTrack(for: floatingModel(width: 200, displayTime: 5)).index, 0)
        XCTAssertEqual(view.findSuitableTrack(for: floatingModel(width: 200, displayTime: 5))?.index, 0)
        XCTAssertEqual(view.findSuitableSyncTrack(for: floatingModel(width: 200, displayTime: 5), at: 0.5)?.index, 0)
    }

    // MARK: - 复用池

    func testCellPoolRoundTripPerCellClass() {
        let view = DanmakuView(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
        let cell = DanmakuCell(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let model = floatingModel(width: 100, displayTime: 5)
        cell.model = model

        view.appendCellToPool(cell)
        let pooled = view.cellFromPool(model)
        XCTAssertTrue(pooled === cell, "入池后应原样取出")
        XCTAssertNil(view.cellFromPool(model), "池空后再取返回 nil")
    }
}
