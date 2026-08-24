import Foundation
import SwiftUI
@testable import PlaybackKit

/// 一个不解码任何东西的内核替身。
///
/// 存在的意义有两层：
/// 1. 让 `PlayerState` / 注册表的语义测试离线、毫秒级跑完（真内核测试留在各适配器包里）；
/// 2. **它就是「新增一个内核适配器要实现多少东西」的度量衡**——如果哪天有人往
///    `PlaybackEngine` 里加了一个不该加的方法，这个类会第一个变长。
///
/// 刻意**不**实现内核弹幕那一组：`supportsKernelDanmaku` 默认 false，
/// 协议扩展的空实现顶上。这正是新适配器该有的样子。
final class FakePlaybackEngine: PlaybackEngine, @unchecked Sendable {
    static let descriptor = PlaybackEngineDescriptor(
        id: "fake",
        displayName: "Fake",
        summary: "测试替身",
        supportsKernelDanmaku: false
    )

    let events: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    private let lock = NSLock()
    private var _latestMediaTime: Duration = .zero
    private var _latestStats = PlaybackStats()
    private var _tracks: [TrackInfo] = []

    /// 记录收到的调用，断言用。
    private(set) var openedSources: [PlaybackSource] = []
    private(set) var selectedSubtitleIDs: [Int64?] = []

    init(tracks: [TrackInfo] = []) {
        var sink: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
        continuation = sink
        _tracks = tracks
    }

    deinit { continuation.finish() }

    var latestMediaTime: Duration { lock.withLock { _latestMediaTime } }
    var latestStats: PlaybackStats { lock.withLock { _latestStats } }

    @MainActor func makeSurfaceView() -> AnyView { AnyView(Color.black) }

    func open(_ source: PlaybackSource) throws {
        lock.withLock { openedSources.append(source) }
    }
    func play() throws {}
    func pause() throws {}
    func stop() throws {}
    func seek(to position: Duration) throws {}
    func setRate(_ rate: Double) throws {}
    func setVolume(_ volume: Double) throws {}

    func tracks() throws -> [TrackInfo] { lock.withLock { _tracks } }
    func selectAudioTrack(_ id: Int64) throws {}
    func selectSubtitleTrack(_ id: Int64?) throws {
        lock.withLock { selectedSubtitleIDs.append(id) }
    }
    func addExternalSubtitle(_ uri: String) throws -> Int64 { 0 }
    func setSubtitleScale(_ scale: Double) throws {}

    func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] {
        [UInt8](repeating: 0, count: width * height * 4)
    }

    // MARK: - 测试驱动

    /// 推一条事件给消费者。
    func emit(_ event: PlayerEvent) {
        if case .positionChanged(let value) = event {
            lock.withLock { _latestMediaTime = value }
        }
        continuation.yield(event)
    }

    func setStats(_ stats: PlaybackStats) {
        lock.withLock { _latestStats = stats }
    }

    func setTracks(_ tracks: [TrackInfo]) {
        lock.withLock { _tracks = tracks }
    }
}

extension TrackInfo {
    /// 测试用的轨道构造快捷方式。
    static func stub(
        id: Int64,
        kind: Kind,
        source: Source = .embedded,
        selected: Bool = false,
        title: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        channels: Int? = nil
    ) -> TrackInfo {
        TrackInfo(
            id: id,
            kind: kind,
            source: source,
            selected: selected,
            title: title,
            language: language,
            codec: codec,
            channels: channels,
            sampleRate: nil
        )
    }
}
