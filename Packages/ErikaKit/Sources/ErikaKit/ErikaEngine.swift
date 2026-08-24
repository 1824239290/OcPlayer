import CErika
import DiagnosticsKit
import Foundation
import PlaybackKit
import QuartzCore
import SwiftUI

/// Erika 内核适配器：`PlaybackEngine` 的第一个实现。
///
/// **锁契约**（改这个文件前先读）：
/// - 内核句柄没有内部同步，所以**每一次** C 调用都必须握着 `lock`。
/// - 渲染线程（`RenderLoop`）每帧：加锁 → `render_tick(绝对呈现时间)` → 把 `poll_event` 抽干 → 解锁，
///   事件**出锁之后**才投递给 `events`，避免在锁内回调用户代码造成死锁。
/// - UI 侧的 open / play / seek / 改配置都是短暂加同一把锁后直接调，因此和 tick 天然串行。
/// - 不用 `actor`：actor 的执行器无法保证落在显示线程上，反而多跳一次。
///
/// 这套串行化是 **Erika 特有的**，不是 `PlaybackEngine` 的要求：换成 libmpv 这类
/// 本身线程安全的内核时，适配器不需要任何锁。
public final class ErikaEngine: PlaybackEngine, @unchecked Sendable {

    // MARK: - PlaybackEngine 身份

    public static let descriptor = PlaybackEngineDescriptor(
        id: "erika",
        displayName: "Erika",
        summary: "Rust · FFmpeg · libass · Metal",
        supportsKernelDanmaku: true,
        // 别在这里重复弹幕开关自己的说明——设置页两行紧挨着，会读成同一句话说两遍。
        notes: "宿主驱动渲染：CAMetalLayer + CADisplayLink，画面由 App 逐帧驱动。"
            + "MPL-2.0，静态链接 LGPL 的 FFmpeg / libass。"
    )

    public static let supportsKernelDanmaku = true

    private let lock = NSLock()
    private let presenter: ErikaPresenter
    private let renderLoop: RenderLoop
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    /// 内核事件流。多处消费请各自 `for await`，此流为单播 —— 由 `PlayerState` 独占更省心。
    public let events: AsyncStream<PlayerEvent>

    /// 中立统计快照（`PlaybackEngine` 要求），UI 侧可随时读。
    public var latestStats: PlaybackStats { withLock { PlaybackStats(_latestStats) } }

    /// Erika 原始统计（HDR / 音频恢复 / 升采样等中立结构体不带的细项）。
    /// 需要这些字段时 downcast 到 `ErikaEngine` 再读。
    public var latestErikaStats: ErikaPresenterStats { withLock { _latestStats } }
    private var _latestStats = ErikaPresenterStats()

    /// 最近一次内核内存分项快照（渲染线程每 10s 采样，任意线程可读）。
    /// 两条弹幕路线共用：2G 峰值和 overlay 缓慢爬升分别落在哪些分项，看它的趋势。
    public var latestMemory: ErikaMemorySnapshot { withLock { _latestMemory } }
    private var _latestMemory = ErikaMemorySnapshot()
    private static let memorySampleIntervalSeconds: Double = 5
    /// 只被渲染线程写；初始 `-.infinity` 让第一帧 tick 先采一条当基线。
    private var lastMemorySampleAt = -Double.infinity
    /// 采样失败只报一次，避免逐帧刷屏。
    private var memorySampleFailed = false

    /// 最近一次内核 position 事件的媒体时间（渲染线程写、任意线程读）。
    /// 弹幕 overlay 用自己的采样时钟读它决定「谁该出场」：暂停/缓冲时内核
    /// 媒体时间冻结，采样值跟着冻结——语义与内核内嵌弹幕的时间契约一致。
    ///
    /// ⚠️ 用独立小锁而不是引擎主锁：主锁每帧被渲染线程的 renderTick 长持，
    /// UI 若按主锁读（overlay 30Hz 采样），会与渲染帧抢锁——读一次可能阻塞
    /// 到一整个 renderTick，渲染线程也可能被 UI 侧拖延，表现为视频掉帧。
    public var latestMediaTime: Duration {
        mediaTimeLock.lock()
        defer { mediaTimeLock.unlock() }
        return .microseconds(_latestMediaTimeMicros)
    }
    private let mediaTimeLock = NSLock()
    private var _latestMediaTimeMicros: Int64 = 0

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

    /// `PlaybackEngine` 的画面边界：交出整个视图，attach / resize / detach / 帧驱动
    /// 全部藏在 `VideoSurfaceView` 内部。调用方按引擎身份给它 `.id(...)`。
    @MainActor
    public func makeSurfaceView() -> AnyView {
        AnyView(VideoSurfaceView(engine: self))
    }

    /// 挂上 `CAMetalLayer` 并启动帧驱动。主线程调用。
    /// 尺寸传**物理像素**，`scale` 传 backingScaleFactor / contentsScale。
    @MainActor
    func attach(to view: PlatformView, layer: CAMetalLayer,
                pixelWidth: Int, pixelHeight: Int, scale: Double) throws {
        let raw = UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        do {
            try withLock {
                try presenter.attachMetalLayer(raw, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
            }
        } catch {
            // attach 失败（显卡 / 缺内核）会一路黑屏，这里补一条错误事件让 UI 有落点。
            PlaybackLog.error("attach 失败 size=\(pixelWidth)x\(pixelHeight) scale=\(scale) error=\(error)")
            continuation.yield(.failed(code: (error as? ErikaError).map { Int32(bitPattern: $0.status.rawValue) } ?? 0,
                                       message: "画面挂载失败：\(error)"))
            throw error
        }
        PlaybackLog.append("attach 成功 size=\(pixelWidth)x\(pixelHeight) scale=\(scale)")
        renderLoop.start(on: view)
    }

    /// 尺寸 / DPI 变化。内部保证在下一次 tick 之前生效（同一把锁）。
    func resize(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        try? withLock {
            try presenter.resizeSurface(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
        }
    }

    /// 先停帧驱动（等线程退出），再 detach —— 顺序反了就是随机崩。
    func detach() {
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
            try withLock {
                try presenter.open(source)
                // 基线快照：open 一结束先采一条，尖峰若发生在打开瞬间也能留下第一现场。
                sampleMemoryAt(reason: "open")
            }
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
            try withLock {
                try presenter.stop()
                // 收尾快照：对比 open/停止前各分项，看释放路径该清的是否清干净。
                sampleMemoryAt(reason: "stop")
            }
            PlaybackLog.append("stop() 成功")
        } catch {
            PlaybackLog.append("stop() 失败 error=\(error)")
            throw error
        }
        // stop 后 5s 的进程基线采样：量化「播放结束内存有没有完全归还系统」。
        // 跨集连播时若基线逐次抬高，就是媒体读取缓冲跨播放残留。独立 Task 只读
        // 进程内存，不持锁、不摸内核句柄，stop 后照常跑。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            let fp = ProcessFootprint.current()
            PlaybackLog.info("停止后基线 \(fp.summaryLine)", fields: fp.logFields)
        }
    }

    /// ⚠️ **Erika 独有，且是终态**：同一 presenter `close()` 之后再 `open()` 抛
    /// `ErikaError "player is closed"`。故意**不在** `PlaybackEngine` 协议里——
    /// 把一个内核的地雷抽象出来只会让所有内核都带上它。
    /// App 层换片 / 退出一律走 `stop()` + 丢弃引擎重建。
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

    /// 没有画面（窗口隐藏 / 纯音频推进）时的帧驱动。Erika 独有：
    /// 宿主驱动帧的内核才需要这个，App 层目前没有用到。
    @discardableResult
    public func audioOnlyTick() throws -> ErikaPresenterStats {
        try withLock { try presenter.audioOnlyTick() }
    }

    // MARK: - 轨道与字幕

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

    /// 字幕整体缩放（1.0 = 默认字号；HUD 的「字号 +/-」用）。
    public func setSubtitleScale(_ scale: Double) throws {
        try withLock { try ErikaError.check(erika_presenter_set_subtitle_scale(presenter.handle, scale)) }
    }

    // MARK: - 截图

    /// 离屏截当前合成帧（视频 + 字幕），RGBA8，尺寸传视频物理分辨率。
    public func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] {
        try withLock { try presenter.captureFrameRGBA(width: width, height: height) }
    }

    // MARK: - 内核内置弹幕（DFM+）

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

    // MARK: - 内部

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// 采样内核内存分项 + 进程 footprint 并打一条 info 日志。**调用方必须已持有 `lock`**（要摸 presenter）。
    /// 采样失败只报一次——通常意味着该能力在某版本不可用，不该逐帧刷屏。
    private func sampleMemoryAt(reason: String) {
        do {
            let snapshot = ErikaMemorySnapshot(try presenter.resourceStatus())
            let process = ProcessFootprint.current()
            _latestMemory = snapshot
            memorySampleFailed = false
            var fields = snapshot.logFields
            for (key, value) in process.logFields { fields[key] = value }
            PlaybackLog.info(
                "内核内存 reason=\(reason) \(snapshot.summaryLine) · \(process.summaryLine)",
                fields: fields
            )
        } catch {
            if !memorySampleFailed {
                memorySampleFailed = true
                PlaybackLog.error("内核内存采样失败 error=\(error)")
            }
        }
    }

    /// 播放页调试行：默认帧计数行下追加一行内核内存分项（HUD TimelineView 每秒重读）。
    public func debugStatsLine() -> String {
        let s = latestStats
        let m = latestMemory
        let p = ProcessFootprint.current()
        return """
        解码 \(s.decodedVideoFrames) · 渲染 \(s.renderedVideoFrames) · \
        硬解 \(s.hardwareVideoFrames) · 软解 \(s.softwareVideoFrames) · \
        零拷贝 \(s.zeroCopyVideoFrames) · 音频 \(s.pushedAudioFrames) · \
        渲染失败 \(s.renderFailures) · 音频失败 \(s.audioFailures)\n\
        内核内存 \(m.summaryLine)\n\
        \(p.summaryLine)
        """
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
            // 每 10s 采一次内核内存，渲染线程时间基准，形成整段播放的内存时间线。
            if presentationTime - lastMemorySampleAt >= Self.memorySampleIntervalSeconds {
                lastMemorySampleAt = presentationTime
                sampleMemoryAt(reason: "tick")
            }
        } catch let error as ErikaError {
            PlaybackLog.error("render_tick 失败 error=\(error)", throttle: Self.renderThrottle)
            pending.append(.failed(code: Int32(bitPattern: error.status.rawValue), message: error.message))
        } catch {
            PlaybackLog.error("render_tick 失败（未知） error=\(error)", throttle: Self.renderThrottle)
            pending.append(.failed(code: 0, message: "\(error)"))
        }
        // 事件是轮询模型：每帧抽干，不然会积压。
        while true {
            do {
                guard let event = try presenter.pollEvent() else { break }
                if case .positionChanged(let value) = event {
                    mediaTimeLock.lock()
                    _latestMediaTimeMicros = value.microseconds
                    mediaTimeLock.unlock()
                }
                pending.append(event)
            } catch let error as ErikaError {
                PlaybackLog.error("poll_event 失败 error=\(error)")
                pending.append(.failed(code: Int32(bitPattern: error.status.rawValue), message: error.message))
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
