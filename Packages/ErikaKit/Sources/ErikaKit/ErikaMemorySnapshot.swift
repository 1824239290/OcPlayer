import CErika
import DiagnosticsKit
import Foundation

/// 内核渲染内存分项快照（`erika_presenter_get_resource_status` 的中立镜像）。
///
/// 两条弹幕路线共用同一份采样：渲染线程每 10s 打一条 + open/stop 各打一条，
/// 内核弹幕 2G 峰值和 overlay 缓慢爬升分别落在哪些分项，`diagnostics.jsonl`
/// 里直接可见。字段都是字节数（0 表示该能力未分配），`drawableCount` 是
/// 窗口交换链上在手的 drawable 数量。
public struct ErikaMemorySnapshot: Sendable, Equatable {
    public var deviceCurrentAllocatedBytes: UInt64
    public var deviceRecommendedWorkingSetBytes: UInt64
    public var drawableEstimatedBytes: UInt64
    public var videoFrameBytes: UInt64
    public var overlayAtlasBytes: UInt64
    public var danmakuAtlasBytes: UInt64
    public var danmakuVertexBufferBytes: UInt64
    public var upscalerBytes: UInt64
    public var rendererTrackedBytes: UInt64
    public var presenterCPUDanmakuAtlasBytes: UInt64
    public var drawableCount: UInt32
    public var outputModeSwitches: UInt64

    public init() {
        deviceCurrentAllocatedBytes = 0
        deviceRecommendedWorkingSetBytes = 0
        drawableEstimatedBytes = 0
        videoFrameBytes = 0
        overlayAtlasBytes = 0
        danmakuAtlasBytes = 0
        danmakuVertexBufferBytes = 0
        upscalerBytes = 0
        rendererTrackedBytes = 0
        presenterCPUDanmakuAtlasBytes = 0
        drawableCount = 0
        outputModeSwitches = 0
    }

    init(_ raw: ErikaPresenterResourceStatus) {
        deviceCurrentAllocatedBytes = raw.device_current_allocated_bytes
        deviceRecommendedWorkingSetBytes = raw.device_recommended_working_set_bytes
        drawableEstimatedBytes = raw.drawable_estimated_bytes
        videoFrameBytes = raw.video_frame_bytes
        overlayAtlasBytes = raw.overlay_atlas_bytes
        danmakuAtlasBytes = raw.danmaku_atlas_bytes
        danmakuVertexBufferBytes = raw.danmaku_vertex_buffer_bytes
        upscalerBytes = raw.upscaler_bytes
        rendererTrackedBytes = raw.renderer_tracked_bytes
        presenterCPUDanmakuAtlasBytes = raw.presenter_cpu_danmaku_atlas_bytes
        drawableCount = raw.drawable_count
        outputModeSwitches = raw.output_mode_switches
    }

    /// 诊断日志的字段（原始字节数，精度不损失）。
    public var logFields: [String: DiagnosticValue] {
        [
            "device_allocated_bytes": .unsignedInteger(deviceCurrentAllocatedBytes),
            "video_frame_bytes": .unsignedInteger(videoFrameBytes),
            "overlay_atlas_bytes": .unsignedInteger(overlayAtlasBytes),
            "danmaku_atlas_bytes": .unsignedInteger(danmakuAtlasBytes),
            "danmaku_vertex_bytes": .unsignedInteger(danmakuVertexBufferBytes),
            "renderer_tracked_bytes": .unsignedInteger(rendererTrackedBytes),
            "cpu_danmaku_atlas_bytes": .unsignedInteger(presenterCPUDanmakuAtlasBytes),
            "drawable_count": .unsignedInteger(UInt64(drawableCount)),
        ]
    }

    /// HUD 调试行 / 日志消息的压缩摘要。
    public var summaryLine: String {
        "视频帧 \(Self.fmt(videoFrameBytes)) · 弹幕图集 \(Self.fmt(danmakuAtlasBytes))"
            + " · 顶点 \(Self.fmt(danmakuVertexBufferBytes)) · overlay \(Self.fmt(overlayAtlasBytes))"
            + " · 内核跟踪 \(Self.fmt(rendererTrackedBytes)) · drawables \(drawableCount)"
            + " · device \(Self.fmt(deviceCurrentAllocatedBytes))"
    }

    private static func fmt(_ bytes: UInt64) -> String {
        bytes == 0 ? "0B" : String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}
