import CErika
import DiagnosticsKit
import Foundation
import PlaybackKit

// `ErikaOutputStatus` → `PlaybackOutputSnapshot` 的纯映射。
//
// 这个文件的意义就是**别再丢字段**：内核一直在报面格式与回退原因（`get_output_status`
// 的 13 个字段），此前只读了 `active_encoding` 一个，排查「HDR 源为什么出 SDR」时
// 只能靠猜。映射是纯函数、不碰句柄，所以可以在无 GPU 的机器上单测（CI 可跑）。

extension PlaybackOutputSnapshot.SurfaceFormat {
    /// `ErikaOutputSurfaceFormat`（0/1/2）→ 中立枚举。未知值不猜，回落 `.unknown`。
    init(_ raw: Int32) {
        switch raw {
        case Int32(ErikaOutputSurfaceFormat_EightBitUnorm.rawValue): self = .eightBitUnorm
        case Int32(ErikaOutputSurfaceFormat_TenBitUnorm.rawValue): self = .tenBitUnorm
        case Int32(ErikaOutputSurfaceFormat_SixteenBitFloat.rawValue): self = .sixteenBitFloat
        default: self = .unknown
        }
    }
}

extension PlaybackOutputSnapshot.FallbackReason {
    /// `ErikaOutputFallbackReason`（0…8）→ 中立枚举。
    ///
    /// 内核承诺 **只追加、不重编号 0…8**，所以这里可以按值硬映射；超出范围
    /// （内核比 App 新）一律 `.unknown`——把不认识的码猜成某个具体原因，
    /// 会让排查走错方向，比「未知」更坏。
    init(_ raw: Int32) {
        switch raw {
        case Int32(ErikaOutputFallbackReason_None.rawValue): self = .none
        case Int32(ErikaOutputFallbackReason_DisplayHdrUnsupported.rawValue):
            self = .displayHdrUnsupported
        case Int32(ErikaOutputFallbackReason_HybridCompositionRequired.rawValue):
            self = .hybridCompositionRequired
        case Int32(ErikaOutputFallbackReason_WgpuBackendNotVulkan.rawValue):
            self = .wgpuBackendNotVulkan
        case Int32(ErikaOutputFallbackReason_Rgba16FloatSurfaceFormatUnavailable.rawValue):
            self = .rgba16FloatSurfaceFormatUnavailable
        case Int32(ErikaOutputFallbackReason_NativeWindowDataSpaceApiUnavailable.rawValue):
            self = .nativeWindowDataSpaceApiUnavailable
        case Int32(ErikaOutputFallbackReason_ScrgbDataSpaceVerificationFailed.rawValue):
            self = .scrgbDataSpaceVerificationFailed
        case Int32(ErikaOutputFallbackReason_SurfaceConfigureFailed.rawValue):
            self = .surfaceConfigureFailed
        case Int32(ErikaOutputFallbackReason_LegacyAppleEdrUnsupported.rawValue):
            self = .legacyAppleEdrUnsupported
        default: self = .unknown
        }
    }
}

extension PlaybackOutputSnapshot {
    /// `active_headroom` 只有 `active_headroom_known` 为真时才算数：内核在不知道
    /// 显示器比例时也会填一个「有效内容回退值」，把它当权威读数会得出错误结论
    /// （例如把 SDR 屏报成 HDR 就绪）。
    init(_ raw: ErikaOutputStatus) {
        self.init(
            surfaceFormat: SurfaceFormat(raw.surface_format),
            fallbackReason: FallbackReason(raw.fallback_reason),
            fallbackCount: raw.fallback_count,
            activeHeadroom: raw.active_headroom_known ? raw.active_headroom : nil,
            activeHeadroomKnown: raw.active_headroom_known,
            extendedLinearActive: raw.extended_linear_active
        )
    }

    /// 日志字段（诊断包里按字符串比对；枚举用 rawValue 而不是本地化文案）。
    var logFields: [String: DiagnosticValue] {
        [
            "surface_format": .string(surfaceFormat.rawValue),
            "fallback_reason": .string(fallbackReason.rawValue),
            "fallback_count": .unsignedInteger(fallbackCount),
            "headroom_known": .boolean(activeHeadroomKnown),
            "headroom": activeHeadroom.map { .double(Double($0)) } ?? .null,
            "extended_linear": .boolean(extendedLinearActive),
        ]
    }

    /// 压缩摘要（日志消息用）。
    var summaryLine: String {
        var parts = ["面格式 \(surfaceFormat.rawValue)"]
        if fallbackReason != .none { parts.append("回退 \(fallbackReason.rawValue)") }
        if fallbackCount > 0 { parts.append("累计 \(fallbackCount) 次") }
        if let activeHeadroom {
            parts.append(String(format: "headroom ×%.2f", activeHeadroom))
        }
        if extendedLinearActive { parts.append("扩展线性") }
        return parts.joined(separator: " · ")
    }
}
