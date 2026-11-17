import XCTest
import PlaybackKit
@testable import ErikaKit

/// 轨道能力（真内核）：枚举、选音轨、关字幕、外挂 srt 字幕。
final class ErikaTrackTests: XCTestCase {

    func testPopulatedTrackCountIsBoundedByAllocatedCapacity() {
        XCTAssertEqual(TrackInfo.populatedCount(5, capacity: 2), 2)
        XCTAssertEqual(TrackInfo.populatedCount(2, capacity: 5), 2)
    }

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

        // 4b) 选轨后 `tracks()` 必须把这条报成 selected。
        //
        // 这不是内核自娱自乐的细节：App 层的自动选字幕（`SubtitleTrackSelector`）
        // 靠「当前 selected 就是最优解 → keep」收口，内核若迟迟不更新 selected，
        // 每次 `trackSelectionChanged` 刷新都会再下发一次同样的选轨，形成抖动。
        let selectedAfter = try await waitForTracks(engine) {
            $0.contains { $0.kind == .subtitle && $0.id == subtitle.id && $0.selected }
        }
        XCTAssertTrue(
            selectedAfter.contains { $0.kind == .subtitle && $0.id == subtitle.id && $0.selected },
            "选中的外挂字幕轨应在 tracks() 里报 selected，否则宿主侧判定无法收敛"
        )

        // 5) 选中后再次「关掉」
        try engine.selectSubtitleTrack(nil)
        let closed = try await waitForTracks(engine) {
            !$0.contains { $0.kind == .subtitle && $0.selected }
        }
        XCTAssertFalse(
            closed.contains { $0.kind == .subtitle && $0.selected },
            "关字幕后不该还有字幕轨报 selected"
        )
    }

    /// 外挂字幕轨可移除，内嵌轨不可。
    ///
    /// `canRemove` 是 App 侧「删除」入口的**唯一闸门**（内嵌轨不给删除项），所以两半
    /// 都要钉住：①外挂轨报 true 且真的删得掉；②内嵌轨报 false。
    /// `TestMedia` 造不出内嵌字幕轨，用同素材的**内嵌视频/音轨**覆盖同一段映射
    /// （`can_remove` 的判定在内核里是按轨来源给的，与轨类型无关）。
    func testRemoveExternalSubtitleTrack() async throws {
        let media = try await TestMedia.makeMovieWithTwoTones(seconds: 2)
        defer { try? FileManager.default.removeItem(at: media) }

        let engine = try ErikaEngine()
        defer { try? engine.close() }
        try engine.open(PlaybackSource(fileURL: media))
        try engine.play()

        let initial = try await waitForTracks(engine) { !$0.isEmpty }
        // 内嵌轨一律不可移除：UI 若照 source 猜而不是读内核，这里会先炸。
        let embedded = initial.filter { $0.source == .embedded }
        XCTAssertFalse(embedded.isEmpty, "前提：素材应含内嵌轨")
        XCTAssertFalse(
            embedded.contains { $0.canRemove },
            "内嵌轨不该报 canRemove——App 的删除入口就是按它显隐的"
        )

        let srt = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-sub-remove-\(UUID().uuidString).srt")
        let srtContent = """
        1
        00:00:00,000 --> 00:00:02,000
        待删除的字幕

        """
        try srtContent.write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }

        let subtitleID = try engine.addExternalSubtitle(srt.path)
        let withSub = try await waitForTracks(engine) {
            $0.contains { $0.id == subtitleID }
        }
        let external = try XCTUnwrap(withSub.first { $0.id == subtitleID })
        XCTAssertTrue(external.canRemove, "外挂字幕轨应报 canRemove")
        try engine.selectSubtitleTrack(subtitleID)
        _ = try await waitForTracks(engine) { $0.contains { $0.id == subtitleID && $0.selected } }

        // 删掉当前选中的这条：内核轨道列表里应彻底消失。
        try engine.removeSubtitleTrack(subtitleID)
        let removed = try await waitForTracks(engine) {
            !$0.contains { $0.id == subtitleID }
        }
        XCTAssertFalse(
            removed.contains { $0.id == subtitleID },
            "移除后的外挂字幕轨不该再出现在 tracks() 里"
        )
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
