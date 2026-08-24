import XCTest
import PlaybackKit
@testable import ErikaKit

final class ErikaDanmakuTests: XCTestCase {

    func testDanmakuTrackLifecycle() throws {
        let xml = try makeBilibiliXML()
        defer { try? FileManager.default.removeItem(at: xml) }

        let engine = try ErikaEngine()
        defer { try? engine.close() }

        let firstID = try engine.addDanmakuTrack(
            fileURI: xml.path,
            name: "Main",
            offset: .milliseconds(250)
        )
        var tracks = try engine.danmakuTracks()
        let first = try XCTUnwrap(tracks.first { $0.id == firstID })
        XCTAssertEqual(first.name, "Main")
        XCTAssertTrue(first.enabled)
        XCTAssertEqual(first.itemCount, 2)
        XCTAssertEqual(first.offset.microseconds, 250_000)

        try engine.setDanmakuTrack(firstID, enabled: false)
        try engine.setDanmakuTrack(firstID, offset: .milliseconds(-500))
        tracks = try engine.danmakuTracks()
        let updated = try XCTUnwrap(tracks.first { $0.id == firstID })
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(updated.offset.microseconds, -500_000)

        let secondID = try engine.addDanmakuTrack(fileURI: xml.path, name: "Secondary")
        XCTAssertEqual(try engine.danmakuTracks().count, 2)
        try engine.removeDanmakuTrack(secondID)
        XCTAssertEqual(try engine.danmakuTracks().map(\.id), [firstID])

        try engine.setDanmakuGlobalOffset(.seconds(1))
        try engine.clearDanmaku()
        XCTAssertTrue(try engine.danmakuTracks().isEmpty)

        try engine.loadDanmaku(fileURI: xml.path)
        tracks = try engine.danmakuTracks()
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.itemCount, 2)
    }

    func testDanmakuConfigRoundTrip() throws {
        let engine = try ErikaEngine()
        defer { try? engine.close() }

        let original = try engine.danmakuConfig()
        var changed = original
        changed.opacity = original.opacity == 0.73 ? 0.71 : 0.73
        changed.displayArea = original.displayArea == 0.63 ? 0.61 : 0.63
        changed.mergeDuplicates.toggle()
        changed.blockTop.toggle()

        try engine.setDanmakuConfig(changed)
        let applied = try engine.danmakuConfig()
        XCTAssertEqual(applied.opacity, changed.opacity, accuracy: 0.0001)
        XCTAssertEqual(applied.displayArea, changed.displayArea, accuracy: 0.0001)
        XCTAssertEqual(applied.mergeDuplicates, changed.mergeDuplicates)
        XCTAssertEqual(applied.blockTop, changed.blockTop)

        try engine.setDanmakuEnabled(false)
        XCTAssertFalse(try engine.danmakuConfig().enabled)
        try engine.setDanmakuEnabled(true)
        XCTAssertTrue(try engine.danmakuConfig().enabled)

        try engine.setDanmakuBlockWords(json: "[]")
        try engine.setDanmakuFont(family: nil, filePath: nil)
    }

    private func makeBilibiliXML() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-danmaku-\(UUID().uuidString).xml")
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <i>
          <d p="0.5,1,25,16777215,0,0,0,0">first</d>
          <d p="1.0,5,25,16711680,0,0,0,0">second</d>
        </i>
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
