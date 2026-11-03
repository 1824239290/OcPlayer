import XCTest
@testable import OcPlayer

/// 「一轮新的滚动动作」判据（`DetailPagePager.isNewScrollGesture`）。
///
/// ## 为什么要有这组用例
///
/// 原来的判据是 `phase.contains(.began) || !hasPreciseScrollingDeltas`，在装了
/// **Mos**（鼠标滚轮平滑）的机器上两个分支同时为假 —— Mos 把一格滚轮摊成一串
/// `hasPreciseScrollingDeltas == true`、`phase == []` 的连续事件（实测 Mos 4.2.1，
/// 见 `DetailPagePager.beginsNewScrollGesture` 的注释）。后果是第二页翻不回第一页。
///
/// 这组用例把「三种输入都读得通」钉住：传统鼠标、真实触控板、Mos 平滑流。
/// 只要判据退回「只看设备特征」，`testMosSmoothStreamArmsOnFirstEvent` 之外的
/// 触控板与 Mos 交错用例都会变红。
final class DetailPageWheelGestureTests: XCTestCase {

    private typealias Subject = DetailPagePager

    // MARK: - 传统鼠标：每格独立

    func testPlainWheelEachDetentIsNewGesture() {
        // 两格之间隔 300ms（人手正常速度），每格都应算新一轮。
        XCTAssertTrue(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.0, lastTimestamp: 99.7),
            "传统鼠标：相隔 300ms 属于两下独立动作")
    }

    func testPlainWheelFirstEventIsNewGesture() {
        // 还没收过事件（lastTimestamp == 0），第一发必然是新一轮。
        XCTAssertTrue(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 500.0, lastTimestamp: 0))
    }

    func testPlainWheelRapidDetentsShareOneGesture() {
        // 一格之内系统可能连发几发（同一格的细分），间隔 8ms 不算新动作。
        XCTAssertFalse(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.008, lastTimestamp: 100.000),
            "同一格内的细分事件不能算新一轮，否则一格就会翻页")
    }

    // MARK: - 真实触控板：以 phase 为准

    func testTrackpadBeganIsNewGesture() {
        XCTAssertTrue(Subject.isNewScrollGesture(
            phaseBegan: true, phaseIsEmpty: false,
            timestamp: 100.0, lastTimestamp: 99.0),
            "触控板 .began 无论间隔多久都是新一轮")
    }

    func testTrackpadChangedMidGestureIsNotNewGesture() {
        // 手势中段：phase 非空且不含 began。即便间隔很久（手指按住不动）也不是新动作。
        XCTAssertFalse(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: false,
            timestamp: 105.0, lastTimestamp: 100.0),
            "同一手势的 .changed 不能算新一轮，否则滚到顶后继续滚会直接翻回去")
    }

    // MARK: - Mos 平滑流：没有 phase，靠时间间隔

    /// 这是本次修复的核心回归点。
    ///
    /// Mos 发的流：phase 空、hasPreciseScrollingDeltas 为真。改造前这条判据
    /// 两个分支都落空（不是 began、也不是「非精确」），于是永远不武装。
    func testMosSmoothStreamArmsOnFirstEvent() {
        XCTAssertTrue(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.0, lastTimestamp: 0),
            "Mos 流的第一发必须算新一轮，否则第二页永远翻不回第一页")
    }

    func testMosSmoothStreamMidStreamIsNotNewGesture() {
        // 平滑流大约每 16ms 一发（60Hz），一串之内都不能算新动作。
        for offset in stride(from: 0.016, through: 0.096, by: 0.016) {
            XCTAssertFalse(Subject.isNewScrollGesture(
                phaseBegan: false, phaseIsEmpty: true,
                timestamp: 100.0 + offset, lastTimestamp: 100.0),
                "Mos 流内间隔 \(offset)s 不应算新一轮")
        }
    }

    func testMosSmoothStreamAfterPauseIsNewGesture() {
        // 用户停手再滚：间隔远超 120ms，必须重新武装。
        XCTAssertTrue(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.5, lastTimestamp: 100.0),
            "Mos 停手 500ms 后再滚必须是新一轮")
    }

    func testMosInertiaTailIsNotNewGesture() {
        // Mos 的惯性滑行尾巴事件同样 phase 空，且与主体紧邻（<16ms），
        // 不能被当成用户的新动作 —— 否则滑行就把页面顶回去了。
        XCTAssertFalse(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.016, lastTimestamp: 100.0))
    }

    // MARK: - 边界

    func testGapBoundaryIsInclusiveAtThreshold() {
        // 正好等于阈值算新一轮（>=，不是 >）。
        XCTAssertTrue(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.120, lastTimestamp: 100.000))
    }

    func testJustBelowGapIsSameGesture() {
        XCTAssertFalse(Subject.isNewScrollGesture(
            phaseBegan: false, phaseIsEmpty: true,
            timestamp: 100.119, lastTimestamp: 100.000))
    }
}
