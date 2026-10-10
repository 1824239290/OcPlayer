import Foundation
import Testing
@testable import ErikaKit

/// `render_tick_with_timing` 的延迟夹取。
///
/// 内核对这个值有**硬约束**（`erika.h`：有限且 ±0.25 s 内），超界不是被忽略而是
/// 直接判错。逐帧调用点如果不自己夹，一次时钟异常（`CADisplayLink` 尚未入 runloop、
/// 系统休眠唤醒）就会让整帧推进失败——表现为画面卡住而日志里一堆 render_tick 失败。
/// 所以边界逐条钉住。不实例化 presenter，无需 GPU。
@Suite("呈现时序延迟夹取")
struct RenderTickTimingTests {

    @Test("正常范围内的延迟原样通过")
    func passesReasonableDelays() {
        #expect(RenderLoop.sanitizedPresentationDelay(0) == 0)
        #expect(RenderLoop.sanitizedPresentationDelay(0.016) == 0.016)
        #expect(RenderLoop.sanitizedPresentationDelay(-0.008) == -0.008)
    }

    @Test("边界值 ±0.25 有效")
    func boundariesAreInclusive() {
        // 内核接受「±0.25 秒以内」，边界本身是合法的——差一点点就退化成无 timing tick。
        #expect(RenderLoop.sanitizedPresentationDelay(0.25) == 0.25)
        #expect(RenderLoop.sanitizedPresentationDelay(-0.25) == -0.25)
    }

    @Test("超出 ±0.25 返回 nil（调用方退回无 timing 的 render_tick）")
    func rejectsOutOfRangeDelays() {
        #expect(RenderLoop.sanitizedPresentationDelay(0.2501) == nil)
        #expect(RenderLoop.sanitizedPresentationDelay(-0.2501) == nil)
        // 系统休眠唤醒后 targetTimestamp 可能离现在很远。
        #expect(RenderLoop.sanitizedPresentationDelay(12) == nil)
        #expect(RenderLoop.sanitizedPresentationDelay(-60) == nil)
    }

    @Test("非有限值一律拒绝")
    func rejectsNonFiniteDelays() {
        #expect(RenderLoop.sanitizedPresentationDelay(.nan) == nil)
        #expect(RenderLoop.sanitizedPresentationDelay(.infinity) == nil)
        #expect(RenderLoop.sanitizedPresentationDelay(-.infinity) == nil)
    }

    @Test("约束常量与内核 erika.h 的声明一致")
    func maximumMatchesKernelContract() {
        // 内核注释：「must be finite and within +/-0.25 seconds」。改了这里就等于
        // 改了和内核的契约，必须有意识。
        #expect(RenderLoop.maximumPresentationDelay == 0.25)
    }
}
