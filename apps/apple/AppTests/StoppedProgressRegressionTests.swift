import CoreModel
import Foundation
import JellyfinKit
import MetadataKit
@testable import OcPlayer
@testable import PlaybackKit
import XCTest

/// 使用生产默认 Stopped 超时与真实首页/SQLite 路径，防止末次进度被旧响应覆盖。
@MainActor
final class StoppedProgressRegressionTests: XCTestCase {
    func testNormalStoppedRefreshKeepsFinalProgress() async throws {
        try await verifyProgress(suspendStopped: false)
    }

    func testTimedOutStoppedRefreshKeepsFinalProgress() async throws {
        try await verifyProgress(suspendStopped: true)
    }

    private func verifyProgress(suspendStopped: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel()
        app.metadata.setup(directory: directory)
        _ = await app.metadata.waitUntilReady()
        let old = MediaItem(id: "progress-probe", name: "probe", kind: .movie,
                            playState: .init(played: false, percentage: 0, positionSeconds: 0))
        let server = StubMediaServer()
        server.itemResult = .success(old)
        server.resumeResult = .success([old])
        app.server = server
        _ = try await app.metadata.refreshItem(itemID: old.id)
        await app.loadHome()
        let controller = PlaybackController()
        app.playback = controller
        app.nowPlayingItem = old
        controller.state.apply(.durationChanged(.seconds(100)))
        controller.state.apply(.positionChanged(.seconds(42)))
        let source = StoppedProgressSource()
        let reporter = SuspendingStoppedReporter(server: server, item: old, suspend: suspendStopped)
        defer { reporter.release(); _ = source; _ = controller }
        let coordinator = PlaybackReportingCoordinator(stateSource: source, heartbeatInterval: .seconds(60))
        app.playbackReporting = coordinator
        coordinator.start(reporter: reporter, context: PlaybackSessionContext(itemID: old.id),
                          requestID: UUID(), resumeSeconds: nil, onTerminal: { _ in })
        app.dismissPlayer()
        await app.metadata.pendingPlaybackProgressWrite?.value
        let store = try XCTUnwrap(app.metadata.activeStore)
        let tenant = TenantID(profile: server.profile)
        let before = try await store.item(old.id, tenant: tenant)
        print("PROBE local-before-refresh suspend=\(suspendStopped) position=\(before?.item.playState?.positionSeconds ?? -1)")
        XCTAssertEqual(before?.item.playState?.positionSeconds, 42)
        await app.dismissFollowUpTask?.value
        let after = try await store.item(old.id, tenant: tenant)
        print("PROBE after-refresh suspend=\(suspendStopped) pendingStop=\(reporter.isSuspended) home=\(app.home.resume.first?.playState?.positionSeconds ?? -1) disk=\(after?.item.playState?.positionSeconds ?? -1)")
        XCTAssertEqual(app.home.resume.first?.playState?.positionSeconds, 42,
                       "服务端上报超时不应把刚写入的本地末次进度盖旧")
        XCTAssertEqual(after?.item.playState?.positionSeconds, 42)
        XCTAssertEqual(reporter.isSuspended, suspendStopped)
    }
}

@MainActor
private final class StoppedProgressSource: PlaybackReportingStateSource {
    func playbackReportSnapshot(for requestID: PlaybackRequest.ID) -> PlaybackReportSnapshot? {
        PlaybackReportSnapshot(state: .active, positionSeconds: 42, durationSeconds: 100, sourceOpenFailed: false)
    }
}

@MainActor
private final class SuspendingStoppedReporter: PlaybackReporting {
    let server: StubMediaServer
    let item: MediaItem
    let suspend: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isSuspended = false

    init(server: StubMediaServer, item: MediaItem, suspend: Bool) {
        self.server = server; self.item = item; self.suspend = suspend
    }
    func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async {}
    func reportPlaybackProgress(context: PlaybackSessionContext, positionSeconds: Double, isPaused: Bool) async {}
    func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async {
        if suspend {
            isSuspended = true
            await withCheckedContinuation { continuation = $0 }
            isSuspended = false
        }
        var updated = item
        updated.playState = .init(played: false, percentage: positionSeconds / 100, positionSeconds: positionSeconds)
        server.resumeResult = .success([updated])
    }
    func release() { continuation?.resume(); continuation = nil }
}
