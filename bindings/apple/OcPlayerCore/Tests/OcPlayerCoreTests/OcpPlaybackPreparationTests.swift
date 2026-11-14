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
}
