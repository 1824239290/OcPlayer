import CErika
import DiagnosticsKit
import XCTest
@testable import ErikaKit

/// `step()` 锁内攒下的失败 → 锁外日志的映射。
///
/// **刻意不建 `ErikaEngine`**：构造 `ErikaPresenter` 需要真内核与 Metal，无 GPU 的
/// 机器上跑不了；而 `step()` 由渲染线程的 `CADisplayLink` 驱动、又是 private，
/// 全仓没有任何运行时用例能覆盖它（驱动 `ErikaEngine` 的测试只碰 `open()` /
/// `audioOnlyTick()` 这类同步入口）。所以这里测的是**契约**：
/// 哪种失败落到哪条消息、带哪个节流键 —— 这两件事改错了不会有任何现象，
/// 只能靠断言钉住。
///
/// 注意：本套件钉的不是「修复前的缺陷」（那时 poll_event 没有节流、日志在锁内），
/// 那两点属于结构约束，没有可断言的运行时表现。见 CHANGELOG 的说明。
final class RenderFailureLogTests: XCTestCase {

    /// 收集 `emitFailures` 的输出来断言，不落盘。
    private typealias Emission = (message: String, throttle: DiagnosticThrottle?)

    private func emit(_ failures: [ErikaEngine.RenderFailure]) -> [Emission] {
        var emissions: [Emission] = []
        ErikaEngine.emitFailures(failures) { message, throttle in
            emissions.append((message, throttle))
        }
        return emissions
    }

    private func playerError(_ text: String = "audio output stalled at EOF") -> ErikaError {
        ErikaError(status: ErikaStatus_PlayerError, message: text)
    }

    // MARK: - 消息文本（改动前后必须逐字节一致）

    func testRenderTickFailureMessage() {
        let emissions = emit([.renderTick(playerError())])
        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(
            emissions[0].message.hasPrefix("render_tick 失败 error="),
            "实际：\(emissions[0].message)")
    }

    func testRenderTickUnknownFailureMessage() {
        let emissions = emit([.renderTickUnknown(TestError.boom)])
        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(
            emissions[0].message.hasPrefix("render_tick 失败（未知） error="),
            "实际：\(emissions[0].message)")
    }

    func testPollEventFailureMessage() {
        let emissions = emit([.pollEvent(playerError())])
        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(
            emissions[0].message.hasPrefix("poll_event 失败 error="),
            "实际：\(emissions[0].message)")
    }

    func testPollEventUnknownFailureMessage() {
        let emissions = emit([.pollEventUnknown(TestError.boom)])
        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(
            emissions[0].message.hasPrefix("poll_event 失败（未知） error="),
            "实际：\(emissions[0].message)")
    }

    func testUnknownMessageCarriesTheUnderlyingDescription() {
        let emissions = emit([.pollEventUnknown(TestError.boom)])
        XCTAssertTrue(emissions[0].message.contains("boom"), "实际：\(emissions[0].message)")
    }

    // MARK: - 节流键（本条最容易悄悄改坏）

    func testRenderAndPollUseTheSameInterval() {
        XCTAssertEqual(ErikaEngine.renderThrottle.interval, 1)
        XCTAssertEqual(ErikaEngine.pollThrottle.interval, 1)
    }

    /// 同一个节流键上谁先到谁就占住窗口，另一条会被整段压掉 ——
    /// 内核同时坏 render 与 poll 时，恰恰是最需要两种证据都在的时候。
    func testRenderAndPollThrottleKeysAreDistinct() {
        XCTAssertNotEqual(
            ErikaEngine.renderThrottle.key, ErikaEngine.pollThrottle.key,
            "render 与 poll 共用节流键会互相压制")
    }

    func testFailuresRouteToMatchingThrottle() {
        let emissions = emit([
            .renderTick(playerError()),
            .pollEvent(playerError()),
            .renderTickUnknown(TestError.boom),
            .pollEventUnknown(TestError.boom),
        ])
        XCTAssertEqual(emissions.count, 4)
        XCTAssertEqual(emissions[0].throttle?.key, ErikaEngine.renderThrottle.key)
        XCTAssertEqual(emissions[1].throttle?.key, ErikaEngine.pollThrottle.key)
        XCTAssertEqual(emissions[2].throttle?.key, ErikaEngine.renderThrottle.key)
        XCTAssertEqual(emissions[3].throttle?.key, ErikaEngine.pollThrottle.key)
    }

    /// 每一处都必须带节流：漏一个就等于恢复成「逐帧刷屏」。
    func testNoFailureIsEmittedWithoutThrottle() {
        let emissions = emit([
            .renderTick(playerError()),
            .renderTickUnknown(TestError.boom),
            .pollEvent(playerError()),
            .pollEventUnknown(TestError.boom),
        ])
        XCTAssertEqual(emissions.count, 4)
        for (index, emission) in emissions.enumerated() {
            XCTAssertNotNil(emission.throttle, "第 \(index) 条没有节流")
        }
    }

    // MARK: - 顺序与空集

    func testOrderIsPreserved() {
        let emissions = emit([
            .pollEvent(playerError("first")),
            .renderTick(playerError("second")),
            .pollEventUnknown(TestError.boom),
        ])
        XCTAssertEqual(emissions.count, 3)
        XCTAssertTrue(emissions[0].message.contains("first"))
        XCTAssertTrue(emissions[1].message.contains("second"))
        XCTAssertTrue(emissions[2].message.hasPrefix("poll_event 失败（未知）"))
    }

    func testNoFailuresEmitsNothing() {
        XCTAssertTrue(emit([]).isEmpty)
    }

    // MARK: - 替身

    private enum TestError: Error, CustomStringConvertible {
        case boom
        var description: String { "boom" }
    }
}
