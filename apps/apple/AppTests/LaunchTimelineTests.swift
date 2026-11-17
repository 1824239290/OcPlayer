@testable import OcPlayer
import XCTest

/// 启动编排的逐帧钉子。分镜常量与方案预览（HTML 逐帧验证版）同源，
/// 这里钉的是「Swift 实现没把拍子弹错」：关键帧数值、交叉窗口、退场判定、
/// 减弱动态降级。改分镜先改这里——预览与实现共享同一套常量。
@MainActor
final class LaunchTimelineTests: XCTestCase {
    private let timeline = LaunchTimeline()

    // MARK: - 描边

    func testHeadDrawProgressKeyframes() {
        let f0 = timeline.evaluate(elapsed: 0, readyAt: nil, reduceMotion: false)
        XCTAssertEqual(f0.headProgress, 0, accuracy: 0.0001)
        let fMid = timeline.evaluate(elapsed: 390, readyAt: nil, reduceMotion: false)
        XCTAssertEqual(fMid.headProgress, 0.5, accuracy: 0.001)
        let fEnd = timeline.evaluate(elapsed: 700, readyAt: nil, reduceMotion: false)
        XCTAssertEqual(fEnd.headProgress, 1, accuracy: 0.0001)
    }

    func testHeadStrokeGateAndFadeOut() {
        // 落笔前不可见（否则圆头端帽在起点漏一个圆点）。
        XCTAssertLessThan(timeline.evaluate(elapsed: 0, readyAt: nil, reduceMotion: false).headStrokeOpacity, 0.01)
        XCTAssertGreaterThan(timeline.evaluate(elapsed: 150, readyAt: nil, reduceMotion: false).headStrokeOpacity, 0.99)
        // 画完交叉淡出（780–930），给填充让位。
        XCTAssertEqual(timeline.evaluate(elapsed: 1000, readyAt: nil, reduceMotion: false).headStrokeOpacity, 0, accuracy: 0.0001)
    }

    func testHeadFillCrossfade() {
        XCTAssertLessThan(timeline.evaluate(elapsed: 650, readyAt: nil, reduceMotion: false).headFillOpacity, 0.01)
        XCTAssertEqual(timeline.evaluate(elapsed: 710, readyAt: nil, reduceMotion: false).headFillOpacity, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(timeline.evaluate(elapsed: 760, readyAt: nil, reduceMotion: false).headFillOpacity, 0.99)
    }

    func testWhiskersStaggered() {
        let f = timeline.evaluate(elapsed: 615, readyAt: nil, reduceMotion: false)
        XCTAssertGreaterThan(f.whiskerProgress[0], 0)
        XCTAssertEqual(f.whiskerProgress[3], 0, accuracy: 0.0001, "第四根 700ms 才起笔")
        let fDone = timeline.evaluate(elapsed: 850, readyAt: nil, reduceMotion: false)
        XCTAssertTrue(fDone.whiskerProgress.allSatisfy { $0 == 1 })
    }

    // MARK: - 播放三角与光晕

    func testTriangleSpringOvershoots() {
        let start = timeline.evaluate(elapsed: 470, readyAt: nil, reduceMotion: false)
        XCTAssertEqual(start.triangleScale, 0.55, accuracy: 0.0001)
        // 窗口内有过冲（>1），落定时回到 1。
        let overshoot = stride(from: 470.0, through: 740.0, by: 2.0).map {
            timeline.evaluate(elapsed: $0, readyAt: nil, reduceMotion: false).triangleScale
        }.max()!
        XCTAssertGreaterThan(overshoot, 1.0)
        XCTAssertLessThan(overshoot, 1.15)
        XCTAssertEqual(timeline.evaluate(elapsed: 740, readyAt: nil, reduceMotion: false).triangleScale, 1, accuracy: 0.001)
    }

    func testGlowBloomWindow() {
        XCTAssertLessThan(timeline.evaluate(elapsed: 200, readyAt: nil, reduceMotion: false).glowOpacity, 0.01, "光晕随三角起，不抢描边")
        XCTAssertGreaterThan(timeline.evaluate(elapsed: 800, readyAt: nil, reduceMotion: false).glowOpacity, 0.3)
    }

    // MARK: - 退场判定（不垫时长）

    func testExitWaitsForMinVisible() {
        // 就绪早于落定：动画路径等到落定（900ms）才退，减弱动态 600ms。
        XCTAssertEqual(timeline.exitStart(readyAt: 300, reduceMotion: false), 900)
        XCTAssertEqual(timeline.exitStart(readyAt: 300, reduceMotion: true), 600)
        // 就绪晚于下限：加一拍缓冲再退。
        XCTAssertEqual(timeline.exitStart(readyAt: 2600, reduceMotion: false), 2720)
        XCTAssertEqual(timeline.exitStart(readyAt: 950, reduceMotion: false), 1070)
        // 未就绪：永不退（呼吸等待）。
        XCTAssertNil(timeline.exitStart(readyAt: nil, reduceMotion: false))
    }

    func testIdleBreathingThenExit() {
        // 落定即呼吸：幅度 1.2%，起于 1、中段 >1。
        XCTAssertEqual(timeline.evaluate(elapsed: 900, readyAt: 2600, reduceMotion: false).markScale, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(timeline.evaluate(elapsed: 1550, readyAt: 2600, reduceMotion: false).markScale, 1.001)
        // 数据就绪触发交棒：标志先淡出、整层再淡出，终点撤除。
        let midExit = timeline.evaluate(elapsed: 2720 + 130, readyAt: 2600, reduceMotion: false)
        XCTAssertLessThan(midExit.markOpacity, 1)
        XCTAssertGreaterThan(midExit.overlayOpacity, 0)
        let done = timeline.evaluate(elapsed: 2720 + 260, readyAt: 2600, reduceMotion: false)
        XCTAssertEqual(done.overlayOpacity, 0, accuracy: 0.0001)
        XCTAssertTrue(done.isFinished)
        // 呼吸幅度在交棒前 150ms 收敛，衔接放大不跳变。
        let atExitStart = timeline.evaluate(elapsed: 2720, readyAt: 2600, reduceMotion: false)
        XCTAssertEqual(atExitStart.markScale, 1, accuracy: 0.02)
    }

    // MARK: - 氛围 hold（背景没穿好衣服不交棒）

    func testAmbienceHoldKeepsOverlayWhenPending() throws {
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: nil, holdForAmbience: true, reduceMotion: false))
        XCTAssertEqual(start, 900 + 1600, accuracy: 0.0001, "池子没就绪：下限之上多等 1.6s")
        let mid = timeline.evaluate(
            elapsed: 2000, readyAt: 45, ambienceReadyAt: nil, holdForAmbience: true, reduceMotion: false)
        XCTAssertEqual(mid.overlayOpacity, 1, accuracy: 0.0001, "等待期不退场")
        XCTAssertGreaterThan(mid.markScale, 1.001, "等待期标志在呼吸")
        XCTAssertFalse(mid.isFinished)
    }

    func testAmbienceArrivalPullsExitEarlier() throws {
        // 池子在下限之后、上限之前就绪：退场提前到「就绪 + 120ms」。
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: 2280, holdForAmbience: true, reduceMotion: false))
        XCTAssertEqual(start, 2400, accuracy: 0.0001)
        let before = timeline.evaluate(
            elapsed: 2300, readyAt: 45, ambienceReadyAt: 2280, holdForAmbience: true, reduceMotion: false)
        XCTAssertEqual(before.overlayOpacity, 1, accuracy: 0.0001)
        let during = timeline.evaluate(
            elapsed: 2400 + 130, readyAt: 45, ambienceReadyAt: 2280, holdForAmbience: true, reduceMotion: false)
        XCTAssertLessThan(during.overlayOpacity, 1)
    }

    func testAmbienceArrivalBeforeFloorUsesFloorWithGrace() throws {
        // 池子在下限之前就绪：退场取「就绪+120」与下限的较大者。
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: 800, holdForAmbience: true, reduceMotion: false))
        XCTAssertEqual(start, 920, accuracy: 0.0001)
    }

    func testAmbienceHoldAppliesToReduceMotion() throws {
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: nil, holdForAmbience: true, reduceMotion: true))
        XCTAssertEqual(start, 600 + 1600, accuracy: 0.0001)
    }

    func testNoHoldWithoutSession() throws {
        // onboarding / 本地播放：没有氛围图可等，照原节奏退。
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: nil, holdForAmbience: false, reduceMotion: false))
        XCTAssertEqual(start, 900, accuracy: 0.0001)
    }

    // MARK: - 首页骨架 hold（首页没加载好不交棒）

    func testHomeHoldKeepsOverlayWhenPending() throws {
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, homeReadyAt: nil, holdForHome: true, reduceMotion: false))
        XCTAssertEqual(start, 900 + 1600, accuracy: 0.0001, "首页还在骨架期：下限之上多等 1.6s")
        let mid = timeline.evaluate(
            elapsed: 2000, readyAt: 45, homeReadyAt: nil, holdForHome: true, reduceMotion: false)
        XCTAssertEqual(mid.overlayOpacity, 1, accuracy: 0.0001, "等待期不退场")
        XCTAssertFalse(mid.isFinished)
    }

    func testHomeArrivalPullsExitEarlier() throws {
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, homeReadyAt: 2280, holdForHome: true, reduceMotion: false))
        XCTAssertEqual(start, 2400, accuracy: 0.0001)
    }

    func testHomeArrivalBeforeFloorUsesFloorWithGrace() throws {
        let start = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, homeReadyAt: 800, holdForHome: true, reduceMotion: false))
        XCTAssertEqual(start, 920, accuracy: 0.0001)
    }

    func testBothHoldsShareOneCap() throws {
        // 两个门控都在等：共享一个上限，不叠加成 900+3200。
        let bothPending = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: nil, homeReadyAt: nil,
            holdForAmbience: true, holdForHome: true, reduceMotion: false))
        XCTAssertEqual(bothPending, 900 + 1600, accuracy: 0.0001)
        // 一个到了、另一个还在等：仍是上限封顶（ cap 比就绪+120 晚）。
        let oneArrived = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: 2280, homeReadyAt: nil,
            holdForAmbience: true, holdForHome: true, reduceMotion: false))
        XCTAssertEqual(oneArrived, 900 + 1600, accuracy: 0.0001)
        // 两个都到了：取较晚的就绪 + 一拍。
        let bothArrived = try XCTUnwrap(timeline.exitStart(
            readyAt: 45, ambienceReadyAt: 2280, homeReadyAt: 2500,
            holdForAmbience: true, holdForHome: true, reduceMotion: false))
        XCTAssertEqual(bothArrived, 2620, accuracy: 0.0001)
    }

    func testNoExitBeforeReady() {
        let f = timeline.evaluate(elapsed: 5000, readyAt: nil, reduceMotion: false)
        XCTAssertEqual(f.overlayOpacity, 1, accuracy: 0.0001)
        XCTAssertFalse(f.isFinished)
    }

    // MARK: - 减弱动态

    func testReduceMotionShowsStaticMark() {
        let f = timeline.evaluate(elapsed: 180, readyAt: nil, reduceMotion: true)
        XCTAssertEqual(f.headStrokeOpacity, 0)
        XCTAssertEqual(f.headFillOpacity, 1)
        XCTAssertEqual(f.whiskerFillOpacity, [1, 1, 1, 1])
        XCTAssertEqual(f.triangleScale, 1)
        XCTAssertEqual(f.markOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(f.markScale, 1, accuracy: 0.0001)
        let early = timeline.evaluate(elapsed: 0, readyAt: nil, reduceMotion: true)
        XCTAssertEqual(early.markOpacity, 0, accuracy: 0.0001, "静态标志也要 180ms 淡入，不闪现")
    }
}
