import Foundation
import XCTest
@testable import OcPlayerCore

final class OcpSettingsBackupTests: XCTestCase {
    private func core() throws -> OcpSettingsBackup {
        let path = try OcpTestLibrary.path()
        return try XCTUnwrap(OcpSettingsBackup(libraryPath: path))
    }
    private func bytes(_ extra: String = "", version: Int = 1) -> Data {
        Data("{\"formatVersion\":\(version),\"exportedAt\":\"2026-11-14T00:00:00Z\",\"appVersion\":\"fixture\"\(extra)}".utf8)
    }
    func testLegacyMirrorAndNullableRestoreOperations() throws {
        let result = try core().decode(bytes(",\"mirror\":{\"enabled\":true,\"tmdbEnabled\":false}"))
        XCTAssertTrue(result.summary.hasMirror); XCTAssertFalse(result.summary.hasTMDb)
        XCTAssertEqual(result.effects.map(\.operation), ["set", "remove", "set", "remove", "remove"])
        XCTAssertFalse(result.backupJSON.contains("\"enabled\""))
    }
    func testNativeVersionAndEmptyErrorsRemainTyped() throws {
        let client = try core()
        XCTAssertThrowsError(try client.decode(Data())) { XCTAssertEqual(($0 as? OcpSettingsBackup.Failure)?.kind, "emptyData") }
        XCTAssertThrowsError(try client.decode(bytes(version: 2))) { XCTAssertEqual(($0 as? OcpSettingsBackup.Failure)?.version, 2) }
        XCTAssertTrue(try client.prepare(bytes(version: 2)).backupJSON.contains("\"formatVersion\":2"))
    }
    func testUtf16AndFirstDuplicateKeysDecodeWithoutPrecisionLoss() throws {
        let text = "{\"formatVersion\":1,\"formatVersion\":2,\"exportedAt\":\"2026-11-14T00:00:00Z\",\"appVersion\":\"fixture\"}"
        let result = try core().decode(text.data(using: .utf16LittleEndian)!)
        XCTAssertTrue(result.backupJSON.contains("\"formatVersion\":1"))
    }
    func testSnapshotDefaultsAndPresentFalseAreDistinct() throws {
        let result = try core().snapshot(preferences: ["playback.skipIntro": .init(present: true, value: false), "playback.outroRetentionSeconds": .init(present: true, value: 0)],
            tmdb: ["language": "zh-CN", "preferText": true, "replaceImages": false, "showPlaceholders": true, "cacheDays": 30],
            exportedAt: "2026-11-14T00:00:00Z", appVersion: "fixture", deviceName: nil, dandanplayGatewayURL: nil)
        let object = try JSONSerialization.jsonObject(with: result.backupData) as! [String: Any]
        let playback = object["playback"] as! [String: Any]
        XCTAssertEqual(playback["skipIntro"] as? Bool, false); XCTAssertEqual(playback["skipOutro"] as? Bool, true)
        XCTAssertEqual(playback["outroRetentionSeconds"] as? Int, 0)
    }
    func testEffectNumbersKeepExactInt64AndSummaryUsesGraphemes() throws {
        let text = ",\"tmdb\":{\"apiKey\":\"prefix-👩‍👩‍👧‍👦🇨🇳éz\",\"language\":\"zh-CN\",\"preferText\":true,\"replaceImages\":false,\"showPlaceholders\":true,\"cacheDays\":9007199254740993.0}"
        let result = try core().decode(bytes(text))
        XCTAssertEqual(result.summary.tmdbKeyTail, "••••👩‍👩‍👧‍👦🇨🇳éz")
        let effect = try XCTUnwrap(result.effects.first { $0.field == "tmdb.cacheDays" })
        XCTAssertEqual((try effect.value() as? NSNumber)?.int64Value, 9007199254740993)
    }
}
