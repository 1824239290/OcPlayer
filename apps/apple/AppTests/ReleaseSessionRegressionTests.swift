import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
import PlaybackKit
import SwiftUI
import XCTest
@testable import OcPlayer

@MainActor
final class ReleaseSessionRegressionTests: XCTestCase {
    private final class ReviewEngine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(id: "review-fake", displayName: "Review", summary: "Review", supportsKernelDanmaku: false)
        let events: AsyncStream<PlayerEvent>
        let continuation: AsyncStream<PlayerEvent>.Continuation
        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { .init() }
        init() { (events, continuation) = AsyncStream.makeStream() }
        @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }
        func open(_ source: PlaybackSource) throws {}
        func play() throws {}
        func pause() throws {}
        func stop() throws {}
        private let lock = NSLock()
        private var seeks: [Duration] = []
        var seekPositions: [Duration] { lock.withLock { seeks } }
        func seek(to position: Duration) throws { lock.withLock { seeks.append(position) } }
        func setRate(_ rate: Double) throws {}
        func setVolume(_ volume: Double) throws {}
        func tracks() throws -> [TrackInfo] { [] }
        func selectAudioTrack(_ id: Int64) throws {}
        func selectSubtitleTrack(_ id: Int64?) throws {}
        func addExternalSubtitle(_ uri: String) throws -> Int64 { 0 }
        func setSubtitleScale(_ scale: Double) throws {}
        func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }
    }

    func testFinalProgressStaysInOriginalTenant() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "release-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MetadataCoordinator()
        coordinator.setup(directory: directory)
        _ = await coordinator.waitUntilReady()
        let store = try XCTUnwrap(coordinator.activeStore)
        let a = StubMediaServer(profileID: "A:user")
        let b = StubMediaServer(profileID: "B:user")
        let item = MediaItem(id: "same-item-id", name: "A video", kind: .movie)
        try await store.saveItems([item], tenant: TenantID(profile: a.profile))
        try await store.saveItems([MediaItem(id: item.id, name: "B video", kind: .movie)], tenant: TenantID(profile: b.profile))
        let app = AppModel(metadata: coordinator)
        app.server = a
        let controller = PlaybackController()
        app.playback = controller
        let engine = ReviewEngine()
        let consumer = controller.state.start(consuming: engine)
        defer { consumer.cancel() }
        engine.continuation.yield(.durationChanged(.seconds(600)))
        engine.continuation.yield(.positionChanged(.seconds(60)))
        while controller.state.position != .seconds(60) { await Task.yield() }
        app.nowPlayingItem = item
        let finished = app.finishReporting()
        app.server = b
        await finished?.value
        let newTenantItem = try await store.item(item.id, tenant: TenantID(profile: b.profile))
        let oldTenantItem = try await store.item(item.id, tenant: TenantID(profile: a.profile))
        XCTAssertNil(newTenantItem?.item.playState)
        XCTAssertEqual(oldTenantItem?.item.playState?.positionSeconds, 60)
        app.server = nil
    }

    func testExplicitResumeUnderThirtySecondsSchedulesSeek() throws {
        let selected = PlaybackEngineRegistry.storedSelectionID
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.register(ReviewEngine.descriptor) { ReviewEngine() }
        PlaybackEngineRegistry.select(ReviewEngine.descriptor.id)
        defer {
            PlaybackEngineRegistry.resetForTesting()
            if let selected { PlaybackEngineRegistry.select(selected) }
            else { PlaybackEngineRegistry.clearSelection() }
            PlaybackEngineAssembly.registerAll()
        }
        let controller = PlaybackController()
        controller.open(request: PlaybackRequest(title: "recover", uri: "/tmp/review.mp4", resumeSeconds: 20))
        XCTAssertNotNil(controller.resumeTask)
        controller.stopPlayback()
        controller.open(request: PlaybackRequest(title: "control", uri: "/tmp/review.mp4", resumeSeconds: 40))
        XCTAssertNotNil(controller.resumeTask)
        controller.stopPlayback()
    }

    func testExplicitResumePositionsReachEngineAndInvalidValuesDoNot() async throws {
        let selected = PlaybackEngineRegistry.storedSelectionID
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.register(ReviewEngine.descriptor) { ReviewEngine() }
        PlaybackEngineRegistry.select(ReviewEngine.descriptor.id)
        defer {
            PlaybackEngineRegistry.resetForTesting()
            if let selected { PlaybackEngineRegistry.select(selected) }
            else { PlaybackEngineRegistry.clearSelection() }
            PlaybackEngineAssembly.registerAll()
        }
        for position in [1.0, 20, 29, 30, 40, 0, -1, .nan, .infinity] {
            let controller = PlaybackController()
            let request = PlaybackRequest(title: "resume", uri: "/tmp/resume.mp4", resumeSeconds: position)
            controller.open(request: request)
            let engine = try XCTUnwrap(controller.engine as? ReviewEngine)
            engine.continuation.yield(.stateChanged(.ready))
            engine.continuation.yield(.durationChanged(.seconds(600)))
            let source = await controller.waitUntilSourceReady(for: request.id, timeout: .seconds(3))
            XCTAssertNotNil(source)
            if position.isFinite && position > 0 {
                let resume = try XCTUnwrap(controller.resumeTask)
                await resume.value
                XCTAssertEqual(engine.seekPositions, [.seconds(position)])
            } else {
                XCTAssertNil(controller.resumeTask)
                XCTAssertTrue(engine.seekPositions.isEmpty)
            }
            controller.stopPlayback()
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }

    func testSetupWaitCannotInstallRetiredRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "setup-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate()
        let entered = expectation(description: "database open held")
        let coordinator = MetadataCoordinator(openStore: { root in
            entered.fulfill()
            await gate.wait()
            return try MetadataCache.open(at: root)
        })
        coordinator.setActiveServer(StubMediaServer(profileID: "A:user"))
        coordinator.setup(directory: directory)
        await fulfillment(of: [entered], timeout: 3)
        var started = false
        let pending = Task { @MainActor in
            started = true
            return await coordinator.currentRepository()
        }
        while !started { await Task.yield() }
        coordinator.setActiveServer(StubMediaServer(profileID: "B:user"))
        await gate.release()
        let stale = await pending.value
        XCTAssertNil(stale)
        let current = await coordinator.currentRepository()
        XCTAssertNotNil(current)
        XCTAssertFalse(stale === current)
        coordinator.setActiveServer(nil)
    }
}
