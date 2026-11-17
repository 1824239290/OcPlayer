import Foundation
import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// 删除字幕轨的接线：菜单闸门（`canRemove`）→ 引擎调用 → 记账清理 → 偏好收敛。
///
/// 真内核那一半（外挂轨报 `canRemove` 且删得掉、内嵌轨报 false）在
/// `Packages/ErikaKit/Tests/ErikaKitTests/ErikaTrackTests.swift` 里用真内核跑；
/// 这里验的是 App 层**接线**——闸门真的拦住了、删完的账真的清了、删掉当前选中的
/// 那条之后真的会重新收敛到按偏好的那条。
@MainActor
final class SubtitleRemovalTests: XCTestCase {

    /// 带真实轨道表的替身内核：`removeSubtitleTrack` 记录调用（并可选择抛错），
    /// 成功时**同步**把它从轨道表里摘掉。
    ///
    /// 移除做成同步而不是像 `SubtitlePreferenceTests` 的选轨那样异步，是因为
    /// 控制器删完立刻 `refreshTracks` 并按新列表收敛：内核若是异步，测试就只能靠
    /// 「再刷一次」兜，验不到「删掉选中轨 → 自动重选」这条真正要守的路。真内核上
    /// 移除在 `tracks()` 下一次读取时也已经生效（见 ErikaTrackTests 的轮询）。
    private final class TrackedFakeEngine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(
            id: "subtitle-removal-fake",
            displayName: "SubtitleRemovalFake",
            summary: "测试替身",
            supportsKernelDanmaku: false
        )

        let events: AsyncStream<PlayerEvent>
        private let continuation: AsyncStream<PlayerEvent>.Continuation
        private let lock = NSLock()
        private var _tracks: [TrackInfo]
        private var _removedIDs: [Int64] = []
        private var _selectedIDs: [Int64?] = []
        private var _current: Int64?
        private var _failNextRemoval = false

        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { PlaybackStats() }

        init(tracks: [TrackInfo], selected: Int64?) {
            var sink: AsyncStream<PlayerEvent>.Continuation!
            events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
            continuation = sink
            _current = selected
            _tracks = Self.applying(selection: selected, to: tracks)
        }

        deinit { continuation.finish() }

        var removedIDs: [Int64] { lock.withLock { _removedIDs } }
        var selectedIDs: [Int64?] { lock.withLock { _selectedIDs } }
        var currentSelection: Int64? { lock.withLock { _current } }

        /// 清空选轨调用记录（断言「这一次没有额外下发」用）。
        func resetSelectionLog() { lock.withLock { _selectedIDs.removeAll() } }

        func failNextRemoval() { lock.withLock { _failNextRemoval = true } }

        @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }

        func open(_ source: PlaybackSource) throws {}
        func play() throws {}
        func pause() throws {}
        func stop() throws {}
        func seek(to position: Duration) throws {}
        func setRate(_ rate: Double) throws {}
        func setVolume(_ volume: Double) throws {}
        func tracks() throws -> [TrackInfo] { lock.withLock { _tracks } }
        func selectAudioTrack(_ id: Int64) throws {}

        func selectSubtitleTrack(_ id: Int64?) throws {
            lock.withLock {
                _selectedIDs.append(id)
                _current = id
                _tracks = Self.applying(selection: id, to: _tracks)
            }
        }

        @discardableResult func addExternalSubtitle(_ uri: String) throws -> Int64 { -1 }
        func setSubtitleScale(_ scale: Double) throws {}
        func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }

        func removeSubtitleTrack(_ id: Int64) throws {
            if lock.withLock({ _failNextRemoval }) {
                lock.withLock { _failNextRemoval = false }
                struct RemovalRejected: Error {}
                throw RemovalRejected()
            }
            lock.withLock {
                _removedIDs.append(id)
                _tracks = _tracks.filter { $0.id != id }
                if _current == id {
                    _current = nil
                    _tracks = Self.applying(selection: nil, to: _tracks)
                }
            }
        }

        private static func applying(selection: Int64?, to tracks: [TrackInfo]) -> [TrackInfo] {
            tracks.map { track in
                guard track.kind == .subtitle else { return track }
                return TrackInfo(
                    id: track.id, kind: track.kind, source: track.source,
                    selected: track.id == selection, title: track.title,
                    language: track.language, codec: track.codec,
                    channels: track.channels, sampleRate: track.sampleRate,
                    canRemove: track.canRemove
                )
            }
        }
    }

    private var savedLanguage: String?
    private var savedEngineSelection: String?

    override func setUp() async throws {
        try await super.setUp()
        savedLanguage = UserDefaults.standard
            .string(forKey: SettingsKeys.subtitleLanguagePreference)
        savedEngineSelection = PlaybackEngineRegistry.storedSelectionID
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.clearSelection()
    }

    override func tearDown() {
        PlaybackEngineRegistry.resetForTesting()
        if let savedEngineSelection {
            PlaybackEngineRegistry.select(savedEngineSelection)
        } else {
            PlaybackEngineRegistry.clearSelection()
        }
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: SettingsKeys.subtitleLanguagePreference)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.subtitleLanguagePreference)
        }
        PlaybackEngineAssembly.registerAll()
        super.tearDown()
    }

    private func makeController(
        tracks: [TrackInfo],
        selected: Int64?,
        preference: SubtitleLanguagePreference = .chineseSimplified
    ) -> (PlaybackController, TrackedFakeEngine) {
        let engine = TrackedFakeEngine(tracks: tracks, selected: selected)
        PlaybackEngineRegistry.register(TrackedFakeEngine.descriptor) { engine }
        PlaybackPreferences.subtitleLanguagePreference = preference
        let controller = PlaybackController()
        XCTAssertNotNil(controller.prepareEngine(), "替身内核应能创建")
        return (controller, engine)
    }

    /// 外挂轨（可删）+ 内嵌中文轨（不可删）。
    private func removable() -> TrackInfo {
        TrackInfo(id: 10, kind: .subtitle, source: .external, selected: false,
                  title: nil, language: nil, codec: "srt", channels: nil, sampleRate: nil,
                  canRemove: true)
    }

    private func embeddedChinese() -> TrackInfo {
        TrackInfo(id: 2, kind: .subtitle, source: .embedded, selected: false,
                  title: nil, language: "chi", codec: "ass", channels: nil, sampleRate: nil,
                  canRemove: false)
    }

    /// 取一条**带正确 `selected` 的活轨**——UI 的调用点就是这样拿的
    /// （`ForEach(state.subtitleTracks)`，而状态是 `engine.tracks()` 的过滤副本；
    /// 这里直接从引擎取，省掉一次刷新，值与 UI 完全一致）。
    ///
    /// 别用上面的构造值直接调 `removeSubtitle`：那些值的 `selected` 恒为 false，
    /// 「删的是当前选中轨」这条最重要的分支就永远走不到，用例会在没验证的情况下通过。
    private func liveTrack(
        _ engine: TrackedFakeEngine,
        id: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TrackInfo {
        let track = try engine.tracks().first { $0.id == id }
        return try XCTUnwrap(track, "前提：轨道 \(id) 应在内核轨道表里", file: file, line: line)
    }

    /// 闸门：`canRemove` 为 false 的轨（内嵌）连引擎都不该碰。
    ///
    /// 这条是「菜单项显隐」与「控制器」之间唯一的契约：UI 已经不渲染删除按钮了，
    /// 但控制器若只看 `source` 猜，就会有第二条路径把内嵌轨递给内核去拒。
    func testEmbeddedTrackIsNeverSentToEngine() throws {
        let (controller, engine) = makeController(tracks: [embeddedChinese()], selected: 2)
        controller.removeSubtitle(try liveTrack(engine, id: 2))

        XCTAssertTrue(engine.removedIDs.isEmpty, "canRemove == false 的轨不该下发移除")
        XCTAssertEqual(engine.currentSelection, 2, "也不该顺手动选择")
    }

    /// 删的是没在显示的轨：当前选择不动，也不触发重选。
    func testRemovingUnselectedTrackKeepsSelection() throws {
        let (controller, engine) = makeController(
            tracks: [removable(), embeddedChinese()], selected: 2
        )
        XCTAssertEqual(engine.currentSelection, 2, "前提：内嵌中文轨在显示")
        engine.resetSelectionLog()

        controller.removeSubtitle(try liveTrack(engine, id: 10))

        XCTAssertEqual(engine.removedIDs, [10], "应下发一次移除")
        XCTAssertEqual(engine.currentSelection, 2, "删旁轨不该改当前字幕")
        XCTAssertTrue(engine.selectedIDs.isEmpty, "不该额外下发选轨")
        XCTAssertEqual(controller.state.subtitleTracks.count, 1, "轨道列表应已刷新")
    }

    /// 删掉**当前选中**的那条：清掉「用户自己拨过」闸门，让偏好校正收敛到剩下的轨。
    ///
    /// 这是本功能最容易做漏的一步——闸门是为「别覆盖用户的选择」而设的，而那条轨
    /// 已经不存在了；继续拦着，用户就会停在「字幕没了也不自动选」的状态里。
    func testRemovingSelectedTrackReConvergesToPreference() throws {
        let (controller, engine) = makeController(
            tracks: [removable(), embeddedChinese()], selected: 10
        )
        // 模拟用户自己点过外挂那条：闸门抬起（本片内不再自动改）。
        controller.setSubtitle(try liveTrack(engine, id: 10))
        XCTAssertTrue(controller.userChoseSubtitleForCurrentSource, "前提：用户拨过")
        XCTAssertEqual(engine.currentSelection, 10)

        controller.removeSubtitle(try liveTrack(engine, id: 10))

        XCTAssertEqual(engine.removedIDs, [10])
        XCTAssertFalse(controller.userChoseSubtitleForCurrentSource, "删掉选中轨后闸门应清除")
        XCTAssertEqual(
            engine.selectedIDs.last, 2,
            "剩下的中文内嵌轨应被偏好校正接着选上（默认档：中文优先·简体）"
        )
    }

    /// 移除失败：报错徽章 + **不动**闸门与选择（失败不该连带关掉自动校正）。
    func testRemovalFailureKeepsStateAndSurfacesError() throws {
        let (controller, engine) = makeController(
            tracks: [removable(), embeddedChinese()], selected: 10
        )
        controller.setSubtitle(try liveTrack(engine, id: 10))
        engine.failNextRemoval()

        controller.removeSubtitle(try liveTrack(engine, id: 10))

        XCTAssertNotNil(controller.setupError, "失败要有落点")
        XCTAssertTrue(controller.userChoseSubtitleForCurrentSource, "失败不该清除用户选择闸门")
        XCTAssertEqual(engine.currentSelection, 10, "失败后当前字幕不变")
        XCTAssertEqual(controller.state.subtitleTracks.count, 2, "轨道列表不该被改")
    }
}
