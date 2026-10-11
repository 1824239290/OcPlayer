import Darwin
import DiagnosticsKit
import ErikaKit
import Foundation

/// 播放结束后的 malloc 空闲页归还。
///
/// **为什么要它**：Erika 内核（Rust 堆 + 静态链接的 FFmpeg）和 App 层 Swift 对象都走系统
/// malloc。停止播放后内核虽然释放了媒体会话，libmalloc 对 MALLOC_SMALL/LARGE 的空闲页
/// 默认不 decommit，`phys_footprint` 因此长期停在播放时的高位（实测 stop 后 ~270MB，
/// 不做 relief 时要等下一次 open 重建会话才回落）。
///
/// `malloc_zone_pressure_relief` 是系统公开 API：把 zone 里的空闲页立即还给内核。
/// 只碰空闲页，不影响任何存活分配；对没有压力 relief 语义的 zone 是 no-op。
///
/// **两拍调度**（`scheduleAfterStop`）：内核 destroy 不 join demux 线程（上游
/// AimesSoft/Erika#125），那个线程最多还能带着 HTTP 缓冲活 20 秒（fetch 重试预算）。
/// 第一拍（2s）回收 presenter 析构立刻释放的页；第二拍（25s）等 demux 线程尾巴退出后
/// 再收一次。每拍前后各采一条进程 footprint，`diagnostics.jsonl` 里直接看 relief 拿回多少。
@MainActor
enum MallocPressureRelief {

    /// `stopPlayback()` 收尾时调用：安排多拍归还。重复调用会取消上一轮未触发的拍。
    /// Task 捕获的只有本 enum 的静态成员，不持有任何对象——播放器控制器的生命周期与它无关。
    ///
    /// 拍位依据真机实测（2026-08-28）：+2s/+25s 时内核媒体会话尚未释放完（malloc 仍 200MB
    /// 在册，relief 无页可收）；vmmap 显示释放发生在之后一分钟内——内核 demux/prefetch
    /// 线程不 join、单次 HTTP 读最长阻塞 60s（上游 AimesSoft/Erika#125），析构链条要等它。
    /// 因此补 +60s/+120s 两拍：前两拍收 Swift 侧立释放的页，后两拍收内核尾巴释放完的页。
    /// 多拍是幂等 no-op（没有空闲页时 pressure_relief 立即返回），代价可忽略。
    static func scheduleAfterStop() {
        stopTask?.cancel()
        // 相对间隔（秒）：累计落点 +2s / +25s / +60s / +120s。
        let beats: [(interval: UInt64, label: String)] = [
            (2, "stop+2s"), (23, "stop+25s"), (35, "stop+60s"), (60, "stop+120s"),
        ]
        stopTask = Task {
            for beat in beats {
                try? await Task.sleep(for: .seconds(beat.interval))
                guard !Task.isCancelled else { return }
                await Task.detached { perform(reason: beat.label) }.value
            }
        }
    }

    private static var stopTask: Task<Void, Never>?

    // MARK: - relief 本体（非隔离，后台线程执行）

    /// 对进程内所有 malloc zone 做一次压力归还，前后各采一条 footprint 进诊断日志。
    nonisolated private static func perform(reason: String) {
        let before = ProcessFootprint.current()

        var zonePointers: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        malloc_get_all_zones(mach_task_self_, nil, &zonePointers, &zoneCount)
        if let zonePointers, zoneCount > 0 {
            for index in 0..<Int(zoneCount) {
                guard let zoneRaw = UnsafeMutableRawPointer(bitPattern: zonePointers[index]) else { continue }
                let zone = zoneRaw.assumingMemoryBound(to: malloc_zone_t.self)
                // goal 传 0 = 归还全部空闲页。
                malloc_zone_pressure_relief(zone, 0)
            }
        }

        let after = ProcessFootprint.current()
        let message = "malloc relief reason=\(reason) "
            + "进程 \(format(before.physFootprintBytes)) → \(format(after.physFootprintBytes)) · "
            + "malloc \(format(before.mallocAllocatedBytes)) → \(format(after.mallocAllocatedBytes))"
        playerLog.info(message, fields: [
            "reason": .string(reason),
            "before_footprint_bytes": .unsignedInteger(before.physFootprintBytes),
            "before_malloc_bytes": .unsignedInteger(before.mallocAllocatedBytes),
            "after_footprint_bytes": .unsignedInteger(after.physFootprintBytes),
            "after_malloc_bytes": .unsignedInteger(after.mallocAllocatedBytes),
        ])
    }

    private nonisolated static func format(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}
