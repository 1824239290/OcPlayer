import CoreModel
import Foundation
import OcPlayerCore
import XCTest
@testable import JellyfinKit

@MainActor
final class PlaybackPreparationWorkflowTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }
    private struct Failure: Error, CustomStringConvertible { let name: String; var description: String { name } }
    private func source(_ id: String, play: Bool = false) -> PlaybackMediaSource {
        .init(id: id, name: "版本 \(id)", path: "/原盘/\(id).mkv", size: .max, container: "mkv",
            supportsDirectPlay: play, supportsDirectStream: true, supportsTranscoding: nil,
            bitrate: .max, runTimeSeconds: 7200.25, videoRangeType: "DOVIWithHDR10")
    }
    private func item() -> MediaItem {
        var item = MediaItem(id: "episode", name: "本集", kind: .episode)
        item.seriesID = "series"; item.seriesName = "原生剧名"; item.seasonNumber = .max; item.episodeNumber = .max
        item.playState = .init(played: false, percentage: 0.01, positionSeconds: 1.25)
        item.runtimeSeconds = 7200.5; item.overview = "完整简介"; item.genres = ["原始字段"]
        item.originalTitle = "原題"; item.primaryImageTag = "tag"; item.year = 2024
        return item
    }
    private func prepare(_ item: MediaItem, server: PreparationFixtureServer,
                         home: PlaybackPreparationWorkflow.HomeProvider = { ([], []) },
                         client: OcpCoreClient? = nil) async throws -> (PlaybackPreparationWorkflow.Outcome, PreparedPlayback?) {
        var prepared: PreparedPlayback?
        let outcome = try await PlaybackPreparationWorkflow.prepare(item: item, resumeSeconds: 8.75,
            server: server, home: home, coreClient: client, onResolved: { _ in }, onFallback: { _, _ in }, onReady: { prepared = $0 })
        return (outcome, prepared)
    }
    func testCompleteSourceSequencePreservesNativeObjectsAndSkipsOnlyFailedAlternate() async throws {
        let server = PreparationFixtureServer(), calls = Calls(), original = item()
        let info = PlaybackInfo(playSessionID: "会话", mediaSources: [source("a"), source("b", play: true), source("b"), source("c")])
        server.playbackInfoHandler = { id in calls.add("info:\(id)"); return info }
        server.streamHandler = { id, source, session in
            calls.add("url:\(id):\(source ?? "nil"):\(session ?? "nil")")
            if source == "a" { throw Failure(name: "坏备用源") }
            return "https://fixture/\(source ?? "nil")?session=\(session ?? "nil")"
        }
        let (_, result) = try await prepare(original, server: server)
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(prepared.item, original); XCTAssertEqual(prepared.resumeSeconds, 8.75)
        XCTAssertEqual(prepared.title, "原生剧名 S9223372036854775807E9223372036854775807")
        XCTAssertEqual(prepared.context, info.sessionContext(itemID: original.id, selectedSource: info.mediaSources[1]))
        XCTAssertEqual(prepared.context.mediaSourceSize, .max); XCTAssertEqual(prepared.context.videoRangeType, "DOVIWithHDR10")
        XCTAssertEqual(prepared.alternates.map(\.id), ["c"])
        XCTAssertEqual(prepared.alternates.first?.context, info.sessionContext(itemID: original.id, selectedSource: info.mediaSources[3]))
        XCTAssertEqual(calls.all, ["info:episode", "url:episode:b:会话", "url:episode:a:会话", "url:episode:c:会话"])
        XCTAssertEqual(prepared.authHeader, server.authorizationHeader)
    }
    func testCollectionReadsCurrentHomeAfterMembersAndUsesResolvedItemResume() async throws {
        let server = PreparationFixtureServer(); var next: [MediaItem] = []
        let episode = item()
        server.membersHandler = { next = [episode]; return .init(items: [.init(id: "series", name: "剧", kind: .series)], startIndex: 0, totalRecordCount: 1) }
        let (_, result) = try await prepare(.init(id: "box", name: "合集", kind: .boxSet), server: server, home: { (next, []) })
        XCTAssertEqual(result?.item, episode); XCTAssertEqual(result?.resumeSeconds, 1.25)
        XCTAssertEqual(server.callCount("episodes"), 0); XCTAssertEqual(server.callCount("playbackInfo"), 1)
    }
    func testResolutionPreservesOriginalErrorTypeEmptyResultAndEpisodeOrder() async throws {
        let server = PreparationFixtureServer()
        server.episodesResult = .failure(Failure(name: "剧集请求失败"))
        do { _ = try await PlaybackPreparationWorkflow.resolve(item: .init(id: "series", name: "剧", kind: .series), server: server, home: { ([], []) }); XCTFail() }
        catch { XCTAssertTrue(error is Failure); XCTAssertEqual("\(error)", "剧集请求失败") }
        let empty = try await prepare(.init(id: "box", name: "合集", kind: .boxSet), server: server)
        if case let .noContent(title, error) = empty.0 { XCTAssertEqual(title, "合集"); XCTAssertEqual(error, "这个合集里还没有可播放的内容") } else { XCTFail() }
        var special = item(); special.id = "special"; special.seasonNumber = 0
        var watched = item(); watched.id = "watched"; watched.playState?.played = true
        var first = item(); first.id = "first"
        server.episodesResult = .success([special, watched, first, item()])
        let selected = try await PlaybackPreparationWorkflow.resolve(item: .init(id: "series", name: "剧", kind: .series), server: server, home: { ([], []) })
        XCTAssertEqual(selected, first)
    }
    func testPlaybackInfoFallbackKeepsOriginalFailureAndNativeRuntime() async throws {
        let server = PreparationFixtureServer(), calls = Calls(), original = item()
        server.playbackInfoHandler = { _ in throw Failure(name: "最初错误") }
        server.streamHandler = { id, source, session in calls.add("\(id):\(source ?? "nil"):\(session ?? "nil")"); return "direct" }
        let (_, prepared) = try await prepare(original, server: server)
        XCTAssertEqual(prepared?.context.durationSeconds, original.runtimeSeconds); XCTAssertNil(prepared?.context.playSessionID)
        XCTAssertEqual(prepared?.context.mediaSourceID, nil); XCTAssertEqual(calls.all, ["episode:nil:nil"])
        server.streamHandler = { _, _, _ in throw Failure(name: "备用直连错误") }
        let (failed, result) = try await prepare(original, server: server); XCTAssertNil(result)
        if case let .failed(_, error, phase, original) = failed {
            XCTAssertEqual(error, "播放信息获取失败：最初错误"); XCTAssertEqual(phase, "playback"); XCTAssertEqual(original.map { "\($0)" }, "最初错误")
        } else { XCTFail() }
    }
    func testPrimaryURLFailureFallsBackWithoutReusingPlaybackSession() async throws {
        let server = PreparationFixtureServer(), calls = Calls()
        server.playbackInfoHandler = { _ in PlaybackInfo(playSessionID: "旧会话", mediaSources: [self.source("primary", play: true)]) }
        server.streamHandler = { _, source, session in
            calls.add("\(source ?? "nil"):\(session ?? "nil")")
            if source != nil { throw Failure(name: "主源地址失败") }; return "fallback"
        }
        let (_, result) = try await prepare(item(), server: server)
        XCTAssertEqual(result?.uri, "fallback"); XCTAssertNil(result?.context.playSessionID)
        XCTAssertEqual(calls.all, ["primary:旧会话", "nil:nil"])
    }
    func testCancellationErrorWithoutTaskCancellationKeepsInfoFallbackSemantics() async throws {
        let server = PreparationFixtureServer()
        server.playbackInfoHandler = { _ in throw CancellationError() }
        let (_, result) = try await prepare(item(), server: server)
        XCTAssertNotNil(result); XCTAssertNil(result?.context.playSessionID)
        server.episodesResult = .failure(CancellationError())
        do { _ = try await PlaybackPreparationWorkflow.resolve(item: .init(id: "series", name: "剧", kind: .series), server: server, home: { ([], []) }); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRetiredMetadataCannotPresentOrCancelNewPreparationLease() async throws {
        guard OcpCoreFeature.isEnabled, let core = OcpPlaybackPreparation() else { throw XCTSkip("Core preparation lease retirement requires enabled Core") }
        let server = PreparationFixtureServer(); var continuation: CheckedContinuation<PlaybackInfo, Never>?
        server.playbackInfoHandler = { _ in await withCheckedContinuation { continuation = $0 } }
        var presented = false
        let task = Task { try await PlaybackPreparationWorkflow.prepare(item: item(), resumeSeconds: nil, server: server,
            home: { ([], []) }, coreClient: core.client, onResolved: { _ in }, onFallback: { _, _ in }, onReady: { _ in presented = true }) }
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(continuation)
        try core.invalidate()
        let new = try core.start(item: ["key":"new", "id":"new", "kind":"movie", "name":"新片"], mode: "resolve")
        pending.resume(returning: PlaybackInfo(playSessionID: "late", mediaSources: []))
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(presented); try core.validate(new); try core.cancel(token: new.token)
    }
    func testContinuationKeepsServerOrderAndCompleteOpaqueNextItem() async throws {
        let server = PreparationFixtureServer(); var current = item(); current.seasonNumber = 1
        var special = current; special.id = "special"; special.seasonNumber = 0
        var next = item(); next.id = "next"; next.playState = .init(played: true, percentage: 1, positionSeconds: 170.25)
        let expected = next
        server.windowHandler = { series, after, limit in
            XCTAssertEqual(series, "series"); XCTAssertEqual(after, "episode"); XCTAssertEqual(limit, 6)
            var earlier = current; earlier.id = "earlier"
            return [earlier, current, special, expected]
        }
        let selected = try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server)
        XCTAssertEqual(selected?.id, "next"); XCTAssertEqual(selected?.overview, expected.overview)
        XCTAssertEqual(selected?.seasonNumber, .max); XCTAssertEqual(selected?.episodeNumber, .max)
        XCTAssertEqual(selected?.playState?.positionSeconds, 170.25); XCTAssertEqual(selected?.genres, expected.genres)
    }
    func testContinuationGuardsMissingAnchorNoSuccessorAndTypedErrors() async throws {
        let server = PreparationFixtureServer(); var calls = 0
        server.windowHandler = { _, _, _ in calls += 1; return [] }
        var missingSeries = item(); missingSeries.seriesID = nil
        var special = item(); special.seasonNumber = 0
        for current in [MediaItem(id: "movie", name: "电影", kind: .movie), missingSeries, special] {
            let next = try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server); XCTAssertNil(next)
        }
        XCTAssertEqual(calls, 0)
        let current = item()
        for values in [[], [current], [MediaItem(id: "missing", name: "缺锚点", kind: .episode)]] {
            server.windowHandler = { _, _, _ in values }
            let next = try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server); XCTAssertNil(next)
        }
        server.windowHandler = { _, _, _ in throw Failure(name: "typed-window") }
        do { _ = try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server); XCTFail() }
        catch { XCTAssertEqual((error as? Failure)?.name, "typed-window") }
        server.windowHandler = { _, _, _ in throw CancellationError() }
        do { _ = try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCancelledContinuationCannotReturnLateNextItem() async throws {
        let server = PreparationFixtureServer(); var continuation: CheckedContinuation<[MediaItem], Never>?
        server.windowHandler = { _, _, _ in await withCheckedContinuation { continuation = $0 } }
        let current = item(); var next = current; next.id = "next"
        let task = Task { try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server) }
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(continuation); task.cancel(); pending.resume(returning: [current, next])
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRetiredContinuationCannotConsumeNewPreparation() async throws {
        guard OcpCoreFeature.isEnabled, let core = OcpPlaybackPreparation() else { throw XCTSkip("Core continuation retirement requires enabled Core") }
        let server = PreparationFixtureServer(); var continuation: CheckedContinuation<[MediaItem], Never>?
        server.windowHandler = { _, _, _ in await withCheckedContinuation { continuation = $0 } }
        let current = item(); var next = current; next.id = "next"
        let task = Task { try await PlaybackPreparationWorkflow.nextEpisode(after: current, server: server, coreClient: core.client) }
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(continuation); try core.invalidate()
        let fresh = try core.start(item: ["key":"fresh", "id":"fresh", "kind":"movie", "name":"新片"], mode: "resolve")
        pending.resume(returning: [current, next])
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        try core.validate(fresh); try core.cancel(token: fresh.token)
    }

}
