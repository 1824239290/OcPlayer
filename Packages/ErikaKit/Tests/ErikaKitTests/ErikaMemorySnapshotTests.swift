import CErika
import Testing
@testable import ErikaKit

/// 内核内存采样（`erika_presenter_get_resource_status`）的映射与可达性。
@Suite("Erika 内核内存快照")
struct ErikaMemorySnapshotTests {

    @Test("C 结构字段原样映射到 Swift 镜像")
    func mapsCFields() throws {
        var raw = ErikaPresenterResourceStatus()
        raw.device_current_allocated_bytes = 1_000_000
        raw.device_recommended_working_set_bytes = 2_000_000
        raw.drawable_estimated_bytes = 3_000_000
        raw.video_frame_bytes = 4_000_000
        raw.overlay_atlas_bytes = 5_000_000
        raw.danmaku_atlas_bytes = 6_000_000
        raw.danmaku_vertex_buffer_bytes = 7_000_000
        raw.upscaler_bytes = 8_000_000
        raw.renderer_tracked_bytes = 9_000_000
        raw.presenter_cpu_danmaku_atlas_bytes = 10_000_000
        raw.drawable_count = 3
        raw.output_mode_switches = 4

        let snapshot = ErikaMemorySnapshot(raw)
        #expect(snapshot.deviceCurrentAllocatedBytes == 1_000_000)
        #expect(snapshot.deviceRecommendedWorkingSetBytes == 2_000_000)
        #expect(snapshot.drawableEstimatedBytes == 3_000_000)
        #expect(snapshot.videoFrameBytes == 4_000_000)
        #expect(snapshot.overlayAtlasBytes == 5_000_000)
        #expect(snapshot.danmakuAtlasBytes == 6_000_000)
        #expect(snapshot.danmakuVertexBufferBytes == 7_000_000)
        #expect(snapshot.upscalerBytes == 8_000_000)
        #expect(snapshot.rendererTrackedBytes == 9_000_000)
        #expect(snapshot.presenterCPUDanmakuAtlasBytes == 10_000_000)
        #expect(snapshot.drawableCount == 3)
        #expect(snapshot.outputModeSwitches == 4)
    }

    @Test("空初始快照全零")
    func emptySnapshotIsZero() {
        let snapshot = ErikaMemorySnapshot()
        #expect(snapshot.drawableCount == 0)
        #expect(snapshot.rendererTrackedBytes == 0)
        #expect(snapshot.summaryLine.contains("drawables 0"))
    }

    @Test("空闲 presenter 可读资源状态且不抛错")
    func resourceStatusOnIdle() throws {
        let presenter = try ErikaPresenter()
        let raw = try presenter.resourceStatus()  // 不崩、不抛即可；空闲时各分项允许为 0
        _ = raw
    }

    @Test("进程内存读数可达且物理内存非零")
    func processFootprintIsReadable() {
        let fp = ProcessFootprint.current()
        #expect(fp.maxRSSBytes > 0)          // 进程跑起来必然有过 RSS
        #expect(fp.physFootprintBytes > 0)   // 当前必然占着物理内存
        #expect(fp.summaryLine.contains("进程 "))
    }
}
