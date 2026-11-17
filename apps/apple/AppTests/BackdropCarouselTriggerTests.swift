import XCTest
@testable import OcPlayer

/// 氛围轮播的「何时尝试装载」判定。
///
/// 这条判定错一次的代价是**整个会话都停在纯色底**，而它只在冷启动抢跑时出错
/// （实机日志 2026-09-30：启动瞬间五个请求全部 -1009，氛围池的随机查询与它的
/// 回退源同时为空 → 池子装不上，而 `.task(id:)` 只认 sessionGeneration，
/// 它没变 → 再也不重试。下次启动网络恰好就绪，于是"自己好了"）。
final class BackdropCarouselTriggerTests: XCTestCase {

    /// 冷启动抢跑：池子空、首页也还没数据 —— 此时**没有**可用的补救，
    /// 触发键就是普通的会话键（等首页数据到位再谈重试）。
    func testColdStartRaceHasNothingToRetryWithYet() {
        let trigger = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: true, hasHomeFallback: false)

        XCTAssertFalse(trigger.shouldRetry)
        XCTAssertEqual(trigger.session, 1)
    }

    /// 首页数据到位 = 一次补救机会：触发键必须**变化**，否则 `.task` 不会重跑，
    /// 背景就一直灰着 —— 这正是原来的 bug。
    func testHomeDataArrivalChangesTheTriggerKey() {
        let raced = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: true, hasHomeFallback: false)
        let recoverable = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: true, hasHomeFallback: true)

        XCTAssertTrue(recoverable.shouldRetry, "首页有数据了就该再试一次")
        XCTAssertNotEqual(
            raced, recoverable,
            "触发键必须变，否则 .task 不会重跑，背景会一直灰着")
    }

    /// 池子装好之后触发键要**稳定**：不能再因为首页刷新（isLoading 翻转、
    /// 下拉刷新等）而重启换片循环。
    func testLoadedPoolKeepsTriggerKeyStable() {
        let loadedWithoutHomeData = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: false, hasHomeFallback: false)
        let loadedWithHomeData = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: false, hasHomeFallback: true)

        XCTAssertFalse(loadedWithoutHomeData.shouldRetry)
        XCTAssertFalse(loadedWithHomeData.shouldRetry)
        XCTAssertEqual(
            loadedWithoutHomeData, loadedWithHomeData,
            "池子已装好时，首页数据变化不该重启换片循环")
    }

    /// 换服务器 / 重新登录必须重拉池子（会话代次并进触发键）。
    func testSessionChangeAlwaysChangesTheKey() {
        let before = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: false, hasHomeFallback: true)
        let after = BackdropCarouselTrigger(
            sessionGeneration: 2, poolIsEmpty: false, hasHomeFallback: true)

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.session, 2)
    }

    /// 完整时序回归：抢跑 → 首页到位（重试）→ 装好（停止重试）。
    func testFullRecoverySequence() {
        let raced = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: true, hasHomeFallback: false)
        let retry = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: true, hasHomeFallback: true)
        let settled = BackdropCarouselTrigger(
            sessionGeneration: 1, poolIsEmpty: false, hasHomeFallback: true)

        XCTAssertNotEqual(raced, retry, "1→2：首页到位应触发重试")
        XCTAssertNotEqual(retry, settled, "2→3：装好后应收敛（换片循环重启一次即稳定）")
        XCTAssertFalse(settled.shouldRetry)
    }
}
