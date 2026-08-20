import CErika
import Foundation
import Testing
@testable import ErikaKit

/// M0 第 5 步的无头验收：不开窗口也能证明内核真的把文件 demux 开了 ——
/// 打开一个现造的 1 秒 mp4，轮询事件，看到时长和视频轨。
@Suite("Erika 打开真文件")
struct ErikaOpenFileTests {

    @Test("打开本地 mp4：能拿到时长与视频轨事件")
    func openLocalFile() async throws {
        let movie = try TestMedia.makeShortMovie()
        defer { try? FileManager.default.removeItem(at: movie) }

        let presenter = try ErikaPresenter()
        try presenter.open(PlaybackSource(fileURL: movie))

        var duration: Duration?
        var videoTracks = 0
        var states: [PlaybackState] = []

        // 最多等 5 秒：open 是异步的，事件靠轮询取。没有画面时用 audio_only_tick 推进。
        for _ in 0..<250 {
            _ = try? presenter.audioOnlyTick()
            while let event = try presenter.pollEvent() {
                switch event {
                case .durationChanged(let value): duration = value
                case .tracksChanged(let counts): videoTracks = max(videoTracks, counts.video)
                case .stateChanged(let value): states.append(value)
                default: break
                }
            }
            if duration != nil, videoTracks > 0, states.contains(where: { $0 != .opening }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(videoTracks >= 1, "应该识别出至少一条视频轨")
        let seconds = (duration?.microseconds ?? 0) / 1_000_000
        #expect(seconds >= 1 && seconds <= 2, "1 秒素材的时长应在 1–2 秒内，实际 \(seconds)s")
        #expect(states.contains(.ready) || states.contains(.playing) || states.contains(.paused),
                "应至少进入过 Ready，实际 \(states)")

        try presenter.close()
    }

    @Test("没有 surface 时 render_tick 不应把进程带崩")
    func renderTickWithoutSurface() throws {
        let presenter = try ErikaPresenter()
        // 没挂 surface，内核要么忽略要么报错，但绝不能崩。
        _ = try? presenter.renderTick(at: 0.016)
        _ = try? presenter.pollEvent()
    }

    @Test("Duration 到微秒的换算是截断而不是四舍五入")
    func durationConversion() {
        #expect(Duration.milliseconds(1500).microseconds == 1_500_000)
        #expect(Duration.microseconds(1).microseconds == 1)
        #expect((Duration.microseconds(1) / 2).microseconds == 0)
    }
}
