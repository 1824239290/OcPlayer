import DiagnosticsKit
import Foundation
import PlaybackKit
import SwiftUI
@testable import OcPlayer
import XCTest

/// 会话收尾的内核统计快照接线。
///
/// 关于「为什么值得一条测试」：`kernelDiagnosticsFields()` 里那一整块原始计数器
/// （26 个此前从没有任何读取点的字段）只有在**正确的位置**调用才有价值——内核
/// 自 v0.2.1 起在 `stop()` 时释放 HTTP 缓存与队列，快照落在 stop 之后就记录了
/// 一个已经被清过的现场。这里钉住调用顺序，而不是钉日志内容（读真实日志文件是
/// 进程级副作用，本套件刻意不碰）。
@MainActor
final class KernelDiagnosticsSnapshotTests: XCTestCase {

    /// 记录调用顺序的替身内核。
    private final class OrderRecordingEngine: PlaybackEngine, @unchecked Sendable {
        static let descriptor = PlaybackEngineDescriptor(
            id: "kernel-diagnostics-fake",
            displayName: "KernelDiagnosticsFake",
            summary: "测试替身",
            supportsKernelDanmaku: false
        )

        let events: AsyncStream<PlayerEvent>
        private let continuation: AsyncStream<PlayerEvent>.Continuation
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _fields: [String: DiagnosticValue] = ["decoded_video_frames": .unsignedInteger(7)]

        var latestMediaTime: Duration { .zero }
        var latestStats: PlaybackStats { PlaybackStats() }

        init(fields: [String: DiagnosticValue] = ["decoded_video_frames": .unsignedInteger(7)]) {
            var sink: AsyncStream<PlayerEvent>.Continuation!
            events = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { sink = $0 }
            continuation = sink
            _fields = fields
        }

        deinit { continuation.finish() }

        var calls: [String] { lock.withLock { _calls } }

        private func record(_ name: String) { lock.withLock { _calls.append(name) } }

        @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }

        func open(_ source: PlaybackSource) throws { record("open") }
        func play() throws { record("play") }
        func pause() throws { record("pause") }
        func stop() throws { record("stop") }
        func seek(to position: Duration) throws { record("seek") }
        func setRate(_ rate: Double) throws {}
        func setVolume(_ volume: Double) throws {}
        func tracks() throws -> [TrackInfo] { [] }
        func selectAudioTrack(_ id: Int64) throws {}
        func selectSubtitleTrack(_ id: Int64?) throws {}
        @discardableResult func addExternalSubtitle(_ uri: String) throws -> Int64 { -1 }
        func setSubtitleScale(_ scale: Double) throws {}
        func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] { [] }

        func kernelDiagnosticsFields() -> [String: DiagnosticValue] {
            record("diagnostics")
            return lock.withLock { _fields }
        }
    }

    private var savedEngineSelection: String?

    override func setUp() async throws {
        try await super.setUp()
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
        PlaybackEngineAssembly.registerAll()
        super.tearDown()
    }

    private func makeController(
        fields: [String: DiagnosticValue] = ["decoded_video_frames": .unsignedInteger(7)]
    ) -> (PlaybackController, OrderRecordingEngine) {
        let engine = OrderRecordingEngine(fields: fields)
        PlaybackEngineRegistry.register(OrderRecordingEngine.descriptor) { engine }
        let controller = PlaybackController()
        XCTAssertNotNil(controller.prepareEngine(), "替身内核应能创建")
        return (controller, engine)
    }

    /// 快照必须在 `stop()` **之前**采：stop 之后内核已经释放了缓存与队列。
    func testSnapshotIsTakenBeforeStop() {
        let (controller, engine) = makeController()

        controller.stopPlayback()

        XCTAssertEqual(
            engine.calls, ["diagnostics", "stop"],
            "统计快照必须落在 stop 之前，否则记的是已经被清过的现场"
        )
    }

    /// 引擎不提供诊断字段（非 Erika / 未来内核）：`logKernelDiagnosticsSnapshot`
    /// 会跳过这条日志（空字典不打），但收尾流程照常走完——不能因为一个可选的
    /// 诊断能力缺失就影响 stop。
    func testEmptyDiagnosticsFieldsDoNotBlockStop() {
        let (controller, engine) = makeController(fields: [:])

        controller.stopPlayback()

        XCTAssertEqual(engine.calls, ["diagnostics", "stop"], "空字段也要照常收尾")
    }
}
