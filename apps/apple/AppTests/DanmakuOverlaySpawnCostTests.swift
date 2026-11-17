#if os(macOS)
import XCTest
import AppKit
import DanmakuKit
import DanmakuRenderKit
@testable import OcPlayer

/// 弹幕 spawn 热路径的**主线程**成本。
///
/// 第一轮把「单条栅格化」从 2 435 µs 降到 247 µs（见 `OverlayDanmakuCellRenderTests`），
/// 但那条路跑在 `DanmakuAsyncLayer` 的池队列上。**主线程**上每条弹幕仍要做：
/// 建模型（含 `NSAttributedString.size()` 文本测量）→ 取 cell（复用池）→ 选轨
/// （`findSuitableTrack` 遍历轨道）→ `setNeedsDisplay` 触发异步绘制。
///
/// `DanmakuSpawnPlanner` 的单拍上限是 24 条，这里把「一次 300 条补发」拆成
/// 「300 次模型构造」与「300 次 `view.shoot`」两段分别量，作为主线程帧预算的基准。
/// 断言用**宽松**上限（真回归是数量级的变化），值本身写进失败信息里便于取证。
@MainActor
final class DanmakuOverlaySpawnCostTests: XCTestCase {

    /// 真实弹幕的文本长度分布：短的刷屏、长的吐槽都有。
    private static let samples = [
        "233", "哈哈哈哈哈", "前方高能", "awsl", "这个画面太美了",
        "这里是伏笔 记一下", "泪目", "第一次看的时候没懂 二刷才明白",
        "名场面", "BGM 一起鸡皮疙瘩就起来了", "打卡",
    ]

    private func makeComment(_ index: Int) -> DanmakuJSONParser.Entry {
        DanmakuJSONParser.Entry(
            time: Double(index) * 0.05,
            mode: index % 17 == 0 ? .top : (index % 23 == 0 ? .bottom : .scroll),
            color: index % 5 == 0 ? 0xFFD700 : 0xFFFFFF,
            text: Self.samples[index % Self.samples.count]
        )
    }

    private func makeView() -> DanmakuView {
        let view = DanmakuView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.enableCellReusable = true      // 生产配置：`DanmakuOverlayController` 打开复用池
        view.trackHeight = 22 * 1.35
        view.displayArea = 0.75
        view.paddingTop = 10
        view.paddingBottom = 16
        view.play()                          // `shoot` 只在 .play 状态下收弹幕
        return view
    }

    /// 模型构造 = 主线程上那条 `NSAttributedString.size()` 文本测量。
    func testModelConstructionMainThreadCost() {
        let count = 300
        // 预热（首次会建立字体缓存）
        for index in 0..<20 { _ = OverlayDanmakuModel(comment: makeComment(index), fontSize: 22) }

        let start = DispatchTime.now().uptimeNanoseconds
        var models: [OverlayDanmakuModel] = []
        models.reserveCapacity(count)
        for index in 0..<count {
            models.append(OverlayDanmakuModel(comment: makeComment(index), fontSize: 22))
        }
        let totalMicros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
        XCTAssertEqual(models.count, count)

        let perItem = totalMicros / Double(count)
        // 单拍上限 24 条 → 一拍的主线程测量成本 = perItem × 24
        XCTAssertLessThan(
            perItem, 200,
            "单条模型构造 \(perItem) µs（300 条共 \(totalMicros / 1000) ms；24 条/拍 ≈ \(perItem * 24 / 1000) ms）"
        )
    }

    /// `view.shoot` = 取 cell + 选轨 + setNeedsDisplay（栅格化本身在池队列上异步）。
    func testShootBurstMainThreadCost() {
        let count = 300
        let view = makeView()
        var models: [OverlayDanmakuModel] = []
        models.reserveCapacity(count)
        for index in 0..<count {
            models.append(OverlayDanmakuModel(comment: makeComment(index), fontSize: 22))
        }
        // 预热复用池与轨道
        for model in models.prefix(24) { view.shoot(danmaku: model) }
        view.clean()

        let start = DispatchTime.now().uptimeNanoseconds
        for model in models { view.shoot(danmaku: model) }
        let totalMicros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000

        let perItem = totalMicros / Double(count)
        XCTAssertLessThan(
            perItem, 200,
            "单条 shoot \(perItem) µs（300 条共 \(totalMicros / 1000) ms；24 条/拍 ≈ \(perItem * 24 / 1000) ms）"
        )
        view.clean()
        view.clearPool()
    }

    /// 端到端：一次 300 条补发（`DanmakuSpawnPlanner` 会摊成约 13 拍）的**主线程**总成本。
    func testFullBurstMainThreadCost() {
        let count = 300
        let view = makeView()
        view.clean()
        view.clearPool()

        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<count {
            let model = OverlayDanmakuModel(comment: makeComment(index), fontSize: 22)
            view.shoot(danmaku: model)
        }
        let totalMicros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000

        // 13 拍 × 16.7 ms ≈ 217 ms 的预算里，主线程这一段应远小于一帧
        XCTAssertLessThan(
            totalMicros / 1000, 150,
            "300 条补发的主线程总成本 \(totalMicros / 1000) ms（单条 \(totalMicros / Double(count)) µs）"
        )
        view.clean()
        view.clearPool()
    }
}
#endif
