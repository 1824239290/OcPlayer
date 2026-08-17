import CErika
import CoreMedia
import Foundation
import Metal
import QuartzCore
import Testing
@testable import ErikaKit

/// M0 第 5 步的无头验收：挂一个**离屏** CAMetalLayer，自己手动打 render_tick，
/// 证明内核真的在解码 → 上屏 → 推音频，并且 pause / seek / 倍速 / resize 连打不出错。
/// CAMetalLayer 不进窗口层级也能拿 drawable，所以这一切不需要开窗口。
@Suite("Erika 离屏渲染", .serialized)
struct ErikaRenderTests {

    /// 造一个能直接交给内核的离屏 CAMetalLayer。
    private static func makeLayer(width: Int, height: Int) throws -> CAMetalLayer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CocoaError(.featureUnsupported)
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false          // 允许内核回读，capture_frame 才稳
        layer.isOpaque = true
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.drawableSize = CGSize(width: width, height: height)
        return layer
    }

    private static func attach(_ presenter: ErikaPresenter, _ layer: CAMetalLayer,
                               width: Int, height: Int) throws {
        let raw = UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        try presenter.attachMetalLayer(raw, pixelWidth: width, pixelHeight: height, scale: 1)
    }

    /// 打 tick 并抽干事件，最多 `frames` 帧；`stop` 返回 true 就提前结束。
    @discardableResult
    private static func pump(_ presenter: ErikaPresenter, frames: Int,
                            collect: (PlayerEvent) -> Void = { _ in },
                            stop: () -> Bool = { false }) throws -> ErikaPresenterStats {
        var stats = ErikaPresenterStats()
        for _ in 0..<frames {
            // 显示链会给「这一帧的绝对呈现时间」，离屏就用当前时间 + 一帧。
            stats = try presenter.renderTick(at: CACurrentMediaTime() + 1.0 / 60)
            while let event = try presenter.pollEvent() { collect(event) }
            if stop() { break }
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        return stats
    }

    @Test("有画面有声音：rendered / pushed_audio 都在涨，硬解生效")
    func rendersPictureAndPushesAudio() async throws {
        let movie = try await TestMedia.makeMovieWithTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: movie) }

        let presenter = try ErikaPresenter()
        let layer = try Self.makeLayer(width: 640, height: 360)
        try Self.attach(presenter, layer, width: 640, height: 360)

        try presenter.open(PlaybackSource(fileURL: movie))

        var tracks = TrackCounts(video: 0, audio: 0, subtitle: 0)
        var duration: Duration?
        var failure: String?
        var decoderSwitched = false

        // 等 open 落地（最多 ~2 秒）。
        try Self.pump(presenter, frames: 120, collect: { event in
            switch event {
            case .tracksChanged(let counts): tracks = counts
            case .durationChanged(let value): duration = value
            case .videoDecoderChanged: decoderSwitched = true
            case .failed(_, let message): failure = message ?? "unknown"
            default: break
            }
        }, stop: { duration != nil && tracks.video > 0 && tracks.audio > 0 })

        #expect(failure == nil, "open 阶段不该报错：\(failure ?? "")")
        #expect(tracks.video == 1, "应有 1 条视频轨，实际 \(tracks.video)")
        #expect(tracks.audio == 1, "应有 1 条音轨，实际 \(tracks.audio)")

        try presenter.play()

        var position = Duration.zero
        // 播 ~1.5 秒（90 帧 @60Hz）。
        let stats = try Self.pump(presenter, frames: 90, collect: { event in
            switch event {
            case .positionChanged(let value): position = value
            case .videoDecoderChanged: decoderSwitched = true
            case .failed(_, let message): failure = message ?? "unknown"
            default: break
            }
        })

        #expect(failure == nil, "播放中不该报错：\(failure ?? "")")
        #expect(stats.decoded_video_frames > 0, "应解出视频帧")
        #expect(stats.rendered_video_frames > 0,
                "应真的上屏过（rendered=\(stats.rendered_video_frames)）")
        #expect(stats.pushed_audio_frames > 0,
                "应真的推过音频（pushed=\(stats.pushed_audio_frames)）")
        #expect(stats.render_failures == 0, "渲染不该有失败：\(stats.render_failures)")
        #expect(stats.audio_failures == 0, "音频不该有失败：\(stats.audio_failures)")
        #expect(stats.hardware_video_frames > 0,
                "macOS 上应该走 VideoToolbox 硬解（decoder_changed=\(decoderSwitched)）")
        #expect(position.microseconds > 0, "位置应该往前走，实际 \(position.microseconds)µs")

        // 画面到底是不是真画面：截一张，素材是逐帧变亮的灰底，所以像素应非全黑且三通道接近。
        let pixels = try presenter.captureFrameRGBA(width: 64, height: 36)
        let luma = pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }
        let brightest = luma.max() ?? 0
        #expect(brightest > 0, "截帧不该是全黑")

        try presenter.detachSurface()
        try presenter.close()
    }

    @Test("pause / seek / 倍速 / resize 连打不炸")
    func controlsAreStable() async throws {
        let movie = try await TestMedia.makeMovieWithTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: movie) }

        let presenter = try ErikaPresenter()
        let layer = try Self.makeLayer(width: 480, height: 270)
        try Self.attach(presenter, layer, width: 480, height: 270)
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

        try Self.pump(presenter, frames: 120, collect: note, stop: { ready })
        #expect(ready, "应至少进入过 Ready")

        try presenter.play()
        try Self.pump(presenter, frames: 20, collect: note)

        try presenter.pause()
        try Self.pump(presenter, frames: 10, collect: note)

        try presenter.seek(to: .milliseconds(1_000))
        try Self.pump(presenter, frames: 20, collect: note)

        try presenter.setRate(2.0)
        try presenter.setVolume(0.3)
        try presenter.play()
        try Self.pump(presenter, frames: 20, collect: note)

        // 窗口 resize：内核要求下一次 tick 之前先 resize_surface。
        layer.drawableSize = CGSize(width: 800, height: 450)
        try presenter.resizeSurface(pixelWidth: 800, pixelHeight: 450, scale: 1)
        let stats = try Self.pump(presenter, frames: 30, collect: note)

        #expect(failure == nil, "连打控制不该报错：\(failure ?? "")")
        #expect(stats.render_failures == 0, "resize 后渲染不该失败：\(stats.render_failures)")
        #expect(stats.import_failures == 0, "帧导入不该失败：\(stats.import_failures)")

        try presenter.stop()
        try presenter.detachSurface()
        try presenter.close()
    }
}
