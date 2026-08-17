import XCTest
@testable import ErikaKit

/// 轨道能力（真内核）：枚举、选音轨、关字幕、外挂 srt 字幕。
final class ErikaTrackTests: XCTestCase {

    /// 无窗口驱动：内核事件靠 tick 出来，这里用手动 `audioOnlyTick` 等轨道信息。
    func testEnumerateSelectAndExternalSubtitle() async throws {
        let media = try await TestMedia.makeMovieWithTwoTones(seconds: 2)
        defer { try? FileManager.default.removeItem(at: media) }

        let engine = try ErikaEngine()
        defer { try? engine.close() }
        try engine.open(PlaybackSource(fileURL: media))
        try engine.play()

        // 1) 轨道枚举：2 音轨 + 1 视频轨
        let all = try await waitForTracks(engine) {
            $0.filter { $0.kind == .audio }.count >= 2
        }
        XCTAssertEqual(all.filter { $0.kind == .audio }.count, 2, "双音轨素材应枚举出两条音轨")
        XCTAssertEqual(all.filter { $0.kind == .video }.count, 1)
        XCTAssertTrue(all.filter { $0.kind == .audio }.contains { $0.selected },
                      "打开后应有一条默认选中的音轨")
        XCTAssertFalse(all.filter { $0.kind == .audio }.contains { $0.displayTitle.isEmpty })

        // 2) 切到未选中的那条音轨
        let other = try XCTUnwrap(all.first { $0.kind == .audio && !$0.selected })
        try engine.selectAudioTrack(other.id)

        // 3) 没有字幕轨时「关字幕」不应报错
        try engine.selectSubtitleTrack(nil)

        // 4) 外挂 srt → 轨道列表出现 external 字幕轨，可选中
        let srt = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-sub-\(UUID().uuidString).srt")
        let content = """
        1
        00:00:00,000 --> 00:00:02,000
        你好，字幕

        """
        try content.write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }

        let subtitleID = try engine.addExternalSubtitle(srt.path)
        XCTAssertGreaterThanOrEqual(subtitleID, 0)

        let afterSub = try await waitForTracks(engine) {
            $0.contains { $0.kind == .subtitle }
        }
        let subtitle = try XCTUnwrap(afterSub.first { $0.kind == .subtitle })
        XCTAssertEqual(subtitle.source, .external)
        try engine.selectSubtitleTrack(subtitle.id)

        // 5) 选中后再次「关掉」
        try engine.selectSubtitleTrack(nil)
    }

    /// 手动 tick 直到轨道条件满足（无头环境内核事件靠 tick 驱动）。
    private func waitForTracks(
        _ engine: ErikaEngine,
        _ condition: ([TrackInfo]) -> Bool,
        timeout: TimeInterval = 8
    ) async throws -> [TrackInfo] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [TrackInfo] = []
        while Date() < deadline {
            last = try engine.tracks()
            if condition(last) { return last }
            _ = try? engine.audioOnlyTick()
            try await Task.sleep(for: .milliseconds(60))
        }
        return last
    }
}
