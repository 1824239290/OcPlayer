import CErika
import CoreMedia
import Foundation
import IOSurface
import Metal
import QuartzCore
import Testing
import PlaybackKit
@testable import ErikaKit

/// 画中画喂帧通路（Flutter texture 档）的分层验收：
/// ① `FrameSurfacePool` 的轮转 / 持有中不复用语义；
/// ② `ErikaPresenter` 的 attach_flutter_texture + set_flutter_texture_buffer +
///    render_tick 在真实内核上出帧（iOS PiP 的内核侧前提，等价 spike S2 的自动化版）；
/// ③ `ErikaEngine` 三态档位：begin/endTextureRendering 真的把帧从回调里送出来。
@Suite("Erika 纹理通路（画中画档）", .serialized)
struct ErikaTextureRenderingTests {

    // MARK: - FrameSurfacePool

    @Test("池：全空闲时轮转可用，持有中不复用，释放后回来")
    func poolRespectsInUseSurfaces() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CocoaError(.featureUnsupported)
        }
        let pool = try FrameSurfacePool(pixelWidth: 320, pixelHeight: 180, device: device)

        // 全空闲：连取 8 次（两圈）都成功。
        var seen = Set<IOSurface>()
        for _ in 0..<8 {
            let slot = pool.acquire()
            #expect(slot != nil, "全空闲时 acquire 不该失败")
            seen.insert(slot!.surface)
        }
        #expect(seen.count == 4, "轮转应该覆盖全部 4 个槽位，实际 \(seen.count)")

        // 模拟显示层持有（enqueue 后 sample buffer 攥着 pixelBuffer）：
        // 全部槽位在飞时 acquire 返回 nil（丢拍，优于覆写还在显示的画面）。
        var held: [FrameSurfacePool.Slot] = []
        for _ in 0..<4 {
            let slot = pool.acquire()
            #expect(slot != nil)
            IOSurfaceIncrementUseCount(slot!.surface)
            held.append(slot!)
        }
        #expect(pool.acquire() == nil, "4 槽全部入队未消费时应当丢拍")

        // 归还一个后恢复。
        IOSurfaceDecrementUseCount(held.removeLast().surface)
        #expect(pool.acquire() != nil, "释放一帧后应该能重新拿到槽位")
        held.forEach { IOSurfaceDecrementUseCount($0.surface) }
    }

    @Test("槽位：sample buffer 封装成功且尺寸吻合")
    func slotMakesSampleBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CocoaError(.featureUnsupported)
        }
        let pool = try FrameSurfacePool(pixelWidth: 320, pixelHeight: 180, device: device)
        let slot = pool.acquire()!
        let sample = try slot.makeSampleBuffer(
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 6_000_000)
        )
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        let image = CMSampleBufferGetImageBuffer(sample)!
        #expect(CVPixelBufferGetWidth(image) == 320)
        #expect(CVPixelBufferGetHeight(image) == 180)
    }

    // MARK: - Presenter 级：内核真的能渲染进宿主纹理

    /// 离屏 metal layer 播放中途换到纹理通路再切回来：PiP 进出的内核侧路径。
    /// 素材是逐帧变亮的灰底，最后从纹理里读像素证明写进去的是**真画面**而不是空纹理。
    @Test("播放中切纹理通路：出帧、PTS 单调、画面非黑、切回 layer 不报错")
    func presenterRendersIntoHostTextureMidPlayback() async throws {
        let movie = try await TestMedia.makeMovieWithTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: movie) }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CocoaError(.featureUnsupported)
        }

        let presenter = try ErikaPresenter()
        // 起播：先走 metal layer（前台常态）。
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 640, height: 360)
        try presenter.attachMetalLayer(
            UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())),
            pixelWidth: 640, pixelHeight: 360, scale: 1
        )
        try presenter.open(PlaybackSource(fileURL: movie))

        var ready = false
        var failure: String?
        func note(_ event: PlayerEvent) {
            switch event {
            case .stateChanged(let state) where state != .opening && state != .idle: ready = true
            case .failed(_, let message): failure = message ?? "unknown"
            default: break
            }
        }
        for _ in 0..<120 {
            _ = try presenter.renderTick(at: CACurrentMediaTime() + 1.0 / 60)
            while let event = try presenter.pollEvent() { note(event) }
            if ready { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(ready, "应进入 Ready")
        try presenter.play()
        for _ in 0..<30 {
            _ = try presenter.renderTick(at: CACurrentMediaTime() + 1.0 / 60)
            while let event = try presenter.pollEvent() { note(event) }
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(failure == nil, "起播阶段不该报错：\(failure ?? "")")

        // 进 PiP 等价的通路：detach layer → attach flutter texture。
        try presenter.detachSurface()
        try presenter.attachFlutterTexture(pixelWidth: 320, pixelHeight: 180, scale: 1)

        let pool = try FrameSurfacePool(pixelWidth: 320, pixelHeight: 180, device: device)
        var lastPTS = CMTime.negativeInfinity
        var delivered = 0
        var renderedBefore: UInt64 = 0
        var firstStats = ErikaPresenterStats()
        // 纹理档打 ~1 秒：每拍先选纹理再 tick（内核契约），新帧封装成 sample buffer。
        for _ in 0..<60 {
            guard let slot = pool.acquire() else {
                try await Task.sleep(for: .milliseconds(16))
                continue
            }
            try presenter.setFlutterTextureBuffer(slot.texture)
            let stats = try presenter.renderTick(at: CACurrentMediaTime() + 0.1)
            firstStats = stats
            if delivered == 0 { renderedBefore = 0 }  // 首拍建立基线
            if stats.rendered_video_frames > renderedBefore {
                renderedBefore = stats.rendered_video_frames
                let pts = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 6_000_000)
                #expect(pts > lastPTS, "PTS 必须单调递增")
                lastPTS = pts
                _ = try slot.makeSampleBuffer(presentationTimeStamp: pts)
                delivered += 1
            }
            while let event = try presenter.pollEvent() { note(event) }
            try await Task.sleep(for: .milliseconds(16))
        }

        #expect(failure == nil, "纹理档不该报错：\(failure ?? "")")
        #expect(firstStats.render_failures == 0,
                "渲染进宿主纹理不该失败：\(firstStats.render_failures)")
        #expect(delivered > 0, "纹理档应该渲染出过新帧（delivered=\(delivered)）")

        // 画面是真的：从最后一帧纹理读像素（素材逐帧变亮，非全黑即真画面）。
        if delivered > 0, let slot = pool.acquire() {
            try presenter.setFlutterTextureBuffer(slot.texture)
            _ = try presenter.renderTick(at: CACurrentMediaTime() + 0.1)
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 320 * 180 * 4, alignment: 64)
            defer { bytes.deallocate() }
            slot.texture.getBytes(
                bytes, bytesPerRow: 320 * 4,
                from: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0
            )
            let luma = (0..<(320 * 180 * 4)).filter { $0 % 4 != 3 }.map { bytes.load(fromByteOffset: $0, as: UInt8.self) }
            #expect((luma.max() ?? 0) > 0, "宿主纹理里不该是全黑")
        }

        // 出 PiP 等价：detach 纹理 → 挂回 layer，tick 恢复。
        try presenter.detachSurface()
        try presenter.attachMetalLayer(
            UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())),
            pixelWidth: 640, pixelHeight: 360, scale: 1
        )
        let stats = try presenter.renderTick(at: CACurrentMediaTime() + 1.0 / 60)
        #expect(stats.render_failures == 0, "切回 metal layer 后渲染不该失败")

        try presenter.stop()
        try presenter.detachSurface()
        try presenter.close()
    }

    // MARK: - Engine 级：三态档位

    /// 不挂视图（PiP 期间 App 的视图不在窗口层级里也成立）：open → play →
    /// beginTextureRendering，帧回调应该真的到来（engine 档位 + pool + 内核整链）。
    @Test("engine：纹理档端到端，帧回调到来、退出后幂等")
    func engineTextureModeDeliversFrames() async throws {
        let movie = try await TestMedia.makeMovieWithTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: movie) }

        let engine = try ErikaEngine()
        try engine.open(PlaybackSource(fileURL: movie))
        try engine.play()

        let counter = FrameCounter()
        let entered = engine.beginTextureRendering(pixelWidth: 320, pixelHeight: 180) { _, _ in
            counter.mark()
        }
        #expect(entered, "进纹理档应该成功（open 不在飞、设备可用）")

        // 等 ~1.5s：60Hz 的定时器 + 2 秒素材，帧回调必然发生。
        var waited = 0
        while counter.value == 0 && waited < 1_500 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        #expect(counter.value > 0, "纹理档应该有帧回调（等待 \(waited)ms）")

        engine.endTextureRendering()
        let baseline = counter.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.value == baseline, "退出纹理档后不该再回调")

        // 幂等：重复退出不炸。
        engine.endTextureRendering()
        try engine.stop()
    }
}

/// 跨线程收集帧回调计数（回调来自引擎的定时器队列）。
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func mark() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
