import ErikaKit
import XCTest

@testable import OcPlayer

/// `LIVE-03`：`MallocPressureRelief` 的早退判据与日志字段。
///
/// ## 背景（真实会话实测）
///
/// 5 次运行 × 四拍（+2s/+25s/+60s/+120s），`physFootprint` 变化 **≤0.1 MB**：
/// ```
/// 350.0→350.0 · 367.2→367.2 · 336.0→336.0 · 325.5→325.5 · 330.8→330.7
/// ```
/// 也就是说后三拍基本是纯开销。而它同时打印的 `mallocAllocatedBytes` 读的是
/// `malloc_zone_statistics.size_allocated`，**结构上不可能因 relief 而变**
/// （relief 归还的是空闲页，不改「已分配字节」）—— 那是个永远不动的指标，
/// 给读者用来判断「relief 有没有用」是误导。
final class MallocPressureReliefTests: XCTestCase {

    /// **relief 不改 `mallocAllocatedBytes`** —— 这就是删掉那个日志字段的理由。
    ///
    /// 这条是 `LIVE-03` 的核心证据：若哪天 `malloc_zone_pressure_relief` 真的
    /// 会改「已分配字节」，那删字段就删错了，这条会红。
    func testPressureReliefDoesNotChangeAllocatedBytes() {
        // 制造一些分配再释放，让 zone 里有空闲页可归还。
        for _ in 0..<200 {
            var buffer: [UInt8] = Array(repeating: 0, count: 64 * 1024)
            buffer[0] = 1
            _ = buffer.count
        }
        let before = ProcessFootprint.current()
        _ = MallocPressureRelief.relieveOnceForTesting()
        let after = ProcessFootprint.current()

        // 已分配字节不该因 relief 变化（允许极小抖动：其它线程也在分配）。
        let delta = Int64(after.mallocAllocatedBytes) - Int64(before.mallocAllocatedBytes)
        XCTAssertLessThan(
            abs(delta), 4 * 1024 * 1024,
            "relief 不该显著改变 malloc 已分配字节（实测 \(before.mallocAllocatedBytes) → \(after.mallocAllocatedBytes)）")
    }
}
