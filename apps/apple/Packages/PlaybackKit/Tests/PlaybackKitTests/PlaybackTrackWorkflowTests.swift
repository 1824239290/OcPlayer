import Foundation
import Observation
import OcPlayerCore
import SwiftUI
import XCTest
@testable import PlaybackKit

@MainActor
final class PlaybackTrackWorkflowTests: XCTestCase {
    private final class Engine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(id: "tracks-flow", displayName: "Tracks", summary: "Fixture", supportsKernelDanmaku: false)
        let events = AsyncStream<PlayerEvent> { $0.finish() }
        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { .init() }
        var history: [String] = []
        var failure: String?
        var onCall: (() -> Void)?
        var addedID: Int64 = .max
        struct FixtureError: Error {}
        func record(_ call: String) throws { history.append(call); onCall?(); if failure == call { throw FixtureError() } }
        @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }
        func open(_ source: PlaybackSource) throws {}
        func play() throws {}
        func pause() throws {}
        func stop() throws {}
        func seek(to position: Duration) throws {}
        func setRate(_ rate: Double) throws {}
        func setVolume(_ volume: Double) throws {}
        func tracks() throws -> [TrackInfo] { [] }
        func selectAudioTrack(_ id: Int64) throws { try record("audio:\(id)") }
        func selectSubtitleTrack(_ id: Int64?) throws { try record("subtitle:\(id.map(String.init) ?? "off")") }
        func addExternalSubtitle(_ uri: String) throws -> Int64 { try record("add:\(uri)"); return addedID }
        func removeSubtitleTrack(_ id: Int64) throws { try record("remove:\(id)") }
        func setSubtitleScale(_ scale: Double) throws {}
        func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }
    }
    private func subtitle(_ id: Int64, selected: Bool = false, removable: Bool = true) -> TrackInfo {
        TrackInfo(id: id, kind: .subtitle, source: .external, selected: selected, title: "简体", language: nil, codec: "srt", channels: nil, sampleRate: nil, canRemove: removable)
    }
    func testImportTwoEffectsPreservesNameOnSelectionFailureAndRetiresWorkOnReset() throws {
        let workflow = PlaybackTrackWorkflow(), engine = Engine()
        XCTAssertEqual(workflow.usesCore, OcpCoreFeature.isEnabled && OcpPlaybackTracks() != nil)
        engine.failure = "subtitle:\(Int64.max)"
        XCTAssertThrowsError(try workflow.perform(.importSubtitle(path: "/副本.srt", name: "简体"), engine: engine))
        XCTAssertEqual(engine.history, ["add:/副本.srt", "subtitle:\(Int64.max)"])
        XCTAssertEqual(workflow.externalNames[.max], "简体"); XCTAssertFalse(workflow.manualChoice)
        engine.failure = nil
        try workflow.perform(.automatic(tracks: [subtitle(.max)], preference: .chineseSimplified, current: nil), engine: engine)
        XCTAssertFalse(workflow.manualChoice)
        try workflow.perform(.selectSubtitle(nil), engine: engine); XCTAssertTrue(workflow.manualChoice)
        try workflow.reset(); XCTAssertFalse(workflow.manualChoice); XCTAssertTrue(workflow.externalNames.isEmpty)
    }
    func testSelectedRemovalUnlocksOnlyAfterPhysicalSuccess() throws {
        let workflow = PlaybackTrackWorkflow(), engine = Engine()
        try workflow.registerName(id: 8, name: "繁體"); try workflow.perform(.selectSubtitle(8), engine: engine)
        engine.failure = "remove:8"
        XCTAssertThrowsError(try workflow.perform(.removeSubtitle(subtitle(8, selected: true)), engine: engine))
        XCTAssertTrue(workflow.manualChoice); XCTAssertEqual(workflow.externalNames[8], "繁體")
        engine.failure = nil
        XCTAssertFalse(try workflow.perform(.removeSubtitle(subtitle(8, selected: true, removable: false)), engine: engine))
        try workflow.perform(.removeSubtitle(subtitle(8, selected: true)), engine: engine)
        XCTAssertFalse(workflow.manualChoice); XCTAssertNil(workflow.externalNames[8])
    }
    func testBatchRunsOnlyAfterCurrentBatchEndsAndManualChoiceSuppressesPreference() throws {
        let workflow = PlaybackTrackWorkflow(), engine = Engine()
        try workflow.beginBatch(id: "old"); try workflow.beginBatch(id: "new")
        XCTAssertFalse(try workflow.endBatch(id: "old")); XCTAssertTrue(workflow.isLoadingBatch)
        try workflow.perform(.attachSubtitle(path: "/sidecar.srt", name: "繁體"), engine: engine)
        XCTAssertEqual(workflow.externalNames[.max], "繁體")
        XCTAssertFalse(try workflow.perform(.automatic(tracks: [subtitle(1)], preference: .chineseSimplified, current: nil), engine: engine))
        XCTAssertTrue(try workflow.endBatch(id: "new"))
        XCTAssertTrue(try workflow.perform(.automatic(tracks: [subtitle(1)], preference: .chineseSimplified, current: nil), engine: engine))
        try workflow.perform(.selectSubtitle(nil), engine: engine)
        XCTAssertFalse(try workflow.perform(.automatic(tracks: [subtitle(1)], preference: .chineseSimplified, current: nil), engine: engine))
    }
    func testNestedEngineRefreshDoesNotReenterOrCommitFailedAudioSelection() throws {
        let workflow = PlaybackTrackWorkflow(), engine = Engine()
        var nested: Bool?, mirror: [Int64] = []
        engine.onCall = { nested = try? workflow.perform(.automatic(tracks: [self.subtitle(1)], preference: .chineseSimplified, current: nil), engine: engine) }
        engine.failure = "audio:7"
        XCTAssertThrowsError(try workflow.perform(.selectAudio(7), engine: engine, didSelectAudio: { mirror.append($0) }))
        XCTAssertEqual(nested, false); XCTAssertTrue(mirror.isEmpty); XCTAssertEqual(engine.history, ["audio:7"])
        engine.failure = nil
        try workflow.perform(.selectAudio(8), engine: engine, didSelectAudio: { mirror.append($0) })
        XCTAssertEqual(mirror, [8])
    }
    func testExternalDisplayNamesPublishObservationAfterCoreAcknowledgesAddition() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var changed = false
            func mark() { lock.withLock { changed = true } }
            var value: Bool { lock.withLock { changed } }
        }
        let workflow = PlaybackTrackWorkflow(), engine = Engine(), flag = Flag()
        withObservationTracking { _ = workflow.externalNames } onChange: { flag.mark() }
        try workflow.perform(.attachSubtitle(path: "/字幕.srt", name: "简体"), engine: engine)
        XCTAssertTrue(flag.value)
        XCTAssertEqual(workflow.externalNames[.max], "简体")
    }
    func testSelectorMatchesIndependentNativePolicyAcrossUnicodeAndFieldTrustCorpus() throws {
        guard let core = OcpPlaybackTracks() else { throw XCTSkip("Core-only differential selector contract") }
        let fields = ["", "eng", "jpn", "sc", "sg", "mo", "SC", "zh-Hans", "zh-Hant", "Chinese (Simplified)", "CHS&JPN", "CHT", "简体中文", "繁體", "中日", "简繁", "Big5", "GB2312", "xchsx", "chs\u{0301}", "chs\u{FE0F}", "中\u{FE0F}文", "İCHS", "ｃｈｓ", "①", "Ⅻ", "chs\u{200D}", "s\u{0345}", "正體", "简_英"]
        let preferences: [SubtitleLanguagePreference] = [.chineseSimplified, .chineseTraditional, .followSource, .off]
        for (a, language) in fields.enumerated() {
            for (b, title) in fields.enumerated() {
                let tracks = [TrackInfo.stub(id: .min, kind: .subtitle, source: (a % 2 == 0 ? .embedded : .external), title: title, language: language), TrackInfo.stub(id: .max, kind: .subtitle, source: (a % 2 == 0 ? .embedded : .external), title: fields[(a+b+7) % fields.count], language: "eng")]
                let names = [Int64.max: fields[(a+b+13) % fields.count]]
                for preference in preferences {
                    let current: Int64? = b % 3 == 0 ? nil : (b % 3 == 1 ? .min : .max)
                    let native = SubtitleTrackSelector.nativeSelection(in: tracks, preference: preference, current: current, displayNames: names)
                    let wire = try core.selection(tracks: tracks.map { PlaybackTrackWorkflow.wire($0, displayName: names[$0.id]) }, preference: preference.rawValue, current: current)
                    let actual: SubtitleSelection = wire.action == "select" ? .select(try XCTUnwrap(wire.id)) : (wire.action == "disable" ? .disable : .keep)
                    XCTAssertEqual(actual, native, "a=\(a) b=\(b) preference=\(preference)")
                }
            }
        }
    }
}
