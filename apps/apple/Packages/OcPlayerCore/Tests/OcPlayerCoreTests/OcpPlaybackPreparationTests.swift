import Foundation
import XCTest
@testable import OcPlayerCore

@MainActor
final class OcpPlaybackPreparationTests: XCTestCase {
    func testTypedEffectsKeepReadyLeaseUntilAcknowledgementAndRejectOldWork() throws {
        guard let flow = OcpPlaybackPreparation() else { throw XCTSkip("Core library is required for preparation effects") }
        let first = try flow.start(item: ["key":"item", "id":"item", "name":"电影", "kind":"movie"], mode: "open", resumeSeconds: 1.25)
        XCTAssertEqual(first.effect, "resolved"); XCTAssertEqual(first.arguments?.resumeSeconds, 1.25)
        XCTAssertThrowsError(try flow.resume(first, response: false)); try flow.validate(first)
        let info = try flow.resume(first, response: true)
        XCTAssertThrowsError(try flow.resume(first, response: true))
        let fallback = try flow.fail(info, message: "原始错误", cancelled: false)
        XCTAssertEqual(fallback.effect, "fallback")
        let url = try flow.resume(fallback, response: true); XCTAssertNil(url.arguments?.playSessionId)
        let ready = try flow.resume(url, response: "https://fixture/direct")
        XCTAssertEqual(ready.effect, "ready"); XCTAssertEqual(ready.arguments?.uri, "https://fixture/direct")
        try flow.validate(ready); try flow.invalidate()
        XCTAssertThrowsError(try flow.validate(ready))
        let new = try flow.start(item: ["key":"new", "id":"new", "name":"新片", "kind":"audio"], mode: "resolve")
        XCTAssertGreaterThan(new.token, ready.token); try flow.cancel(token: ready.token); try flow.validate(new)
        XCTAssertTrue(try flow.resume(new, response: true).done)
    }
    func testOriginalWireDecodingRetainsUnsignedTokensAndPreferredSourceOrder() throws {
        let json = """
        {"ok":true,"code":0,"retryable":false,"message":"","data":{"token":18446744073709551615,"sequence":18446744073709551614,"effect":"ready","arguments":{"itemKey":"opaque","status":"resolved"},"done":false,"result":null}}
        """
        let wire = try OcpResponse.fromWire(Data(json.utf8))
        let step = try wire.decodeData(OcpPlaybackPreparation.Step.self)
        XCTAssertEqual(step.token, .max); XCTAssertEqual(step.sequence, .max-1); XCTAssertEqual(step.arguments?.itemKey, "opaque")
        guard let flow = OcpPlaybackPreparation() else { throw XCTSkip("Core library is required for source rules") }
        XCTAssertNil(try flow.preferredSource([]))
        XCTAssertEqual(try flow.preferredSource([["key":"a","id":"a","supportsDirectStream":true],["key":"b","id":"b","supportsDirectPlay":true]]), 1)
    }
    func testTypedContinuationWindowAndNoopRelease() throws {
        guard let flow = OcpPlaybackPreparation() else { throw XCTSkip("Core library is required") }
        let item: [String: Any] = ["key":"current", "id":"current", "name":"集", "kind":"episode", "seriesId":"series"]
        let window = try flow.start(item: item, mode: "next")
        XCTAssertEqual(window.effect, "episodeWindow"); XCTAssertEqual(window.arguments?.startItemId, "current"); XCTAssertEqual(window.arguments?.limit, 6)
        let ready = try flow.resume(window, response: [item, ["key":"next", "id":"next", "kind":"episode", "name":"下一集", "seasonNumber":Int64.max]])
        XCTAssertEqual(ready.effect, "ready"); XCTAssertEqual(ready.arguments?.itemKey, "next"); try flow.validate(ready)
        XCTAssertTrue(try flow.resume(ready, response: true).done)
        let noop = try flow.start(item: ["key":"movie", "id":"movie", "name":"电影", "kind":"movie"], mode: "next")
        XCTAssertTrue(noop.done); XCTAssertThrowsError(try flow.validate(noop))
    }
    func testTypedRecoveryPlansSeparateManualRetryAndBackgroundPosition() throws {
        guard let flow = OcpPlaybackFlow() else { throw XCTSkip("Core library is required") }
        let manual = try flow.recoveryPlan(mode: "manual", loading: false, hasPlayback: true, hasRequest: true,
            hasMediaItem: true, hasLoadedSource: true, currentPositionSeconds: 1.25, requestResumeSeconds: 80.5)
        XCTAssertEqual(manual.action, "reprepare"); XCTAssertEqual(manual.resumeSeconds, 80.5)
        let rebuild = try flow.recoveryPlan(mode: "background", loading: false, hasPlayback: true, hasRequest: true,
            hasMediaItem: false, hasLoadedSource: true, currentPositionSeconds: 0, requestResumeSeconds: 80.5)
        XCTAssertEqual(rebuild.action, "reopen"); XCTAssertEqual(rebuild.resumeSeconds, 0)
        XCTAssertThrowsError(try flow.recoveryPlan(mode: "invalid", loading: false, hasPlayback: true, hasRequest: true,
            hasMediaItem: true, hasLoadedSource: true, currentPositionSeconds: 0, requestResumeSeconds: nil))
    }

    func testRecoveryChainGenerationDecodesFromOriginalWireBytes() throws {
        let wire = """
        {"ok":true,"code":0,"retryable":false,"message":"","data":{"playbackRequestId":"opaque","sourceId":"source","active":true,"generation":18446744073709551615,"failoverCount":0,"attempts":[],"pendingSourceId":null}}
        """
        let response = try OcpResponse.fromWire(Data(wire.utf8))
        let snapshot = try response.decodeData(OcpPlaybackFlow.Snapshot.self)
        XCTAssertEqual(snapshot.generation, .max); XCTAssertEqual(snapshot.playbackRequestId, "opaque")
        let events = """
        {"ok":true,"code":0,"retryable":false,"message":"","data":{"generation":18446744073709551615,"state":"playing","positionSeconds":1.25,"durationSeconds":7200.5,"errorCount":18446744073709551614,"failure":{"code":-2147483648,"message":"原始错误"},"foldedStaleTailFailure":false}}
        """
        let eventResponse = try OcpResponse.fromWire(Data(events.utf8))
        let event = try eventResponse.decodeData(OcpPlaybackEvents.Snapshot.self)
        XCTAssertEqual(event.generation, .max); XCTAssertEqual(event.errorCount, .max-1)
        XCTAssertEqual(event.failure?.code, .min); XCTAssertEqual(event.failure?.message, "原始错误")
    }

}
