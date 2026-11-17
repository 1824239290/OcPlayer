import Foundation
import XCTest
@testable import OcPlayerCore

@MainActor
final class OcpPlaybackTracksTests: XCTestCase {
    private func flow() throws -> OcpPlaybackTracks {
        guard let flow = OcpPlaybackTracks() else { throw XCTSkip("Core dylib is required for track receipts") }
        return flow
    }
    func testTypedTrackEffectsKeepSignedRangesAndDistinctImportReceipts() throws {
        let flow = try flow()
        let add = try flow.begin(["operation": "importSubtitle", "path": "/字幕.srt", "name": "繁體"])
        let firstID = try XCTUnwrap(add.operationId)
        let select = try flow.complete(operationID: firstID, success: true, trackID: .max)
        let secondID = try XCTUnwrap(select.operationId)
        XCTAssertGreaterThan(secondID, firstID)
        XCTAssertEqual(select.effect?.id, .max)
        XCTAssertEqual(flow.snapshot.externalNames[String(Int64.max)], "繁體")
        XCTAssertThrowsError(try flow.complete(operationID: firstID, success: false))
        XCTAssertEqual(flow.snapshot.pendingOperationId, secondID)
        try flow.complete(operationID: secondID, success: true)
        XCTAssertTrue(flow.snapshot.manualChoice)
        try flow.reset()
        let audio = try flow.begin(["operation": "selectAudio", "id": Int64.min])
        XCTAssertEqual(audio.effect?.id, .min)
        try flow.complete(operationID: XCTUnwrap(audio.operationId), success: true)
        XCTAssertFalse(flow.snapshot.manualChoice)
    }
    func testResetAndMalformedReceiptsDoNotConsumeNewEffect() throws {
        let flow = try flow()
        let old = try flow.begin(["operation": "selectSubtitle", "id": 4])
        try flow.reset()
        let new = try flow.begin(["operation": "attachSubtitle", "path": "/外挂.srt", "name": NSNull()])
        XCTAssertThrowsError(try flow.complete(operationID: XCTUnwrap(old.operationId), success: true))
        XCTAssertThrowsError(try flow.complete(operationID: XCTUnwrap(new.operationId), success: true))
        XCTAssertEqual(flow.snapshot.pendingOperationId, new.operationId)
        try flow.complete(operationID: XCTUnwrap(new.operationId), success: true, trackID: .min)
        XCTAssertTrue(flow.snapshot.externalNames.isEmpty)
        XCTAssertNil(flow.snapshot.pendingOperationId)
    }
}
