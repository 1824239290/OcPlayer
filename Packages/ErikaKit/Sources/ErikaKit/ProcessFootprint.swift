import Darwin
import DiagnosticsKit
import Foundation

/// 进程级内存读数，和内核分项采样打同一条日志。
///
/// 为什么要它：`erika_presenter_get_resource_status` 只统计画面 / 弹幕 / 渲染器
/// 自己的分配，**不包含解封装 / HTTP 读取缓冲**（内核的 Rust 堆，进程里表现为
/// MALLOC_LARGE / SMALL）。两条弹幕路线共用的媒体读取链路出问题时，内核计数器
/// 是平的、进程 footprint 在涨——必须两个读数同时采样才能对上号。
public struct ProcessFootprint: Sendable, Equatable {
    /// `task_vm_info.phys_footprint`：计入内存压力的物理内存（字节）。
    /// 和 Activity Monitor 的「内存」列同源，iOS/macOS 上就是它超限触发系统清理。
    public var physFootprintBytes: UInt64
    /// `getrusage(RUSAGE_SELF).ru_maxrss`：进程启动以来的 RSS 峰值（字节）。
    public var maxRSSBytes: UInt64
    /// 系统 malloc 全部 zone 的 `size_allocated` 之和（字节）。
    /// App Swift 对象和内核的 Rust/C 堆都落在 malloc；IOSurface / Metal / CoreAnimation
    /// 的位图是 malloc 之外的 VM。进程 footprint 涨了而 malloc 不动 → 是 VM/位图侧。
    public var mallocAllocatedBytes: UInt64

    public static func current() -> ProcessFootprint {
        var footprint: UInt64 = 0
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            footprint = UInt64(info.phys_footprint)
        }

        var usage = rusage()
        var maxRSS: UInt64 = 0
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            // macOS 的 ru_maxrss 单位是字节（Linux 是 KB）。
            maxRSS = UInt64(usage.ru_maxrss)
        }

        return ProcessFootprint(
            physFootprintBytes: footprint,
            maxRSSBytes: maxRSS,
            mallocAllocatedBytes: Self.readMallocAllocated()
        )
    }

    private static func readMallocAllocated() -> UInt64 {
        var zonePointers: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        malloc_get_all_zones(mach_task_self_, nil, &zonePointers, &zoneCount)
        guard let zonePointers, zoneCount > 0 else { return 0 }
        var total: UInt64 = 0
        for index in 0..<Int(zoneCount) {
            guard let zoneRaw = UnsafeMutableRawPointer(bitPattern: zonePointers[index]) else { continue }
            let zone = zoneRaw.assumingMemoryBound(to: malloc_zone_t.self)
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            total += UInt64(stats.size_allocated)
        }
        return total
    }

    public var logFields: [String: DiagnosticValue] {
        [
            "process_footprint_bytes": .unsignedInteger(physFootprintBytes),
            "process_max_rss_bytes": .unsignedInteger(maxRSSBytes),
            "process_malloc_bytes": .unsignedInteger(mallocAllocatedBytes),
        ]
    }

    public var summaryLine: String {
        "进程 \(Self.fmt(physFootprintBytes)) · 峰值RSS \(Self.fmt(maxRSSBytes)) · malloc \(Self.fmt(mallocAllocatedBytes))"
    }

    private static func fmt(_ bytes: UInt64) -> String {
        bytes == 0 ? "0B" : String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}
