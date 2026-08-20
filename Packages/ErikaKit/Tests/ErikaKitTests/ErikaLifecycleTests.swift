import CErika
import Foundation
import Testing
@testable import ErikaKit

/// 播放生命周期回归（REVIEW_TODO 1.3）。
/// 内核 `close()` 是终态——同一 presenter `close()` 后再 `open()` 必抛 PlayerError；
/// `stop()` 不是。App 层退出播放与换片都走「stop + 丢弃重建」策略（PlaybackController），
/// 这里锁定内核侧契约，防止将来有人改回 `close() → open()`。
@Suite("Erika 播放生命周期")
struct ErikaLifecycleTests {

    /// 打开源并等它落地（duration 到达 + ready）。无窗口：用 audio_only_tick 推进事件。
    /// `open` 抛错会直接向上抛 → 测试失败；等不到就 record 一条。
    private static func openUntilReady(_ presenter: ErikaPresenter, _ url: URL) throws {
        try presenter.open(PlaybackSource(fileURL: url))
        var duration: Duration?
        var states: [PlaybackState] = []
        for _ in 0..<250 {
            _ = try? presenter.audioOnlyTick()
            while let event = try presenter.pollEvent() {
                switch event {
                case .durationChanged(let value): duration = value
                case .stateChanged(let value): states.append(value)
                default: break
                }
            }
            if duration != nil, states.contains(.ready) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Issue.record("open 后 5 秒内没等到 ready + duration（states=\(states)）")
    }

    @Test("open → stop → open 同一个源：stop 后可再 open（退出播放每天在走的路）")
    func reopenAfterStopSameSource() throws {
        let movie = try TestMedia.makeShortMovie()
        defer { try? FileManager.default.removeItem(at: movie) }

        let presenter = try ErikaPresenter()
        try Self.openUntilReady(presenter, movie)
        try presenter.stop()
        try Self.openUntilReady(presenter, movie)
    }

    @Test("open → stop → open 不同源：换源也能再 open")
    func reopenAfterStopDifferentSource() throws {
        let first = try TestMedia.makeShortMovie()
        let second = try TestMedia.makeShortMovie()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let presenter = try ErikaPresenter()
        try Self.openUntilReady(presenter, first)
        try presenter.stop()
        try Self.openUntilReady(presenter, second)
    }

    @Test("open → close → open：close 是终态，再 open 必抛 PlayerError（回归锁定）")
    func cannotReopenAfterClose() throws {
        let movie = try TestMedia.makeShortMovie()
        defer { try? FileManager.default.removeItem(at: movie) }

        let presenter = try ErikaPresenter()
        try Self.openUntilReady(presenter, movie)
        try presenter.close()
        do {
            try presenter.open(PlaybackSource(fileURL: movie))
            Issue.record("close 后 open 应该抛 ErikaError，实际成功")
        } catch let error as ErikaError {
            #expect(error.status == ErikaStatus_PlayerError,
                    "应是 PlayerError(status=3)，实际 \(error)")
        }
    }

    @Test("连播换片策略：旧 presenter stop 后丢弃重建，新 presenter 开下一集可播")
    func nextEpisodeReusesFreshPresenter() throws {
        let episodeA = try TestMedia.makeShortMovie()
        let episodeB = try TestMedia.makeShortMovie()
        defer {
            try? FileManager.default.removeItem(at: episodeA)
            try? FileManager.default.removeItem(at: episodeB)
        }

        // App 层换片（1.1 修复后）：stop 旧引擎 → resetEngine 丢弃 → 新建引擎开新源。
        var presenter = try ErikaPresenter()
        try Self.openUntilReady(presenter, episodeA)
        try presenter.play()

        presenter = try ErikaPresenter()   // 旧 presenter 丢弃（离开作用域销毁）
        try Self.openUntilReady(presenter, episodeB)
        try presenter.play()
        for _ in 0..<10 { _ = try? presenter.audioOnlyTick() }   // 换片后推进几帧不炸
        try presenter.stop()
    }
}
