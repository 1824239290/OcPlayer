import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// 内核装配与「弹幕走哪条路」的判定。设置页的显示与开关全建立在这两件事上。
@MainActor
final class PlaybackEngineSelectionTests: XCTestCase {

    private var savedSelection: String?

    override func setUp() {
        super.setUp()
        savedSelection = PlaybackEngineRegistry.storedSelectionID
        PlaybackEngineRegistry.resetForTesting()
        PlaybackEngineRegistry.clearSelection()
    }

    override func tearDown() {
        PlaybackEngineRegistry.resetForTesting()
        // 别把开发机上真实的用户选择洗掉。
        if let savedSelection {
            PlaybackEngineRegistry.select(savedSelection)
        } else {
            PlaybackEngineRegistry.clearSelection()
        }
        PlaybackEngineAssembly.registerAll()
        super.tearDown()
    }

    /// 装配点真的把 Erika 注册上了，而且它自报支持内核弹幕。
    /// 这条挂了 = 设置页会显示「没有可用的播放内核」，播放直接打不开。
    func testAssemblyRegistersErika() {
        PlaybackEngineAssembly.registerAll()
        let ids = PlaybackEngineRegistry.available.map(\.id)
        XCTAssertEqual(ids.first, "erika", "Erika 应是第一个（也是默认）内核，实际 \(ids)")

        let erika = PlaybackEngineRegistry.available.first { $0.id == "erika" }
        XCTAssertNotNil(erika)
        XCTAssertTrue(erika?.supportsKernelDanmaku == true, "Erika 有内置弹幕渲染器")
        XCTAssertFalse(erika?.displayName.isEmpty ?? true)
        XCTAssertFalse(erika?.summary.isEmpty ?? true)
    }

    /// 内核弹幕渲染当前版本被禁用：无论偏好怎么说，路线一律是 overlay。
    /// `resolveOverlayDanmakuRoute()` 恢复旧判定（内核支持则听偏好）时改回本测试。
    func testDanmakuRouteIsForcedToOverlayWhileKernelDanmakuDisabled() {
        PlaybackEngineAssembly.registerAll()

        let original = PlaybackPreferences.danmakuUseOverlayRenderer
        defer { PlaybackPreferences.danmakuUseOverlayRenderer = original }

        PlaybackPreferences.danmakuUseOverlayRenderer = true
        XCTAssertTrue(PlaybackController().usesOverlayDanmakuRenderer)

        PlaybackPreferences.danmakuUseOverlayRenderer = false
        XCTAssertTrue(PlaybackController().usesOverlayDanmakuRenderer,
                      "内核弹幕禁用期间不能回到内核渲染，偏好里 overlay=关也不行")
    }

    /// 内核**不支持**内核弹幕时强制 overlay，用户偏好说什么都不管——
    /// 否则弹幕会静默消失（内核收下数据但没有渲染器）。
    /// 这条为将来的非弹幕内核（libmpv / libVLC）守着这段逻辑。
    func testDanmakuRouteIsForcedToOverlayWhenKernelCannotRenderIt() {
        PlaybackEngineRegistry.register(NoDanmakuEngine.descriptor) { NoDanmakuEngine() }
        PlaybackEngineRegistry.select(NoDanmakuEngine.descriptor.id)

        let original = PlaybackPreferences.danmakuUseOverlayRenderer
        defer { PlaybackPreferences.danmakuUseOverlayRenderer = original }

        PlaybackPreferences.danmakuUseOverlayRenderer = false
        XCTAssertTrue(
            PlaybackController().usesOverlayDanmakuRenderer,
            "内核没有弹幕渲染器时必须强制 overlay，不能听偏好"
        )
    }

    /// 选择失效时设置页要能显示「回退了」，而且播放照样能开。
    func testStaleSelectionSurfacesToSettingsAndStillResolves() {
        PlaybackEngineAssembly.registerAll()
        PlaybackEngineRegistry.select("mpv-that-does-not-exist")

        XCTAssertTrue(PlaybackEngineRegistry.selectionIsStale)
        XCTAssertEqual(PlaybackEngineRegistry.selected?.id, "erika",
                       "失效选择要静默回退到第一个可用内核")
        XCTAssertNoThrow(try PlaybackEngineRegistry.makeSelected())
    }
}

/// 只声明「没有内核弹幕」的最小引擎：其余弹幕方法由 `PlaybackEngine` 协议扩展兜住，
/// 这里一行都不用写——这正是新适配器该有的成本。
private final class NoDanmakuEngine: PlaybackEngine, @unchecked Sendable {
    static let descriptor = PlaybackEngineDescriptor(
        id: "no-danmaku-stub",
        displayName: "Stub",
        summary: "测试替身：没有内核弹幕",
        supportsKernelDanmaku: false
    )

    let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    init() {
        var sink: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { sink = $0 }
        continuation = sink
    }
    deinit { continuation.finish() }

    var latestMediaTime: Duration { .zero }
    var latestStats: PlaybackStats { PlaybackStats() }

    @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }

    func open(_ source: PlaybackSource) throws {}
    func play() throws {}
    func pause() throws {}
    func stop() throws {}
    func seek(to position: Duration) throws {}
    func setRate(_ rate: Double) throws {}
    func setVolume(_ volume: Double) throws {}
    func tracks() throws -> [TrackInfo] { [] }
    func selectAudioTrack(_ id: Int64) throws {}
    func selectSubtitleTrack(_ id: Int64?) throws {}
    func addExternalSubtitle(_ uri: String) throws -> Int64 { 0 }
    func setSubtitleScale(_ scale: Double) throws {}
    func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }
}
