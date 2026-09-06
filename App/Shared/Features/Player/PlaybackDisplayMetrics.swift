import Foundation

#if os(macOS)
import AppKit
#endif

/// 显示器 EDR headroom 的取值与净化。headroom = 相对 SDR 参考白的倍数
/// （SDR 屏 ≈ 1.0，内置 XDR ≈ 8），内核按 `> 1.0` 判定 HDR 源要真出 EDR。
///
/// 背景契约：内核在 macOS 上**不探测屏幕**（官方 demo 也是宿主人喂 `--edr`），
/// HDR 输出档位全靠宿主在创建 config 里给 headroom；运行时通道
/// `set_output_headroom` 等内核 Metal 后端补齐后才生效。
enum PlaybackDisplayMetrics {
    /// 内核 capi 接受的范围（超界按边界钳制）。
    static let headroomRange: ClosedRange<Double> = 1.0...10_000

    /// 钳到内核接受区间。屏幕原始读数可能异常（缺失/非有限），统一兜底 1.0（SDR）。
    static func sanitized(_ raw: Double) -> Double {
        guard raw.isFinite else { return headroomRange.lowerBound }
        return min(max(raw, headroomRange.lowerBound), headroomRange.upperBound)
    }

    /// 引擎创建时喂内核 config 的 headroom：此刻播放器窗口所在屏的最大潜在
    /// EDR 倍数。非 macOS 返回 0 = 「不指定」，维持内核默认行为（iOS 的
    /// headroom 通道内核侧尚未接，保持原状）。
    @MainActor
    static func headroomForEngineCreation() -> Float {
        #if os(macOS)
        Float(sanitized(currentScreenEDRHeadroom() ?? headroomRange.lowerBound))
        #else
        0
        #endif
    }

    #if os(macOS)
    /// 当前 key/main 窗口所在屏的最大潜在 EDR 倍数；拿不到屏返回 nil。
    /// 播放器是主窗口覆盖层，keyWindow / mainWindow 即播放窗口。
    @MainActor
    static func currentScreenEDRHeadroom() -> Double? {
        let screen = NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        return screen.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) }
    }
    #endif
}
