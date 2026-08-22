import CErika
import DiagnosticsKit
import Foundation
import QuartzCore

/// 唯一对外的播放引擎。
///
/// **锁契约**（改这个文件前先读）：
/// - 内核句柄没有内部同步，所以**每一次** C 调用都必须握着 `lock`。
/// - 渲染线程（`RenderLoop`）每帧：加锁 → `render_tick(绝对呈现时间)` → 把 `poll_event` 抽干 → 解锁，
///   事件**出锁之后**才投递给 `events`，避免在锁内回调用户代码造成死锁。
/// - UI 侧的 open / play / seek / 改配置都是短暂加同一把锁后直接调，因此和 tick 天然串行。
/// - 不用 `actor`：actor 的执行器无法保证落在显示线程上，反而多跳一次。
public final class ErikaEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let presenter: ErikaPresenter
    private let renderLoop: RenderLoop
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    /// 内核事件流。多处消费请各自 `for await`，此流为单播 —— 由 `PlayerState` 独占更省心。
    public let events: AsyncStream<PlayerEvent>

    /// 最近一次 tick 的统计快照，UI 侧可随时读。
    public var latestStats: ErikaPresenterStats { withLock { _latestStats } }
    private var _latestStats = ErikaPresenterStats()

    /// 最近一次内核 position 事件的媒体时间（渲染线程写、任意线程读）。
    /// 弹幕 overlay 用自己的采样时钟读它决定「谁该出场」：暂停/缓冲时内核
    /// 媒体时间冻结，采样值跟着冻结——语义与内核内嵌弹幕的时间契约一致。
    public var latestMediaTime: Duration { withLock { _latestMediaTime } }
    private var _latestMediaTime: Duration = .zero

    public init(outputMode: ErikaPresenterOutputMode = ErikaPresenterOutputMode_Auto,
                edrHeadroom: Float = 0,
                upscaler: ErikaLumaUpscalerMode = ErikaLumaUpscalerMode_Off) throws {
        presenter = try ErikaPresenter(outputMode: outputMode, edrHeadroom: edrHeadroom, upscaler: upscaler)
        var sink: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
        continuation = sink
        renderLoop = RenderLoop()
        // 所有存储属性就位之后才能捕获 self；用 weak 断开 engine → renderLoop → engine 的环。
        renderLoop.onTick = { [weak self] time in self?.step(presentationTime: time) }
        PlaybackLog.append("ErikaEngine init")
    }

    deinit {
        renderLoop.stop()
        continuation.finish()
    }

    // MARK: - 画面承载

    /// 挂上 `CAMetalLayer` 并启动帧驱动。主线程调用。
    /// 尺寸传**物理像素**，`scale` 传 backingScaleFactor / contentsScale。
    @MainActor
    public func attach(to view: PlatformView, layer: CAMetalLayer,
                       pixelWidth: Int, pixelHeight: Int, scale: Double) throws {
        let raw = UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        do {
            try withLock {
                try presenter.attachMetalLayer(raw, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
            }
        } catch {
            // attach 失败（显卡 / 缺内核）会一路黑屏，这里补一条错误事件让 UI 有落点。
            PlaybackLog.error("attach 失败 size=\(pixelWidth)x\(pixelHeight) scale=\(scale) error=\(error)")
            continuation.yield(.failed(status: (error as? ErikaError)?.status ?? ErikaStatus_PlayerError,
                                       message: "画面挂载失败：\(error)"))
            throw error
        }
        PlaybackLog.append("attach 成功 size=\(pixelWidth)x\(pixelHeight) scale=\(scale)")
        renderLoop.start(on: view)
    }

    /// 尺寸 / DPI 变化。内部保证在下一次 tick 之前生效（同一把锁）。
    public func resize(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        try? withLock {
            try presenter.resizeSurface(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
        }
    }

    /// 先停帧驱动（等线程退出），再 detach —— 顺序反了就是随机崩。
    public func detach() {
        PlaybackLog.append("detach surface")
        renderLoop.stop()
        do {
            try withLock { try presenter.detachSurface() }
            PlaybackLog.append("detach surface 成功")
        } catch {
            PlaybackLog.error("detach surface 失败 error=\(error)")
        }
    }

    // MARK: - 播放控制

    public func open(_ source: PlaybackSource) throws {
        PlaybackLog.append("open() 开始")
        do {
            try withLock { try presenter.open(source) }
            PlaybackLog.append("open() 成功")
        } catch {
            PlaybackLog.error("open() 失败 error=\(error)")
            throw error
        }
    }

    public func play() throws {
        do {
            try withLock { try presenter.play() }
            PlaybackLog.append("play() 成功")
        } catch {
            PlaybackLog.append("play() 失败 error=\(error)")
            throw error
        }
    }

    public func pause() throws {
        do {
            try withLock { try presenter.pause() }
            PlaybackLog.append("pause() 成功")
        } catch {
            PlaybackLog.append("pause() 失败 error=\(error)")
            throw error
        }
    }

    public func stop() throws {
        PlaybackLog.append("stop() 开始")
        do {
            try withLock { try presenter.stop() }
            PlaybackLog.append("stop() 成功")
        } catch {
            PlaybackLog.append("stop() 失败 error=\(error)")
            throw error
        }
    }

    public func close() throws {
        PlaybackLog.append("close() 开始")
        do {
            try withLock { try presenter.close() }
            PlaybackLog.append("close() 成功")
        } catch {
            PlaybackLog.append("close() 失败 error=\(error)")
            throw error
        }
    }
    public func seek(to position: Duration) throws { try withLock { try presenter.seek(to: position) } }
    public func setRate(_ rate: Double) throws { try withLock { try presenter.setRate(rate) } }
    public func setVolume(_ volume: Double) throws { try withLock { try presenter.setVolume(volume) } }

    public func stats() throws -> ErikaPresenterStats {
        try withLock { try presenter.stats() }
    }

    /// 没有画面（窗口隐藏 / 纯音频推进）时的帧驱动。
    @discardableResult
    public func audioOnlyTick() throws -> ErikaPresenterStats {
        try withLock { try presenter.audioOnlyTick() }
    }

    public func tracks() throws -> [TrackInfo] {
        try withLock { try presenter.tracks() }
    }

    public func selectAudioTrack(_ id: Int64) throws {
        try withLock { try presenter.selectAudioTrack(id) }
    }

    public func selectSubtitleTrack(_ id: Int64?) throws {
        try withLock { try presenter.selectSubtitleTrack(id) }
    }

    /// 外挂字幕（本地路径 / URL），返回新轨道 id。
    @discardableResult
    public func addExternalSubtitle(_ uri: String) throws -> Int64 {
        try withLock { try presenter.addExternalSubtitle(uri) }
    }

    // MARK: - Danmaku

    /// Replace all current danmaku with one anonymous Bilibili XML source.
    public func loadDanmaku(fileURI: String) throws {
        try withLock { try presenter.loadDanmaku(fileURI: fileURI) }
    }

    /// Replace all current danmaku with one anonymous inline JSON source.
    public func loadDanmaku(json: String) throws {
        try withLock { try presenter.loadDanmaku(json: json) }
    }

    @discardableResult
    public func addDanmakuTrack(
        fileURI: String,
        name: String,
        offset: Duration = .zero
    ) throws -> UInt64 {
        try withLock {
            try presenter.addDanmakuTrack(fileURI: fileURI, name: name, offset: offset)
        }
    }

    @discardableResult
    public func addDanmakuTrack(
        json: String,
        name: String,
        offset: Duration = .zero
    ) throws -> UInt64 {
        try withLock {
            try presenter.addDanmakuTrack(json: json, name: name, offset: offset)
        }
    }

    public func removeDanmakuTrack(_ id: UInt64) throws {
        try withLock { try presenter.removeDanmakuTrack(id) }
    }

    public func setDanmakuTrack(_ id: UInt64, enabled: Bool) throws {
        try withLock { try presenter.setDanmakuTrack(id, enabled: enabled) }
    }

    public func setDanmakuTrack(_ id: UInt64, offset: Duration) throws {
        try withLock { try presenter.setDanmakuTrack(id, offset: offset) }
    }

    public func setDanmakuGlobalOffset(_ offset: Duration) throws {
        try withLock { try presenter.setDanmakuGlobalOffset(offset) }
    }

    public func danmakuTracks() throws -> [DanmakuTrackInfo] {
        try withLock { try presenter.danmakuTracks() }
    }

    public func clearDanmaku() throws {
        try withLock { try presenter.clearDanmaku() }
    }

    public func setDanmakuEnabled(_ enabled: Bool) throws {
        try withLock { try presenter.setDanmakuEnabled(enabled) }
    }

    public func danmakuConfig() throws -> DanmakuConfig {
        try withLock { try presenter.danmakuConfig() }
    }

    public func setDanmakuConfig(_ config: DanmakuConfig) throws {
        try withLock { try presenter.setDanmakuConfig(config) }
    }

    public func setDanmakuFont(family: String?, filePath: String?) throws {
        try withLock { try presenter.setDanmakuFont(family: family, filePath: filePath) }
    }

    public func setDanmakuBlockWords(json: String) throws {
        try withLock { try presenter.setDanmakuBlockWords(json: json) }
    }

    /// 字幕整体缩放（1.0 = 默认字号；HUD 的「字号 +/-」用）。
    public func setSubtitleScale(_ scale: Double) throws {
        try withLock { try ErikaError.check(erika_presenter_set_subtitle_scale(presenter.handle, scale)) }
    }

    /// 离屏截当前合成帧（视频 + 字幕），RGBA8，尺寸传视频物理分辨率。
    public func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] {
        try withLock { try presenter.captureFrameRGBA(width: width, height: height) }
    }

    // MARK: - 内部

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// 渲染线程每帧一次。失败在故障期间会逐帧触发，日志走 1s 节流，
    /// 只留下首条 + flush 时的一条汇总。
    private static let renderThrottle = DiagnosticThrottle(key: "render-failure", interval: 1)

    /// 渲染线程每帧一次。
    private func step(presentationTime: Double) {
        var pending: [PlayerEvent] = []

        lock.lock()
        do {
            _latestStats = try presenter.renderTick(at: presentationTime)
        } catch let error as ErikaError {
            PlaybackLog.error("render_tick 失败 error=\(error)", throttle: Self.renderThrottle)
            pending.append(.failed(status: error.status, message: error.message))
        } catch {
            PlaybackLog.error("render_tick 失败（未知） error=\(error)", throttle: Self.renderThrottle)
            pending.append(.failed(status: ErikaStatus_PlayerError, message: "\(error)"))
        }
        // 事件是轮询模型：每帧抽干，不然会积压。
        while true {
            do {
                guard let event = try presenter.pollEvent() else { break }
                if case .positionChanged(let value) = event { _latestMediaTime = value }
                pending.append(event)
            } catch let error as ErikaError {
                PlaybackLog.error("poll_event 失败 error=\(error)")
                pending.append(.failed(status: error.status, message: error.message))
                break
            } catch {
                PlaybackLog.error("poll_event 失败（未知） error=\(error)")
                break
            }
        }
        lock.unlock()

        for event in pending {
            // 暂停时降帧：在这里改是因为 step() 就跑在渲染线程上，而 CADisplayLink
            // 只能在自己的 runloop 线程上安全改动。
            if case .stateChanged(let value) = event {
                renderLoop.setPaused(value == .paused)
            }
            continuation.yield(event)
        }
    }
}
