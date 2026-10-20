import CoreModel
import Foundation
import XCTest

@testable import OcPlayer

/// `P2-33`：侧车字幕的**有界并发下载**。
///
/// ## 为什么要它
///
/// 原实现逐条 `await`，**N 条字幕 = N 个串行网络往返**。局域网单次往返几十毫秒、
/// 跨网几百毫秒；一集挂 4–8 条（zh-Hans / zh-Hant / en / ja …）时首屏要多等
/// 好几百毫秒，而且期间字幕菜单是空的。
///
/// ## 两条硬约束
///
/// 1. **顺序必须保持**：`files[i]` 一定对应 `subtitles[i]` —— 挂载顺序决定内核
///    轨道序号，也决定「上次选的字幕（按 id 记的偏好）」指向哪一条。乱了就选错语言。
/// 2. **失败隔离**：某条失败只让那一格是 nil，不影响其它条。
final class ExternalSubtitleConcurrencyTests: XCTestCase {

    /// 造一批「字幕」：本函数只依赖元素能传回给 `download` 闭包，
    /// 所以用 `Int` 索引代替（`ExternalSubtitle` 的 init 在包内，AppTests 构造不了）。
    /// 被测逻辑（有界并发 / 顺序 / 失败隔离）与元素类型无关。
    private func subtitles(_ count: Int) -> [Int] {
        Array(0..<count)
    }

    /// **核心判据：并发执行，不是串行。**
    ///
    /// 每组任务都等 60 ms 才返回。8 条、并发上限 4：
    /// - 串行 → ≥ 480 ms
    /// - 4 路 → 约 120–180 ms
    ///
    /// 用耗时判定而不是「计数器峰值」：后者要加锁且容易被调度抖动干扰。
    func testDownloadsRunConcurrentlyNotSerially() async {
        let items = subtitles(8)
        let start = CFAbsoluteTimeGetCurrent()
        let files = await AppModel.downloadExternalSubtitles(items, limit: 4) { _ in
            try await Task.sleep(for: .milliseconds(60))
            return URL(fileURLWithPath: "/tmp/x.srt")
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertEqual(files.count, 8)
        XCTAssertTrue(files.allSatisfy { $0 != nil }, "全部应成功")
        // 串行需要 480 ms；4 路理论 120 ms。
        // ⚠️ 阈值取 420 而不是 350：审查实测**低 QoS 调度下**（`taskpolicy -b`，
        // CI 上常见）同样的 4 路并发可涨到 318 ms，叠加忙进程会越过 350 假红。
        // 420 让「串行下界 480」与「最慢实测并发 320」之间留出安全间隔。
        XCTAssertLessThan(elapsed, 420,
                          "8 条 × 60 ms 用时 \(Int(elapsed)) ms，说明仍在串行下载（串行 ≥480 ms）")
    }

    /// **顺序必须与入参严格一致**（哪怕完成顺序是乱的）。
    ///
    /// 故意让**后面的先完成**：若实现按完成顺序收集，数组就会倒过来。
    func testResultsKeepInputOrderEvenWhenCompletionOrderDiffers() async {
        let items = subtitles(6)
        let files = await AppModel.downloadExternalSubtitles(items, limit: 6) { subtitle in
            // index 越大，睡得越短 → 完成顺序与入参相反。
            let delay = 10 * (6 - subtitle)
            try await Task.sleep(for: .milliseconds(delay))
            return URL(fileURLWithPath: "/tmp/\(subtitle).srt")
        }
        // files[i] 必须来自 subtitles[i]。
        for (index, file) in files.enumerated() {
            XCTAssertEqual(file?.lastPathComponent, "\(index).srt",
                           "第 \(index) 格拿到了别的字幕（顺序被打乱）")
        }
    }

    /// **单条失败只影响自己那一格。**
    func testSingleFailureDoesNotAffectOthers() async {
        let items = subtitles(5)
        let files = await AppModel.downloadExternalSubtitles(items, limit: 3) { subtitle in
            if subtitle == 2 { throw CancellationError() }
            return URL(fileURLWithPath: "/tmp/\(subtitle).srt")
        }
        XCTAssertEqual(files.count, 5)
        XCTAssertNil(files[2], "失败的那格应是 nil")
        for index in [0, 1, 3, 4] {
            XCTAssertNotNil(files[index], "第 \(index) 条不该被别人的失败连累")
        }
    }

    /// **并发上限真的生效**（不会把所有任务一次全放出去）。
    ///
    /// 用锁保护的在飞计数观察峰值：上限 2、10 条时峰值应 ≤ 2。
    /// Swift 6 下 `@Sendable` 闭包不能捕获并修改局部 `var`，用一个引用容器装计数器。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var peakValue = 0
        func enter() {
            lock.lock(); defer { lock.unlock() }
            value += 1
            peakValue = max(peakValue, value)
        }
        func leave() {
            lock.lock(); defer { lock.unlock() }
            value -= 1
        }
        var peak: Int {
            lock.lock(); defer { lock.unlock() }
            return peakValue
        }
    }

    func testConcurrencyLimitIsRespected() async {
        let counter = Counter()
        let items = subtitles(10)
        _ = await AppModel.downloadExternalSubtitles(items, limit: 2) { _ in
            counter.enter()
            try await Task.sleep(for: .milliseconds(20))
            counter.leave()
            return URL(fileURLWithPath: "/tmp/x.srt")
        }
        XCTAssertLessThanOrEqual(counter.peak, 2, "在飞峰值 \(counter.peak) 超过上限 2")
        XCTAssertGreaterThanOrEqual(counter.peak, 2, "峰值 \(counter.peak) < 2，说明根本没并发")
    }

    /// **生产默认并发上限有断言**（审查指出：7 条用例全部显式传 `limit:`，
    /// 默认值一次都没被执行过 —— 把它改成 1（生产等价串行）测试仍全绿）。
    ///
    /// 这条钉住「默认值是 4」这个事实。生产调用点
    /// （`loadExternalSubtitles`）用的正是默认值，所以它一旦被改小，
    /// 这里立刻红。
    @MainActor
    func testProductionConcurrencyDefaultIsFour() {
        // `AppModel` 是 `@MainActor`，静态属性也带隔离 —— 不能在
        // `XCTAssertEqual` 的 autoclosure（非隔离）里直接读，先取出来。
        let limit = AppModel.externalSubtitleConcurrency
        XCTAssertEqual(limit, 4, "生产默认并发上限被改动（1 = 等价串行）")
    }

    /// **不传 `limit` 时真的按默认值并发。**
    ///
    /// 上一条只断言常量值，这条断言「默认参数确实用到了它」：8 条 × 60 ms，
    /// 若默认走串行（≥480 ms）会红；默认 4 路约 120–180 ms。
    ///
    /// ⚠️ 阈值给到 420 ms（不是 350）：审查实测低 QoS 下 8×60 ms 的并发耗时可涨到
    /// 318 ms，叠加忙进程会越过 350 —— 那条会假红。这里取 420 是为了让「串行」
    /// （下界 480 ms）与「最慢的并发」（实测 ≤320 ms）之间留出安全间隔。
    func testDefaultLimitActuallyRunsConcurrently() async {
        let items = subtitles(8)
        let start = CFAbsoluteTimeGetCurrent()
        // 注意：**不传 limit**，走生产默认值。
        let files = await AppModel.downloadExternalSubtitles(items) { _ in
            try await Task.sleep(for: .milliseconds(60))
            return URL(fileURLWithPath: "/tmp/x.srt")
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertEqual(files.count, 8)
        XCTAssertTrue(files.allSatisfy { $0 != nil })
        XCTAssertLessThan(elapsed, 420,
                          "不传 limit 时用时 \(Int(elapsed)) ms，疑似退化成串行（下界 480 ms）")
    }

    /// 空输入直接返回空数组（不该崩、不该起任务组）。
    func testEmptyInputReturnsEmpty() async {
        let files = await AppModel.downloadExternalSubtitles([Int](), limit: 4) { _ in
            XCTFail("不该被调用")
            return URL(fileURLWithPath: "/tmp/x.srt")
        }
        XCTAssertTrue(files.isEmpty)
    }

    /// `limit` 非法（0 / 负数）时按 1 处理，不该死锁。
    func testNonPositiveLimitStillCompletes() async {
        let items = subtitles(3)
        let files = await AppModel.downloadExternalSubtitles(items, limit: 0) { subtitle in
            URL(fileURLWithPath: "/tmp/\(subtitle).srt")
        }
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.allSatisfy { $0 != nil })
    }

    /// `limit` 大于条数时不该多起任务。
    func testLimitLargerThanCountIsClamped() async {
        let items = subtitles(2)
        let files = await AppModel.downloadExternalSubtitles(items, limit: 100) { subtitle in
            URL(fileURLWithPath: "/tmp/\(subtitle).srt")
        }
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0 != nil })
    }
}
