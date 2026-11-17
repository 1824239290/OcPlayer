@testable import OcPlayer
import XCTest

/// 启动状态机（`LaunchPresenter`）的时序钉子。分镜数学在 `LaunchTimelineTests`；
/// 这里钉的是**有状态**的部分——早到信号先存后补、迟到不回卷、重排只提前、
/// 退场任务按时间轴钟触发（睡眠基准是「排定时钟距退场的剩余量」；直接睡时间轴
/// 绝对时刻的话，收尾会整体迟到 readyAt 那么多，最后一条用例就是防它回归）。
///
/// 日期全部注入：`beginForTesting(at:)` 定时间轴零点，信号方法的 `now:` 定到达
/// 时刻，同步用例不靠真等。固定日期用例里排定的退场任务睡 0ms、测试返回后
/// 立即触发——只翻各自 presenter 的 isVisible，不影响别的用例。
@MainActor
final class LaunchPresenterTests: XCTestCase {
    /// 固定时间轴零点（绝对值无意义，只要求与注入的信号时刻同一坐标系）。
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    override func setUp() {
        super.setUp()
        // 静态「已播」标记跨用例存活，必须每个用例前复位。
        LaunchPresenter.resetPlaybackGateForTesting()
    }

    // MARK: - 门控

    func testBeginSkipsInTestHost() {
        let presenter = LaunchPresenter()
        presenter.begin(reduceMotion: false)
        XCTAssertFalse(presenter.isVisible, "测试宿主必须静默跳过")
        XCTAssertTrue(presenter.started, "started 已置位（防重入）")
    }

    // MARK: - 早到信号：先存后补

    func testSignalsBeforeBeginAreReplayedAtTimelineStart() {
        let presenter = LaunchPresenter()
        presenter.contentBecameReady(
            expectAmbience: true, expectHome: true, now: epoch.addingTimeInterval(0.03))
        XCTAssertFalse(presenter.started, "begin 之前只排队，不起表")

        presenter.beginForTesting(at: epoch)
        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(presenter.readyAtMs, 0, "回放按时间轴零点记时刻")
        XCTAssertTrue(presenter.holdForAmbience)
        XCTAssertTrue(presenter.holdForHome)
        // hold 已立而氛围/首页信号一个都没到：上限封顶（900 + 1600）。
        XCTAssertEqual(presenter.scheduledExitStartMs, 2500)
    }

    func testEarlyAmbienceSignalIsReplayedAtContentReady() {
        let presenter = LaunchPresenter()
        presenter.beginForTesting(at: epoch)
        presenter.ambienceBecameReady(now: epoch.addingTimeInterval(0.03))
        XCTAssertNil(presenter.ambienceReadyAtMs, "hold 标志未立：只存不记时刻")

        presenter.contentBecameReady(expectAmbience: true, now: epoch.addingTimeInterval(0.045))
        XCTAssertEqual(presenter.ambienceReadyAtMs, 45, "早到信号在内容就绪时补记")
        XCTAssertEqual(presenter.scheduledExitStartMs, 900, "max(下限 900, 45 + 120)")
    }

    func testEarlyHomeSignalIsReplayedAtContentReady() {
        let presenter = LaunchPresenter()
        presenter.beginForTesting(at: epoch)
        presenter.homeBecameReady(now: epoch.addingTimeInterval(0.03))
        XCTAssertNil(presenter.homeReadyAtMs)

        presenter.contentBecameReady(
            expectAmbience: false, expectHome: true, now: epoch.addingTimeInterval(0.045))
        XCTAssertEqual(presenter.homeReadyAtMs, 45)
        XCTAssertEqual(presenter.scheduledExitStartMs, 900)
    }

    // MARK: - hold 门控与共享上限

    func testHoldPendingRaisesExitToSharedCap() {
        let presenter = LaunchPresenter()
        presenter.beginForTesting(at: epoch)
        presenter.contentBecameReady(
            expectAmbience: true, expectHome: true, now: epoch.addingTimeInterval(0.045))
        XCTAssertEqual(
            presenter.scheduledExitStartMs, 2500, "双门控共享一个上限（900 + 1600），不叠加")
    }

    func testNoHoldsWithoutSession() {
        let presenter = LaunchPresenter()
        presenter.beginForTesting(at: epoch)
        presenter.contentBecameReady(
            expectAmbience: false, expectHome: false, now: epoch.addingTimeInterval(0.045))
        XCTAssertFalse(presenter.holdForAmbience)
        XCTAssertFalse(presenter.holdForHome)
        XCTAssertEqual(presenter.scheduledExitStartMs, 900, "onboarding / 本地播放：按下限退")
    }

    // MARK: - 迟到不回卷 / 重排只提前

    func testArrivalsPullExitEarlierWithReschedule() {
        let presenter = LaunchPresenter()
        var scheduled: [Double] = []
        presenter.onExitScheduled = { exitStartMs, _ in scheduled.append(exitStartMs) }
        presenter.beginForTesting(at: epoch)
        presenter.contentBecameReady(
            expectAmbience: true, expectHome: true, now: epoch.addingTimeInterval(0.045))

        // 氛围 1200ms 到：home 还在等，退场仍被共享上限顶住（deadline 不变，不重排）。
        presenter.ambienceBecameReady(now: epoch.addingTimeInterval(1.2))
        XCTAssertEqual(presenter.ambienceReadyAtMs, 1200)
        XCTAssertEqual(presenter.scheduledExitStartMs, 2500)

        // home 1300ms 到：退场提前到 max(900, 45+120, 1200+120, 1300+120) = 1420。
        presenter.homeBecameReady(now: epoch.addingTimeInterval(1.3))
        XCTAssertEqual(presenter.scheduledExitStartMs, 1420)
        XCTAssertEqual(scheduled, [2500, 1420], "重排每次回调，且只提前不推迟")
    }

    func testLateArrivalIgnoredOnceExitStartPassed() {
        let presenter = LaunchPresenter()
        presenter.beginForTesting(at: epoch)
        presenter.contentBecameReady(
            expectAmbience: true, now: epoch.addingTimeInterval(0.045))

        // 当前退场起点 = 上限 2500；2600 已过点，信号必须被忽略（不回卷）。
        presenter.ambienceBecameReady(now: epoch.addingTimeInterval(2.6))
        XCTAssertNil(presenter.ambienceReadyAtMs, "迟到不回卷：交棒已开始，信号作废")
        XCTAssertEqual(presenter.scheduledExitStartMs, 2500)
    }

    // MARK: - 退场钟（回归钉：睡眠基准是剩余量，不是时间轴绝对时刻）

    func testDismissalFiresOnTimelineClock() async throws {
        let presenter = LaunchPresenter()
        let start = Date.now
        presenter.beginForTesting(at: start)

        // 真等 1.2s 让「数据就绪」信号迟到（时间轴已走过一段）——这正是旧 bug 的
        // 放大器：睡眠若用时间轴绝对时刻，这 1.2s 会被叠加进等待。
        try await Task.sleep(for: .milliseconds(1200))
        presenter.contentBecameReady(expectAmbience: false, now: Date.now)
        let readyAt = try XCTUnwrap(presenter.readyAtMs)
        XCTAssertGreaterThan(readyAt, 1100, "信号确实晚于下限")
        XCTAssertEqual(presenter.scheduledExitStartMs ?? -1, readyAt + 120, accuracy: 0.5, "就绪 + 一拍")
        XCTAssertTrue(presenter.isVisible, "退场尚未开始")

        // 修复后撤除点 ≈ readyAt + 120 + 260 ≈ 1.58s；旧 bug 要到
        // 1.2s + 1.32s + 260ms ≈ 2.78s。2.3s 处检查足以区分两者。
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(presenter.isVisible, "退场应已按时间轴钟收官（旧 bug 此刻还挂着）")
    }
}
