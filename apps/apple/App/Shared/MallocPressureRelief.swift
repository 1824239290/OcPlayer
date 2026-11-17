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
/// AimesSoft/liberika#125），那个线程最多还能带着 HTTP 缓冲活 20 秒（fetch 重试预算）。
/// 第一拍（2s）回收 presenter 析构立刻释放的页；第二拍（25s）等 demux 线程尾巴退出后
/// 再收一次。每拍前后各采一条进程 footprint，`diagnostics.jsonl` 里直接看 relief 拿回多少。
@MainActor
enum MallocPressureRelief {

    /// `stopPlayback()` 收尾时调用：安排多拍归还。重复调用会取消上一轮未触发的拍。
    /// Task 捕获的只有本 enum 的静态成员，不持有任何对象——播放器控制器的生命周期与它无关。
    ///
    /// ## ⚠️ 「没收益就早退」已评估并**否决**（`LIVE-03`）
    ///
    /// 曾加过一个早退判据：某一拍回收量太小就不再排后续拍，理由是「省掉三次无用的
    /// zone 遍历」。**独立审查指出这是错的，已撤销**：
    ///
    /// - 本函数开头那段注释自己就写着「+2s/+25s 时内核媒体会话尚未释放完，relief 无页可收」
    ///   —— 也就是说**前两拍本来就该是 0**，真正的回收在 +60s/+120s 收内核尾巴。
    ///   拿第一拍的结果决定要不要排后两拍，判据在逻辑上无效。
    /// - 成本实测：一次全 zone relief sweep = **58 ns**，一次 `TASK_VM_INFO` = **1.18 µs**。
    ///   「省掉三次遍历」省的是**纳秒级**，而丢掉的是「几百 MB 内核尾巴」这个功能存在的理由。
    ///
    /// 所以四拍原样保留。这也意味着清单 `LIVE-03` 里「省掉三次无用的 zone 遍历」这个
    /// 预期收益是**基于错误的成本模型**（把 58 ns 当成可观开销），不值得为它冒风险。
    ///
    /// 拍位依据真机实测（2026-08-28）：+2s/+25s 时内核媒体会话尚未释放完（malloc 仍 200MB
    /// 在册，relief 无页可收）；vmmap 显示释放发生在之后一分钟内——内核 demux/prefetch
    /// 线程不 join、单次 HTTP 读最长阻塞 60s（上游 AimesSoft/liberika#125），析构链条要等它。
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

    /// 对进程内所有 malloc zone 做一次压力归还，返回 **API 报告回收的字节数**。
    ///
    /// ## 日志为什么改成报 `released` 而不是 `malloc size_allocated`（`LIVE-03`）
    ///
    /// 原先这条日志同时打 `进程 physFootprint` 与 `malloc size_allocated`。前者在
    /// 本机实测**几乎不动**（5 轮四拍全 ≤0.1 MB），后者读的是 `malloc_zone_statistics`
    /// 的 `size_allocated` —— 而 `malloc_zone_pressure_relief` 归还的是**空闲页**。
    /// 两者都不是「这一拍到底拿回多少」的好读数。
    ///
    /// **正确读数就是 API 的返回值**：`malloc.h` 明确写着它返回
    /// "the number of bytes released"。这里累加所有 zone 的返回值报出来。
    ///
    /// ⚠️ **一处我原先说错、已更正**：我曾断言 `size_allocated` 「结构上不可能因
    /// relief 而变」。审查指出这不成立 —— `size_allocated` 的语义是 "reserved in
    /// memory"，而 relief 做的是 munmap，munmap 可以降低 reserved VM。所以那个说法
    /// 是错的，删字段的**真实理由**只是「它作为本拍收益的读数不好用」，不是「它必然不动」。
    @discardableResult
    nonisolated private static func perform(reason: String) -> UInt64 {
        let before = ProcessFootprint.current()

        var zonePointers: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        malloc_get_all_zones(mach_task_self_, nil, &zonePointers, &zoneCount)
        var released: UInt64 = 0
        if let zonePointers, zoneCount > 0 {
            for index in 0..<Int(zoneCount) {
                guard let zoneRaw = UnsafeMutableRawPointer(bitPattern: zonePointers[index]) else { continue }
                let zone = zoneRaw.assumingMemoryBound(to: malloc_zone_t.self)
                // goal 传 0 = 归还全部空闲页。返回值就是「这一 zone 拿回多少字节」，
                // 比 footprint 差值可靠（后者会被同期其它分配/释放掩盖）。
                released += UInt64(malloc_zone_pressure_relief(zone, 0))
            }
        }

        let after = ProcessFootprint.current()
        // `released` 是 API 报的「拿回多少」；footprint 仅供对照观察
        // （它会受同期其它分配影响，单看差值会误判）。
        let message = "malloc relief reason=\(reason) "
            + "进程 \(format(before.physFootprintBytes)) → \(format(after.physFootprintBytes))"
            + "（API 报告回收 \(format(released))）"
        playerLog.info(message, fields: [
            "reason": .string(reason),
            "before_footprint_bytes": .unsignedInteger(before.physFootprintBytes),
            "after_footprint_bytes": .unsignedInteger(after.physFootprintBytes),
            // API 返回值：`malloc.h` 语义是 "number of bytes released"。
            "released_bytes": .unsignedInteger(released),
        ])
        return released
    }

    /// 测试用：跑一次 relief 并返回回收字节数（供 `AppTests` 验证「不改已分配字节」）。
    @discardableResult
    nonisolated static func relieveOnceForTesting() -> UInt64 {
        perform(reason: "test")
    }

    private nonisolated static func format(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}
