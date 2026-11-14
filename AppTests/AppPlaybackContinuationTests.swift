import CoreModel
import OcPlayerCore
@testable import JellyfinKit
@testable import OcPlayer
import XCTest

@MainActor
final class AppPlaybackContinuationTests: XCTestCase {
    private func current(_ id: String = "current") -> MediaItem {
        var item = MediaItem(id: id, name: "原生剧集", kind: .episode)
        item.seriesID = "series"; item.seasonNumber = 1; item.episodeNumber = 2
        return item
    }
    private func app(_ server: StubMediaServer) -> AppModel {
        let app = AppModel(); app.phase = .ready; app.server = server; app.sessionGeneration = 1
        return app
    }
    private func identity(_ id: String) -> AppModel.ActivePlaybackIdentity {
        .init(sessionGeneration: 1, itemID: id, requestID: UUID())
    }
    func testRecoveryDecisionMatrixPreservesOriginalRetryAndRebuildRules() {
        for mode in ["manual", "background"] {
            for flags in 0..<32 {
                let loading = flags & 1 != 0, playback = flags & 2 != 0, request = flags & 4 != 0
                let item = flags & 8 != 0, loaded = flags & 16 != 0
                for current in [nil, 0, 1.25, 29.999999, 30, 120.5] as [Double?] {
                    for fallback in [nil, 80.5] as [Double?] {
                        let result = AppModel.recoveryPlan(mode: mode, loading: loading, hasPlayback: playback,
                            hasRequest: request, hasMediaItem: item, hasLoadedSource: loaded,
                            currentPositionSeconds: current, requestResumeSeconds: fallback)
                        let action: AppModel.RecoveryPlan.Action
                        let resume: Double?
                        if mode == "manual" {
                            action = loading ? .none : item ? .reprepare : .retryLast
                            resume = action == .reprepare ? (current.flatMap { $0 >= 30 ? $0 : nil } ?? fallback) : nil
                        } else {
                            action = playback && request ? (item ? .reprepare : .reopen) : .none
                            resume = action == .none ? nil : loaded ? current : fallback
                        }
                        XCTAssertEqual(result.action, action); XCTAssertEqual(result.resumeSeconds, resume)
                    }
                }
            }
        }
    }
    func testAppContinuationCommitsCompleteNextItemForActiveIdentity() async throws {
        let server = StubMediaServer(), current = current(), app = app(server)
        var special = current; special.id = "special"; special.seasonNumber = 0
        var next = current; next.id = "next"; next.seasonNumber = .max; next.overview = "完整元数据"
        next.playState = .init(played: true, percentage: 1, positionSeconds: 80.5)
        server.episodeWindowHandler = { series, after, limit in
            XCTAssertEqual(series, "series"); XCTAssertEqual(after, "current"); XCTAssertEqual(limit, 6)
            return [current, special, next]
        }
        let identity = identity(current.id); app.activePlaybackIdentity = identity
        app.resolveNextEpisode(after: current, identity: identity)
        await app.nextEpisodeTask?.value
        XCTAssertEqual(app.nextEpisode?.id, "next"); XCTAssertEqual(app.nextEpisode?.overview, "完整元数据")
        XCTAssertEqual(app.nextEpisode?.seasonNumber, .max); XCTAssertEqual(app.nextEpisode?.playState?.positionSeconds, 80.5)
        app.clearPlaybackSessionState()
    }
    func testLateContinuationCannotReplaceNewPlaybackNextItem() async throws {
        let server = StubMediaServer(), app = app(server), old = current("old"), new = current("new")
        var pending: CheckedContinuation<[MediaItem], Never>?
        server.episodeWindowHandler = { _, _, _ in await withCheckedContinuation { pending = $0 } }
        let oldIdentity = identity(old.id); app.activePlaybackIdentity = oldIdentity
        app.resolveNextEpisode(after: old, identity: oldIdentity)
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try XCTUnwrap(pending), oldTask = try XCTUnwrap(app.nextEpisodeTask)
        var newNext = new; newNext.id = "new-next"
        server.episodeWindowHandler = { _, _, _ in [new, newNext] }
        let newIdentity = identity(new.id); app.activePlaybackIdentity = newIdentity
        app.resolveNextEpisode(after: new, identity: newIdentity); await app.nextEpisodeTask?.value
        XCTAssertEqual(app.nextEpisode?.id, "new-next")
        var oldNext = old; oldNext.id = "late-old-next"
        continuation.resume(returning: [old, oldNext]); await oldTask.value
        XCTAssertEqual(app.nextEpisode?.id, "new-next"); app.clearPlaybackSessionState()
    }
    func testManualRetryDoesNotReenterLoadingPreparation() {
        let server = StubMediaServer(), app = app(server)
        app.nowPlayingItem = current(); app.playbackPreparation = .loading(title: "现有加载")
        let generation = app.playbackOpenGeneration
        app.retryPlayback()
        XCTAssertEqual(app.playbackOpenGeneration, generation); XCTAssertNil(app.playbackOpenTask)
        app.cancelPlaybackOpen()
    }
    func testManualRetryStartsFreshPlaybackInfoAndSessionWithOriginalResume() async throws {
        let server = StubMediaServer(), app = app(server), current = current()
        var calls = 0
        let source = PlaybackMediaSource(id: "fresh-source", name: "新源", path: "/原盘/片.mkv", size: .max,
            container: "mkv", supportsDirectPlay: true, supportsDirectStream: true, supportsTranscoding: nil,
            bitrate: nil, runTimeSeconds: 7200.25, videoRangeType: "HDR10")
        server.playbackInfoHandler = { id in
            XCTAssertEqual(id, current.id); calls += 1
            return PlaybackInfo(playSessionID: "fresh-session", mediaSources: [source])
        }
        let old = PlaybackRequest(title: "旧请求", uri: "http://old/stream", authHeader: "old-auth", resumeSeconds: 80.5)
        app.nowPlayingItem = current; app.presentedPlayer = old
        app.retryPlayback(); await app.playbackOpenTask?.value
        XCTAssertEqual(calls, 1); XCTAssertNotEqual(app.presentedPlayer?.id, old.id)
        XCTAssertEqual(app.presentedPlayer?.resumeSeconds, 80.5)
        XCTAssertEqual(app.presentedPlayer?.sessionContext?.playSessionID, "fresh-session")
        XCTAssertEqual(app.presentedPlayer?.sessionContext?.mediaSourceID, "fresh-source")
        XCTAssertEqual(app.presentedPlayer?.sessionContext?.mediaSourceSize, .max)
        app.cancelPlaybackOpen(); app.clearPlaybackSessionState(); await app.finishReporting()?.value
    }
}
