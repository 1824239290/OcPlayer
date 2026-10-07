import Foundation
import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// 字幕偏好的落地链路：轨道刷新 → `SubtitleTrackSelector` → 引擎选轨。
///
/// 纯规则在 `PlaybackKit` 的 `SubtitleSelectionTests` 里逐条钉住；这里验的是
/// **接线**——设置页读到的偏好真的会被用上、用户拨过之后真的不会被动、以及
/// 这条链路不会自激（选轨 → 事件 → 再选 → …）。
@MainActor
final class SubtitlePreferenceTests: XCTestCase {

    /// 带真实轨道表的替身内核：`tracks()` 返回构造时给的列表，`selectSubtitleTrack`
    /// 记录调用。
    ///
    /// **选轨是异步生效的**（与真内核一致：`ErikaTrackTests` 里要 tick 之后
    /// `tracks()` 才报新的 `selected`）。所以这里把「收到调用」与「生效到轨道列表」
    /// 分成两步：`selectSubtitleTrack` 只记账并置 `_pending`，`settle()` 才把它折进
    /// `_tracks`。控制器在同一次调用里立刻回读时拿到的仍是**旧选择**——这正是重入
    /// 闸门要挡住的场景，替身若同步生效就测不出来。
    private final class TrackedFakeEngine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(
            id: "subtitle-fake",
            displayName: "SubtitleFake",
            summary: "测试替身",
            supportsKernelDanmaku: false
        )

        let events: AsyncStream<PlayerEvent>
        private let continuation: AsyncStream<PlayerEvent>.Continuation
        private let lock = NSLock()
        private var _tracks: [TrackInfo]
        private var _selectedIDs: [Int64?] = []
        private var _current: Int64?
        private var _pending: Int64?
        private var _hasPending = false
        private var _failNextExternalSubtitle = false
        private var _nextExternalTrackID: Int64 = 100

        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { PlaybackStats() }

        init(tracks: [TrackInfo], selected: Int64?) {
            var sink: AsyncStream<PlayerEvent>.Continuation!
            events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
            continuation = sink
            _tracks = tracks
            _current = selected
            _tracks = Self.applying(selection: selected, to: tracks)
        }

        deinit { continuation.finish() }

        var selectedIDs: [Int64?] { lock.withLock { _selectedIDs } }
        var currentSelection: Int64? { lock.withLock { _current } }

        /// 清空选轨调用记录（断言「之后一次都没再下发」用）。
        func resetSelectionLog() {
            lock.withLock { _selectedIDs.removeAll() }
        }

        /// 内核把待生效的选轨落进轨道列表（模拟真实内核的异步生效点）。
        func settle() {
            lock.withLock {
                guard _hasPending else { return }
                _current = _pending
                _hasPending = false
                _tracks = Self.applying(selection: _current, to: _tracks)
            }
        }

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
                _pending = id
                _hasPending = true
            }
        }

        /// 外挂字幕装载：默认成功并追加一条轨道；`failNextExternalSubtitle` 可让它抛错
        /// （模拟用户选到一个坏字幕文件 / 内核不吃这个格式）。
        @discardableResult func addExternalSubtitle(_ uri: String) throws -> Int64 {
            if lock.withLock({ _failNextExternalSubtitle }) {
                lock.withLock { _failNextExternalSubtitle = false }
                struct BrokenSubtitle: Error {}
                throw BrokenSubtitle()
            }
            lock.withLock { _nextExternalTrackID += 1 }
            let id = lock.withLock { _nextExternalTrackID }
            appendTrack(TrackInfo(
                id: id, kind: .subtitle, source: .external, selected: false,
                title: nil, language: nil, codec: "srt", channels: nil, sampleRate: nil
            ))
            return id
        }
        func setSubtitleScale(_ scale: Double) throws {}
        func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }

        /// 让下一次 `addExternalSubtitle` 抛错。
        func failNextExternalSubtitle() { lock.withLock { _failNextExternalSubtitle = true } }

        /// 追加一条轨道（模拟 Jellyfin 侧车字幕陆续下载完）。
        func appendTrack(_ track: TrackInfo) {
            lock.withLock { _tracks = Self.applying(selection: _current, to: _tracks + [track]) }
        }

        /// 推一条事件给消费者。
        func emit(_ event: PlayerEvent) { continuation.yield(event) }

        private static func applying(selection: Int64?, to tracks: [TrackInfo]) -> [TrackInfo] {
            tracks.map { track in
                guard track.kind == .subtitle else { return track }
                return TrackInfo(
                    id: track.id, kind: track.kind, source: track.source,
                    selected: track.id == selection, title: track.title,
                    language: track.language, codec: track.codec,
                    channels: track.channels, sampleRate: track.sampleRate
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
        preference: SubtitleLanguagePreference
    ) -> (PlaybackController, TrackedFakeEngine) {
        let engine = TrackedFakeEngine(tracks: tracks, selected: selected)
        PlaybackEngineRegistry.register(TrackedFakeEngine.descriptor) { engine }
        PlaybackPreferences.subtitleLanguagePreference = preference
        let controller = PlaybackController()
        XCTAssertNotNil(controller.prepareEngine(), "替身内核应能创建")
        return (controller, engine)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func subtitle(id: Int64, language: String? = nil, title: String? = nil,
                          source: TrackInfo.Source = .embedded) -> TrackInfo {
        TrackInfo(
            id: id, kind: .subtitle, source: source, selected: false,
            title: title, language: language, codec: "ass", channels: nil, sampleRate: nil
        )
    }

    /// 默认偏好下的主诉求：内核默认选中的是第一条英文字幕，轨道就绪后自动切中文。
    func testTrackRefreshSwitchesToChineseSubtitle() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))

        try await waitUntil { engine.selectedIDs == [2] }
        // 内核随后真正生效并推 `trackSelectionChanged`：UI 状态要跟着收敛到新轨。
        engine.settle()
        engine.emit(.trackSelectionChanged)
        try await waitUntil { controller.state.subtitleTracks.first(where: { $0.selected })?.id == 2 }
        XCTAssertEqual(engine.selectedIDs, [2], "生效后的那一轮刷新必须判定 keep")
    }

    /// 回归（同步递归）：方法末尾的 `refreshTracks` 会**同步**再触发回调，而内核选轨
    /// 是异步生效的——同一次调用里回读仍是旧选择。没有重入闸门时
    /// 「判定 → 选轨 → 刷新 → 判定」会一路递归下栈，真实内核上就是栈溢出崩溃
    /// （本用例的替身先不 `settle()`，正对着这个窗口）。
    func testSameTurnRefreshDoesNotRecurseBeforeSelectionSettles() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await waitUntil { !engine.selectedIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(engine.selectedIDs, [2], "同一轮里只该下发一次选轨（未生效前不得重入再发）")
        XCTAssertEqual(controller.appliedSubtitlePreferenceCount, 1)
    }

    /// 默认档就是中文优先·简体——用户什么都不设，这条链路也要生效。
    func testDefaultPreferenceIsSimplifiedChinesePriority() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.subtitleLanguagePreference)
        XCTAssertEqual(PlaybackPreferences.subtitleLanguagePreference, .chineseSimplified)
    }

    /// 幂等：选轨会再推一次 `trackSelectionChanged` → 再刷列表 → 再判定。
    /// 已经是最优解时必须停下（否则 `selectedIDs` 会无限增长）。
    func testDoesNotReapplyWhenSelectionAlreadyMatches() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await waitUntil { engine.selectedIDs == [2] }

        // 内核生效 → `trackSelectionChanged` → 再刷列表：这一轮必须判定 keep。
        engine.settle()
        engine.emit(.trackSelectionChanged)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.selectedIDs, [2], "等价判定必须稳定，不能反复下发选轨")
        XCTAssertEqual(controller.appliedSubtitlePreferenceCount, 1)
    }

    /// 用户自己选过之后，本片内不再自动覆盖——外挂字幕陆续挂上来会持续刷轨道列表，
    /// 不加这道闸就会出现「刚切到日文字幕，两秒后被切回中文」。
    func testUserSelectionDisablesAutoSwitchingForThisSource() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng", title: "English"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        controller.setSubtitle(try engine.tracks()[0])   // 用户明确选了英文字幕
        XCTAssertTrue(controller.userChoseSubtitleForCurrentSource)
        engine.settle()                                   // 用户这一选同样异步生效
        engine.resetSelectionLog()
        XCTAssertEqual(engine.currentSelection, 1)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.selectedIDs.isEmpty, "用户选过之后不得再自动改字幕")
        XCTAssertEqual(engine.currentSelection, 1)
    }

    /// 「关闭字幕」也是用户的选择，同样挡住自动切中文。
    func testUserDisablingSubtitlesIsRespected() async throws {
        let tracks = [subtitle(id: 1, language: "chi", title: "简体")]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        controller.setSubtitle(nil)
        engine.settle()
        XCTAssertNil(engine.currentSelection)
        engine.resetSelectionLog()

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 1)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.selectedIDs.isEmpty, "用户关掉字幕后不得被自动打开")
        XCTAssertNil(engine.currentSelection)
    }

    /// 换源（拆引擎重建）要把「用户选过」的闸门复位：新一集该重新按偏好挑。
    func testSwitchingSourceResetsUserChoiceGate() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        controller.setSubtitle(try engine.tracks()[0])
        XCTAssertTrue(controller.userChoseSubtitleForCurrentSource)

        controller.resetEngine()
        XCTAssertFalse(controller.userChoseSubtitleForCurrentSource, "换源后应重新按偏好挑字幕")
    }

    /// 一条中文字幕都没有时保持内核的选择——用户抱怨的是「默认用第一个」，
    /// 不是「没有中文也要乱切」。
    func testKeepsSourceDefaultWhenNoChineseTrack() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "jpn"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 2, preference: .chineseSimplified)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.selectedIDs.isEmpty)
        XCTAssertEqual(engine.currentSelection, 2)
        XCTAssertEqual(controller.appliedSubtitlePreferenceCount, 0)
    }

    /// 后到的更贴合候选（Jellyfin 侧车中文字幕下载完成）要能顶掉先前的最优解。
    func testLaterExternalChineseSubtitleIsPickedUp() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, title: "繁體中文"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await waitUntil { engine.selectedIDs == [2] }
        engine.settle()

        // 侧车简体字幕下载完：URL 走的是 addExternalSubtitle → refreshTracks 那条路。
        engine.appendTrack(subtitle(id: 3, source: .external))
        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 3)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.selectedIDs, [2], "外挂轨自己的语言未知时仍认已选的中文轨")

        // App 层记录的显示名（"简体"）参与判定后应切过去。
        controller.externalSubtitleNames[3] = "简体"
        controller.state.refreshTracks(from: engine)
        try await waitUntil { engine.selectedIDs == [2, 3] }
        engine.settle()
        engine.emit(.trackSelectionChanged)
        try await waitUntil { controller.state.subtitleTracks.first(where: { $0.selected })?.id == 3 }
    }

    /// 「默认关闭」档：轨道就绪后把内核选中的字幕关掉，之后不再重复下发。
    func testOffPreferenceDisablesSubtitlesOnce() async throws {
        let tracks = [subtitle(id: 1, language: "chi", title: "简体")]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .off)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 1)))
        try await waitUntil { engine.selectedIDs == [nil] }
        engine.settle()

        engine.emit(.trackSelectionChanged)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.selectedIDs, [nil], "已关闭时不得重复下发")
        XCTAssertEqual(controller.appliedSubtitlePreferenceCount, 1)
    }

    /// 回归（复核 P2-2）：坏字幕文件加载失败**不该**关掉自动校正。
    /// 原实现进门就置闸门，选到坏文件后这一整片再也不按偏好选字幕。
    func testFailedSubtitleImportDoesNotDisableAutoSelection() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        engine.failNextExternalSubtitle()
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocplayer-broken-\(UUID().uuidString).srt")
        try "不是字幕".write(to: broken, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }

        controller.loadExternalSubtitle(fileURL: broken)

        XCTAssertNotNil(controller.setupError, "失败应让用户看到原因")
        XCTAssertFalse(
            controller.userChoseSubtitleForCurrentSource,
            "加载失败不该被记成「用户选过」，否则自动校正被永久关掉"
        )
        // 对照：闸门没关，随后的轨道刷新仍会按偏好切中文。
        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await waitUntil { engine.selectedIDs == [2] }
    }

    /// 回归（复核 P1-3）：侧车字幕**整批只切换一次**。
    /// 逐条装载时实时校正会让「繁體先下完、简体后下完」连着切两次字幕轨，
    /// 每次都是内核级轨切换（会停/重启音频输出）。
    func testExternalSubtitleBatchSwitchesAtMostOnce() async throws {
        let tracks = [subtitle(id: 1, language: "eng")]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .chineseSimplified)

        controller.beginExternalSubtitleBatch()
        // 批次内先挂繁體、再挂简体：期间一次都不该下发。
        engine.appendTrack(subtitle(id: 2, source: .external))
        controller.externalSubtitleNames[2] = "繁體"
        controller.state.refreshTracks(from: engine)
        engine.appendTrack(subtitle(id: 3, source: .external))
        controller.externalSubtitleNames[3] = "简体"
        controller.state.refreshTracks(from: engine)
        XCTAssertTrue(engine.selectedIDs.isEmpty, "批次期间不得逐条校正")

        // 收尾用过期代次：闸门要关掉（否则这一整片再也不校正），但不得下发动作。
        let stale = PlaybackSourceGeneration(requestID: UUID(), value: 0)
        XCTAssertFalse(controller.endExternalSubtitleBatch(for: stale))
        XCTAssertFalse(controller.isLoadingExternalSubtitleBatch, "批次闸门必须无条件关掉")
        XCTAssertTrue(engine.selectedIDs.isEmpty, "过期代次不得校正")

        // 闸门已关：随后的轨道刷新按当前列表一次切到最贴合的那条（简体，不是先到的繁體）。
        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 3)))
        try await waitUntil { engine.selectedIDs == [3] }
    }

    /// 「跟随文件默认」档：有中文字幕也不干预，完全回到加这个功能之前的行为。
    func testFollowSourcePreferenceNeverIntervenes() async throws {
        let tracks = [
            subtitle(id: 1, language: "eng"),
            subtitle(id: 2, language: "chi"),
        ]
        let (controller, engine) = makeController(tracks: tracks, selected: 1, preference: .followSource)

        engine.emit(.tracksChanged(TrackCounts(video: 1, audio: 1, subtitle: 2)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.selectedIDs.isEmpty)
        XCTAssertEqual(engine.currentSelection, 1)
        XCTAssertEqual(controller.appliedSubtitlePreferenceCount, 0)
    }
}
