import Foundation
import XCTest
@testable import OcPlayerCore

final class OcpCoreClientTests: XCTestCase {
    private struct DecodedPayload: Decodable, Equatable {
        let displayName: String
        let values: [Int]
    }

    private struct Diagnostics: Decodable {
        struct Core: Decodable {
            struct Queue: Decodable {
                let depth: Int
                let bytes: Int
                let capacity: Int
                let byteCapacity: Int
                let coalesced: UInt64
                let dropped: UInt64
            }
            let eventQueueDepth: Int
            let eventQueue: Queue
        }
        let core: Core
    }

    private final class CustomProtocol: URLProtocol, @unchecked Sendable {}

    private func playbackFlow() throws -> OcpPlaybackFlow {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH to exercise shared playback")
        }
        return try XCTUnwrap(OcpPlaybackFlow(libraryPath: path))
    }

    func testRequestChainSurvivesEngineSessionReplacementAndRejectsLateAdoption() throws {
        let flow = try playbackFlow()
        try flow.begin(requestID: "old", sourceID: "primary", alternates: [
            ["id": "alternate", "hasSessionContext": true],
        ])
        let firstEngine = try XCTUnwrap(OcpPlaybackSession(client: flow.client))
        try firstEngine.open(uri: "https://example.test/primary", sourceID: "primary")
        try firstEngine.failed(category: "network", message: "timeout", retryable: true, recordOnly: true)
        XCTAssertEqual(firstEngine.snapshot?.state, "failed")
        let decision = try flow.failed(requestID: "old", kind: "network", hasItem: true)
        XCTAssertEqual(decision.action, "switch")
        XCTAssertEqual(try flow.failed(requestID: "old", kind: "network", hasItem: true).action, "ignored")
        let replacementEngine = try XCTUnwrap(OcpPlaybackSession(client: flow.client))
        try replacementEngine.open(uri: "https://example.test/alternate", sourceID: "alternate")
        XCTAssertTrue(try flow.adopt(fromRequestID: "old", generation: decision.snapshot.generation,
                                    requestID: "new", sourceID: "alternate"))
        XCTAssertEqual(flow.snapshot.failoverCount, 1)
        XCTAssertEqual(try flow.failed(requestID: "new", kind: "format", hasItem: true).action, "manual")
        XCTAssertEqual(flow.snapshot.attempts.map(\.kind), ["network", "format"])
        XCTAssertEqual(flow.snapshot.attempts.map(\.sourceId), ["primary", "alternate"])
        try flow.begin(requestID: "retry", sourceID: nil, alternates: [["id": "alternate", "hasSessionContext": true]])
        let pending = try flow.failed(requestID: "retry", kind: "unknown", hasItem: true)
        try flow.invalidate()
        XCTAssertFalse(try flow.adopt(fromRequestID: "retry", generation: pending.snapshot.generation,
                                     requestID: "late", sourceID: "alternate"))
    }

    func testMalformedFlowArgumentsDoNotModifyActiveRequestOrHistory() throws {
        let flow = try playbackFlow()
        try flow.begin(requestID: "current", sourceID: "primary", alternates: [])
        for (method, args) in [
            ("playbackFlow.begin", ["playbackRequestId": "new", "alternates": [["id": "", "hasSessionContext": true]]] as [String: Any]),
            ("playbackFlow.failed", ["playbackRequestId": "current", "kind": "bad", "hasItem": true]),
            ("playbackFlow.adopt", ["playbackRequestId": "new", "fromPlaybackRequestId": "current", "generation": -1, "sourceId": "alternate"]),
        ] {
            let result = try flow.client.call(method, arguments: args)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.code, 1002)
        }
        let value = try flow.client.call("playbackFlow.snapshot").data.decode(OcpPlaybackFlow.Snapshot.self)
        XCTAssertEqual(value.playbackRequestId, "current")
        XCTAssertEqual(value.failoverCount, 0)
        XCTAssertTrue(value.attempts.isEmpty)
        XCTAssertEqual(try flow.classify(message: "Cancelled network 401").kind, "aborted")
        XCTAssertFalse(try flow.capabilities(kind: "auth").allowsSourceFailover)
        XCTAssertEqual(try flow.capabilities(kind: "network").maximumSourceFailovers, 3)
    }

    func testReportPolicyPreservesPauseHeartbeatAndOnlyCleanNaturalEnd() throws {
        let flow = try playbackFlow()
        let first = try flow.reportStep(state: "paused", positionSeconds: 30, durationSeconds: 100,
                                        sourceOpenFailed: false, mode: "heartbeat", ticks: 0,
                                        reportedPause: false, everyTicks: 10)
        XCTAssertEqual(first.action, "progress")
        let second = try flow.reportStep(state: "paused", positionSeconds: 30, durationSeconds: 100,
                                         sourceOpenFailed: false, mode: "heartbeat", ticks: first.ticks,
                                         reportedPause: first.reportedPause, everyTicks: 10)
        XCTAssertEqual(second.action, "none")
        for (state, openFailed, reachedEnd) in [("stopped", false, true), ("error", false, false), ("stopped", true, false)] {
            let terminal = try flow.reportStep(state: state, positionSeconds: 99, durationSeconds: 100,
                                               sourceOpenFailed: openFailed, mode: "heartbeat", ticks: 9,
                                               reportedPause: false, everyTicks: 10)
            XCTAssertEqual(terminal.action, "stopped")
            XCTAssertEqual(terminal.reachedEnd, reachedEnd)
        }
    }

    func testEngineEventFoldingUpdatesSessionEndAndPreservesPreferences() throws {
        let flow = try playbackFlow()
        let events = try XCTUnwrap(OcpPlaybackEvents(client: flow.client))
        let session = try XCTUnwrap(OcpPlaybackSession(client: flow.client))
        try session.open(uri: "movie.mp4")
        try session.setRate(2)
        try session.setVolume(0.4)
        try session.setMuted(true)
        try session.selectAudio("audio")
        try session.selectSubtitle("subtitle")
        _ = try events.apply(["kind": "duration", "seconds": 100])
        _ = try events.apply(["kind": "position", "seconds": 99])
        _ = try events.apply(["kind": "state_changed", "state": "playing"])
        let end = try events.apply(["kind": "failed", "code": -5, "message": "av_read_frame 本地化 (-5)"])
        XCTAssertTrue(end.foldedTailFailure)
        XCTAssertEqual(end.snapshot.errorCount, 0)
        _ = try events.apply(["kind": "state_changed", "state": "error"])
        try session.refresh()
        XCTAssertEqual(session.snapshot?.state, "ended")
        XCTAssertEqual(session.snapshot?.positionSeconds, 99)
        XCTAssertEqual(session.snapshot?.rate, 2)
        XCTAssertEqual(session.snapshot?.volume, 0.4)
        XCTAssertEqual(session.snapshot?.muted, true)
        XCTAssertEqual(session.snapshot?.audioTrack, "audio")
        XCTAssertEqual(session.snapshot?.subtitleTrack, "subtitle")
        let real = try events.apply(["kind": "failed", "code": 401, "message": "HTTP 401"])
        XCTAssertTrue(real.reportedFailure)
        let after = try events.apply(["kind": "failed", "code": -5, "message": "av_read_frame (-5)"])
        XCTAssertEqual(after.snapshot.state, "error")
        XCTAssertEqual(after.snapshot.failure?.message, "HTTP 401")
        try session.refresh()
        XCTAssertEqual(session.snapshot?.state, "failed")
        try session.setMuted(false)
        XCTAssertEqual(session.snapshot?.volume, 0.4)
    }

    func testEngineRejectsOldGenerationsAndInvalidCommandsWithoutMutation() throws {
        let flow = try playbackFlow()
        let old = try XCTUnwrap(OcpPlaybackEvents(client: flow.client))
        let new = try XCTUnwrap(OcpPlaybackEvents(client: flow.client))
        XCTAssertFalse(try old.apply(["kind": "failed", "code": 401, "message": "old"]).accepted)
        XCTAssertFalse(try old.apply(["kind": "position", "seconds": 99]).accepted)
        XCTAssertNotEqual(old.snapshot.generation, new.snapshot.generation)
        let malformed = try flow.client.call("playbackEvents.apply", arguments: ["generation": new.snapshot.generation, "event": ["kind": "duration", "seconds": -1]])
        XCTAssertFalse(malformed.ok)
        XCTAssertEqual(malformed.code, 1002)
        let snapshot = try flow.client.call("playbackEvents.snapshot").data.decode(OcpPlaybackEvents.Snapshot.self)
        XCTAssertEqual(snapshot.state, "idle")
        XCTAssertEqual(snapshot.errorCount, 0)
        XCTAssertEqual(snapshot.durationSeconds, 0)
        XCTAssertTrue(try new.apply(["kind": "failed", "code": 7, "message": NSNull()]).reportedFailure)
        let duplicate = try new.apply(["kind": "failed", "code": 7, "message": ""])
        XCTAssertFalse(duplicate.reportedFailure)
        XCTAssertEqual(duplicate.snapshot.errorCount, 1)
        XCTAssertEqual(duplicate.snapshot.failure?.message, "")
        XCTAssertFalse(try flow.client.call("playback.setMuted", arguments: ["muted": "yes"]).ok)
    }

    func testNativeEventTelemetryCoalescesAndStaleEventsProduceNoNotifications() throws {
        let flow = try playbackFlow()
        let session = try XCTUnwrap(OcpPlaybackSession(client: flow.client))
        try session.open(uri: "movie.mp4")
        let events = try XCTUnwrap(OcpPlaybackEvents(client: flow.client))
        _ = try events.apply(["kind": "position", "seconds": 30])
        try session.refresh()
        XCTAssertEqual(session.snapshot?.positionSeconds, 30)
        XCTAssertNil(session.snapshot?.durationSeconds, "Unknown-duration streams must not clamp every position to zero")
        try session.pause()
        _ = try events.apply(["kind": "duration", "seconds": 1000])
        _ = try events.apply(["kind": "position", "seconds": 31])
        try session.refresh()
        XCTAssertEqual(session.snapshot?.state, "paused", "Telemetry cannot replay an older engine phase over a newer control")
        _ = try events.apply(["kind": "state_changed", "state": "playing"])
        for index in 0..<1000 { _ = try events.apply(["kind": "position", "seconds": Double(index) / 10]) }
        let diagnostics = try flow.client.call("diag.snapshot").data.decode(Diagnostics.self)
        XCTAssertGreaterThanOrEqual(diagnostics.core.eventQueue.coalesced, 990)
        var collected: [OcpEvent] = []
        while let event = try flow.client.pollEvent() { collected.append(event) }
        let positions = collected.filter { $0.kind == "playback.position" }
        XCTAssertEqual(positions.count, 1)
        if case .object(let payload) = try XCTUnwrap(positions.last).data,
           case .number(let position)? = payload["positionSeconds"] {
            XCTAssertEqual(position, 99.9, accuracy: 0.001)
        } else { XCTFail("Missing latest position") }
        _ = try XCTUnwrap(OcpPlaybackEvents(client: flow.client))
        XCTAssertFalse(try events.apply(["kind": "failed", "code": 401, "message": "old failure"]).accepted)
        XCTAssertNil(try flow.client.pollEvent(), "Rejected generations must not publish into the current source")
    }

    func testSharedForegroundIntentAndErrorDecisionTable() throws {
        let flow = try playbackFlow()
        XCTAssertEqual(try flow.foregroundAction(intentToResume: false, state: "error", hasSetupError: true), "none")
        XCTAssertEqual(try flow.foregroundAction(intentToResume: true, state: nil, hasSetupError: true), "none")
        for state in ["paused", "ready", "playing"] {
            XCTAssertEqual(try flow.foregroundAction(intentToResume: true, state: state, hasSetupError: false), "resume")
            XCTAssertEqual(try flow.foregroundAction(intentToResume: true, state: state, hasSetupError: true), "rebuild")
        }
        for state in ["idle", "opening", "closed", "stopped"] {
            XCTAssertEqual(try flow.foregroundAction(intentToResume: true, state: state, hasSetupError: false), "none")
        }
        XCTAssertEqual(try flow.foregroundAction(intentToResume: true, state: "error", hasSetupError: false), "rebuild")
    }

    func testFoundationDefaultsPermitCoreButInjectedProtocolsDoNot() {
        XCTAssertTrue(OcpCoreFeature.supportsNativeTransport(.default))
        XCTAssertTrue(OcpCoreFeature.supportsNativeTransport(.ephemeral))
        let custom = URLSessionConfiguration.ephemeral
        custom.protocolClasses = [CustomProtocol.self]
        XCTAssertFalse(OcpCoreFeature.supportsNativeTransport(custom))
    }

    func testJSONValueCanDecodeIntoHostTypes() throws {
        let value: JSONValue = .object([
            "displayName": .string("OcPlayer"),
            "values": .array([.number(1), .number(2)]),
        ])
        XCTAssertEqual(try value.decode(DecodedPayload.self), DecodedPayload(displayName: "OcPlayer", values: [1, 2]))
    }

    func testRustCoreSmokeWhenLibraryIsConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH to run the native Rust smoke test")
        }
        let client = try OcpCoreClient(libraryPath: path)
        XCTAssertEqual(OcpCoreClient.abiVersion, 1)
        let ping = try client.call("ping")
        XCTAssertTrue(ping.ok)
        guard case .object(let data) = ping.data, case .bool(true)? = data["pong"] else {
            return XCTFail("ping response must include pong=true")
        }

        let snapshot = try client.snapshot()
        guard case .object(let object) = snapshot else {
            return XCTFail("core snapshot must be an object")
        }
        guard case .bool(true)? = object["ready"] else {
            return XCTFail("new core snapshot must be ready")
        }

        let event = try client.pollEvent()
        XCTAssertEqual(event?.kind, "core.ready")
    }

    func testExplicitMissingLibraryDoesNotLoadAnotherCandidate() {
        XCTAssertThrowsError(try OcpCoreClient(libraryPath: "/nonexistent/ocplayer-core-test.dylib"))
    }

    func testRustEventBackpressurePreservesControlsAndLatestPosition() throws {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH to run the native Rust event test")
        }
        let client = try OcpCoreClient(libraryPath: path)
        try client.call("playback.open", arguments: ["source": "movie.mp4"])
        try client.call("playback.play")
        client.attachSurface(nativeHandle: 1, width: 1920, height: 1080, scale: 2, kind: 0)
        for frame in 0..<7200 {
            client.renderTick(timeSeconds: Double(frame) / 60)
            if frame.isMultiple(of: 60) {
                try client.call("playback.position", arguments: ["positionSeconds": Double(frame) / 60])
            }
        }
        try client.call("playback.pause")
        let diagnostics = try client.diagnosticsSnapshot().decode(Diagnostics.self)
        XCTAssertEqual(diagnostics.core.eventQueueDepth, 7)
        XCTAssertEqual(diagnostics.core.eventQueue.coalesced, 7318)
        XCTAssertEqual(diagnostics.core.eventQueue.dropped, 0)
        XCTAssertLessThanOrEqual(diagnostics.core.eventQueue.bytes, diagnostics.core.eventQueue.byteCapacity)

        var events: [OcpEvent] = []
        while let event = try client.pollEvent() { events.append(event) }
        XCTAssertEqual(events.first?.kind, "core.ready")
        XCTAssertEqual(events.last?.kind, "playback.pause")
        XCTAssertTrue(events.contains { $0.kind == "playback.play" })
        for (previous, next) in zip(events, events.dropFirst()) {
            XCTAssertGreaterThan(next.sequence, previous.sequence)
        }
        let position = try XCTUnwrap(events.first { $0.kind == "playback.position" })
        struct Position: Decodable { let positionSeconds: Double }
        XCTAssertEqual(try position.data.decode(Position.self).positionSeconds, 119)
        let drained = try client.diagnosticsSnapshot().decode(Diagnostics.self)
        XCTAssertEqual(drained.core.eventQueue.bytes, 0)

        // A host that never polls controls must still have a fixed upper bound.
        for position in 0..<1000 {
            try client.call("playback.seek", arguments: ["positionSeconds": position])
        }
        try client.call("playback.stop")
        let overflow = try client.diagnosticsSnapshot().decode(Diagnostics.self)
        XCTAssertEqual(overflow.core.eventQueue.depth, overflow.core.eventQueue.capacity)
        XCTAssertEqual(overflow.core.eventQueue.capacity, 256)
        XCTAssertGreaterThan(overflow.core.eventQueue.dropped, 0)
        var last: OcpEvent?
        while let event = try client.pollEvent() { last = event }
        XCTAssertEqual(last?.kind, "playback.stop")
    }

    func testPlaybackSessionMirrorsLifecycleWhenLibraryIsConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH to run the native Rust playback test")
        }
        UserDefaults.standard.set(true, forKey: OcpCoreFeature.userDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: OcpCoreFeature.userDefaultsKey) }
        let session = try XCTUnwrap(OcpPlaybackSession(libraryPath: path))
        try session.open(uri: "movie.mp4", sourceID: "primary")
        XCTAssertEqual(session.snapshot?.state, "ready")
        try session.ready(durationSeconds: 120)
        try session.play()
        XCTAssertEqual(session.snapshot?.state, "playing")
        try session.updatePosition(seconds: 12.5, durationSeconds: 120)
        XCTAssertEqual(try XCTUnwrap(session.snapshot?.positionSeconds), 12.5, accuracy: 0.001)
        try session.pause()
        XCTAssertEqual(session.snapshot?.state, "paused")
        try session.stop()
        XCTAssertEqual(session.snapshot?.state, "stopped")
    }

    func testPlaybackPreferencesSurvivePositionPauseAndTrackClearing() throws {
        guard let path = ProcessInfo.processInfo.environment["OCP_CORE_LIBRARY_PATH"], !path.isEmpty else {
            throw XCTSkip("Set OCP_CORE_LIBRARY_PATH to run the native Rust preferences test")
        }
        UserDefaults.standard.set(true, forKey: OcpCoreFeature.userDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: OcpCoreFeature.userDefaultsKey) }
        let client = try OcpCoreClient(libraryPath: path)
        let session = try XCTUnwrap(OcpPlaybackSession(client: client))
        try session.open(uri: "movie.mp4")
        try session.ready(durationSeconds: 120)
        try session.pause()
        XCTAssertEqual(session.snapshot?.state, "paused")
        try session.setRate(2)
        try session.setVolume(0.4)
        try session.selectAudio("audio-2")
        try session.selectSubtitle("subtitle-3")
        try session.play()
        try session.updatePosition(seconds: 25, durationSeconds: 125)
        try session.pause()
        try session.seek(seconds: 130)
        XCTAssertEqual(session.snapshot?.rate, 2)
        XCTAssertEqual(session.snapshot?.volume, 0.4)
        XCTAssertEqual(session.snapshot?.audioTrack, "audio-2")
        XCTAssertEqual(session.snapshot?.subtitleTrack, "subtitle-3")
        XCTAssertEqual(session.snapshot?.positionSeconds, 125)
        XCTAssertEqual(session.snapshot?.durationSeconds, 125)
        try session.selectAudio(nil)
        try session.selectSubtitle(nil)
        try session.updatePosition(seconds: 30)
        XCTAssertNil(session.snapshot?.audioTrack)
        XCTAssertNil(session.snapshot?.subtitleTrack)
        XCTAssertEqual(session.snapshot?.rate, 2)
        XCTAssertEqual(session.snapshot?.volume, 0.4)
        XCTAssertEqual(session.snapshot?.durationSeconds, 125)
    }
}
