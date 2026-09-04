import CErika
import DiagnosticsKit
import Foundation
import PlaybackKit
import QuartzCore
import SwiftUI

/// Erika 内核适配器：`PlaybackEngine` 的第一个实现。
///
/// **锁契约**（改这个文件前先读）：
/// - 内核句柄没有内部同步，所以**每一次** C 调用都必须握着 `lock`（下称**主锁**）。
/// - 渲染线程（`RenderLoop`）每帧：加主锁 → `render_tick(绝对呈现时间)` → 把 `poll_event` 抽干 → 解锁，
///   事件**出锁之后**才投递给 `events`，避免在锁内回调用户代码造成死锁。
/// - **open 是唯一的长持主锁调用**：内核在调用线程上同步完成网络连接与格式探测，
///   弱网下可达数十秒。因此 open 期间其余入口走**让位契约**（见 `yieldLock` 一节）：
///   UI 侧的 stop / detach / resize 只登记意图立即返回，由 open 收尾在 open 线程补做；
///   play / pause / seek / 改速率音量在 open 期间直接丢弃（那时没有媒体内容，操作无意义）。
///   open 本身因此必须由宿主安排在**非主线程**执行，否则上述让位救不了主线程。
/// - 统计快照（`latestStats` / `latestMemory`）走独立的 `statsLock`：UI 会以 10Hz 轮询
///   首帧标志，绝不能让这些读撞上 open 的长持锁（先例：`mediaTimeLock`）。
/// - 不用 `actor`：actor 的执行器无法保证落在显示线程上，反而多跳一次。
///
/// 这套串行化是 **Erika 特有的**，不是 `PlaybackEngine` 的要求：换成
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

    // MARK: open 让位契约（改 open / stop / detach 前先读）

    /// open 长持主锁期间的让位状态。**独立小锁，绝不与主锁嵌套获取**——
    /// 让位路径的全部意义就是在这段时间不碰主锁。
    private let yieldLock = NSLock()
    /// open 在飞（`open()` 进入到收尾之间）。读方是 UI 线程的让位入口。
    private var _isOpening = false
    /// open 期间有人请求过 stop：open 收尾在 open 线程补做。
    private var _pendingStop = false
    /// open 期间收到的 surface 操作（attach / resize / detach 后写胜出），
    /// open 收尾按最终意图补做一次。detach 与 attach/resize 互斥覆盖。
    private var _deferredSurface: DeferredSurfaceUpdate?
    /// open 收尾是否补做过让位的 stop / detach（即这次 open 的成果已被放弃）。
    /// 宿主用它决定是否跳过后续的 play / 参数设置（stop 之后 play 会重头播）。
    private var _openingInterrupted = false

/// open 期间登记的 surface 操作。
private struct DeferredSurfaceUpdate {
    enum Op {
        /// layer 已由视图创建，token 与几何一起延后交给内核。
        case attach(view: PlatformView, layerToken: UInt64)
        case resize
        case detach
    }
    let op: Op
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
}

/// Sendable 检查逃生舱：值本身只在单一执行环境（这里是主线程）访问，
/// 由调用点保证，盒子只为携带它跨过 Task 边界。
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

    // MARK: 统计快照（独立于主锁，UI 高频读）

    /// `_latestStats` / `_latestMemory` 的专用锁。写方：渲染线程（step / sampleMemoryAt）；
    /// 读方：UI 轮询与 HUD。与主锁的嵌套只允许「主锁 → statsLock」一个方向
    /// （渲染线程在主锁内写），反向无嵌套，无死锁环。
    private let statsLock = NSLock()

    /// 内核事件流。多处消费请各自 `for await`，此流为单播 —— 由 `PlayerState` 独占更省心。
    public let events: AsyncStream<PlayerEvent>

    /// 中立统计快照（`PlaybackEngine` 要求），UI 侧可随时读、不与 open 的长持锁竞争
    /// （loading 轮询以 10Hz 读首帧标志，走主锁会撞上 open）。
    public var latestStats: PlaybackStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return PlaybackStats(_latestStats)
    }

    /// Erika 原始统计（HDR / 音频恢复 / 升采样等中立结构体不带的细项）。
    /// 需要这些字段时 downcast 到 `ErikaEngine` 再读。
    public var latestErikaStats: ErikaPresenterStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _latestStats
    }
    private var _latestStats = ErikaPresenterStats()

    /// 最近一次内核内存分项快照（渲染线程每 5s 采样，任意线程可读）。
    /// 两条弹幕路线共用：2G 峰值和 overlay 缓慢爬升分别落在哪些分项，看它的趋势。
    public var latestMemory: ErikaMemorySnapshot {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _latestMemory
    }
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
    ///
    /// open 在飞时让位：只登记意图（后写胜出），由 open 收尾在 open 线程补
    /// `attach_metal_layer`，回主线程补 `renderLoop.start`。正常时序里 attach 发生在
    /// open 派发之前（视图先布局、`.task` 后跑），这条是防御 + attach 失败后的
    /// layout 重试落在 open 期间的兜底。
    @MainActor
    func attach(to view: PlatformView, layer: CAMetalLayer,
                pixelWidth: Int, pixelHeight: Int, scale: Double) throws {
        let raw = UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        if deferSurfaceDuringOpen(.attach(view: view, layerToken: raw),
                                  pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale) {
            return
        }
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
    /// 失败补节流日志：吞掉的话失败后画面停在旧 viewport（黑屏/拉伸），只有现象没有原因。
    ///
    /// open 在飞时让位：登记最终几何（后写胜出），open 收尾补做——否则拖窗口 /
    /// 全屏切换会从主线程撞上 open 的长持锁。
    func resize(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        if deferSurfaceDuringOpen(.resize,
                                  pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale) {
            return
        }
        do {
            try withLock {
                try presenter.resizeSurface(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
            }
        } catch {
            PlaybackLog.error("resize_surface 失败 size=\(pixelWidth)x\(pixelHeight) scale=\(scale) error=\(error)",
                              throttle: Self.resizeThrottle)
        }
    }

    /// 先停帧驱动（等线程退出），再 detach —— 顺序反了就是随机崩。
    /// 返回是否成功断开：失败时内核可能仍攥着 layer 的裸指针，调用方
    /// （MetalHostView）会记标志、在视图释放前再强制补断一次。
    ///
    /// open 在飞时让位：**连 `renderLoop.stop()` 都不做**——它会 join 正被 open
    /// 挡住的渲染线程（cancel 后仍要等 runloop 唤醒点），主线程一样会被拖住。
    /// 全部登记给 open 收尾补做。
    @discardableResult
    func detach() -> Bool {
        PlaybackLog.append("detach surface")
        if deferSurfaceDuringOpen(.detach, pixelWidth: 0, pixelHeight: 0, scale: 0) {
            return false
        }
        renderLoop.stop()
        do {
            try withLock { try presenter.detachSurface() }
            PlaybackLog.append("detach surface 成功")
            return true
        } catch {
            PlaybackLog.error("detach surface 失败 error=\(error)")
            return false
        }
    }

    // MARK: open 让位（yield）内部

    /// open 在飞时登记 surface 操作；返回 true 表示已登记（调用方立即返回，不碰主锁）。
    private func deferSurfaceDuringOpen(_ op: DeferredSurfaceUpdate.Op,
                                        pixelWidth: Int, pixelHeight: Int, scale: Double) -> Bool {
        yieldLock.lock()
        defer { yieldLock.unlock() }
        guard _isOpening else { return false }
        switch op {
        case .attach(let view, let layerToken):
            _deferredSurface = DeferredSurfaceUpdate(
                op: .attach(view: view, layerToken: layerToken),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: scale
            )
        case .resize:
            if let current = _deferredSurface, case .attach(let view, let layerToken) = current.op {
                // 关键修复：open 期间视图先 attach 再 layout 触发 resize，
                // 后续的 resize 必须继承已有的 view 和 layerToken，只更新几何尺寸，
                // 绝不能把 .attach 冲掉替换成纯 .resize！
                // 否则 view 和 layerToken 丢失，收尾无法挂载 layer 和启动渲染循环。
                _deferredSurface = DeferredSurfaceUpdate(
                    op: .attach(view: view, layerToken: layerToken),
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    scale: scale
                )
            } else {
                _deferredSurface = DeferredSurfaceUpdate(
                    op: .resize,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    scale: scale
                )
            }
        case .detach:
            _deferredSurface = DeferredSurfaceUpdate(
                op: .detach,
                pixelWidth: 0,
                pixelHeight: 0,
                scale: 0
            )
        }
        return true
    }

    /// open 进入时调用：清上一轮让位残留，置 opening 标志。
    /// internal 供测试驱动（无真实 open 的让位路径回归）。
    func markOpeningStarted() {
        yieldLock.lock()
        _isOpening = true
        _pendingStop = false
        _deferredSurface = nil
        _openingInterrupted = false
        yieldLock.unlock()
    }

    /// open 收尾（`open()` 的 defer，主锁之外）调用：清标志并补做让位登记的操作。
    /// 补做顺序 stop → surface，与正常路径 stopPlayback → detach 一致。
    /// internal 供测试驱动。
    func finishOpening() {
        var pendingStop = false
        var surface: DeferredSurfaceUpdate?
        yieldLock.lock()
        _isOpening = false
        pendingStop = _pendingStop
        surface = _deferredSurface
        _pendingStop = false
        _deferredSurface = nil
        // 只有 stop 与 surface 拆卸（detach）让位才视为中断：宿主跳过 play / 参数设置。
        // 兜底的 attach / resize（open 期间视图布局落在让位窗口内）是防御性补做，仍照常播放，
        // 若也计作中断会让宿主错过 play，Jellyfin 等慢源 open 结束后一直停在 loading。
        // `.attach` 带关联值不能 ==，用模式匹配判断是否拆卸让位。
        let interruptedBySurface: Bool
        if let s = surface, case .detach = s.op {
            interruptedBySurface = true
        } else {
            interruptedBySurface = false
        }
        _openingInterrupted = pendingStop || interruptedBySurface
        yieldLock.unlock()

        if pendingStop {
            PlaybackLog.append("open 让位收尾：补 stop")
            try? withLock { try presenter.stop() }
        }
        guard let surface else { return }
        switch surface.op {
        case .detach:
            PlaybackLog.append("open 让位收尾：补 detach")
            renderLoop.stop()
            try? withLock { try presenter.detachSurface() }
        case .resize:
            PlaybackLog.append("open 让位收尾：补 resize \(surface.pixelWidth)x\(surface.pixelHeight)")
            try? withLock {
                try presenter.resizeSurface(pixelWidth: surface.pixelWidth,
                                            pixelHeight: surface.pixelHeight, scale: surface.scale)
            }
        case .attach(let view, let layerToken):
            PlaybackLog.append("open 让位收尾：补 attach \(surface.pixelWidth)x\(surface.pixelHeight) scale=\(surface.scale)")
            do {
                try withLock {
                    try presenter.attachMetalLayer(layerToken, pixelWidth: surface.pixelWidth,
                                                   pixelHeight: surface.pixelHeight, scale: surface.scale)
                }
            } catch {
                PlaybackLog.error("open 让位收尾补 attach 失败 error=\(error)")
                continuation.yield(.failed(code: (error as? ErikaError).map { Int32(bitPattern: $0.status.rawValue) } ?? 0,
                                           message: "画面挂载失败：\(error)"))
                return
            }
            // renderLoop.start 要求主线程（要摸视图）。view / renderLoop 都不是
            // Sendable,但真实访问被 @MainActor 闭环限定,盒子只为过并发检查。
            let viewBox = UncheckedSendableBox(value: view)
            let loopBox = UncheckedSendableBox(value: renderLoop)
            Task { @MainActor in
                loopBox.value.start(on: viewBox.value)
            }
        }
    }

    private static let resizeThrottle = DiagnosticThrottle(key: "resize-surface", interval: 1)

    // MARK: - 播放控制

    /// 这次 open 收尾是否已把成果让位给 stop/detach（即 open 期间宿主请求过 stop
    /// 或 surface 拆卸）。宿主在 `open()` 返回后读取，决定要不要跳过 play / 参数设置
    /// ——内核 stop 之后 play 是合法的重播操作，跳过才不会让已放弃的源幽灵出声。
    public var openWasInterrupted: Bool {
        yieldLock.lock()
        defer { yieldLock.unlock() }
        return _openingInterrupted
    }

    public func open(_ source: PlaybackSource) throws {
        PlaybackLog.append("open() 开始")
        markOpeningStarted()
        defer { finishOpening() }
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
        if dropControlDuringOpen("play") { return }
        do {
            try withLock { try presenter.play() }
            PlaybackLog.append("play() 成功")
        } catch {
            PlaybackLog.append("play() 失败 error=\(error)")
            throw error
        }
    }

    public func pause() throws {
        if dropControlDuringOpen("pause") { return }
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
        if deferStopDuringOpen() { return }
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
        // 跨集连播时若基线逐次抬高，就是媒体读取缓冲跨播放残留。Task 刻意不捕获
        // self：引擎在 stop 后本来就该被宿主析构（weak self 到 5s 时必为 nil，
        // 基线一条都打不出来），而 footprint 是纯进程读数，不需要引擎活着。
        // 此处 relief 由宿主侧 MallocPressureRelief 负责，这里只留裸基线。
        Task {
            try? await Task.sleep(for: .seconds(5))
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

    /// open 期间丢弃播放控制（play/pause/seek/速率/音量）：此时还没有媒体内容，
    /// 操作无意义；不丢弃的话调用线程会撞上 open 的长持锁。
    private func dropControlDuringOpen(_ name: String) -> Bool {
        yieldLock.lock()
        defer { yieldLock.unlock() }
        guard _isOpening else { return false }
        PlaybackLog.append("open 在飞，丢弃 \(name)")
        return true
    }

    /// open 期间把 stop 登记给 open 收尾补做；返回 true 表示已登记。
    private func deferStopDuringOpen() -> Bool {
        yieldLock.lock()
        defer { yieldLock.unlock() }
        guard _isOpening else { return false }
        _pendingStop = true
        PlaybackLog.append("open 在飞，stop 让位登记")
        return true
    }

    public func seek(to position: Duration) throws {
        if dropControlDuringOpen("seek") { return }
        try withLock { try presenter.seek(to: position) }
    }
    public func setRate(_ rate: Double) throws {
        if dropControlDuringOpen("setRate") { return }
        try withLock { try presenter.setRate(rate) }
    }
    public func setVolume(_ volume: Double) throws {
        if dropControlDuringOpen("setVolume") { return }
        try withLock { try presenter.setVolume(volume) }
    }

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
            statsLock.lock()
            _latestMemory = snapshot
            statsLock.unlock()
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
            let stats = try presenter.renderTick(at: presentationTime)
            statsLock.lock()
            _latestStats = stats
            statsLock.unlock()            // 每 5s 采一次内核内存，渲染线程时间基准，形成整段播放的内存时间线。
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
        // 事件是轮询模型：每帧抽干，不然会积压。但每帧迭代要有上限——内核坏掉
        // 疯狂产事件时，锁内 while true 会把等这把锁的 UI 控制调用饿死；上限内
        // 抽不完的留给下一帧（poll 模型本来就能留）。
        var polled = 0
        while polled < Self.maxEventsPerFrame {
            polled += 1
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
            // 帧率档位跟随播放状态：paused 降帧 15-30（拖窗口/resize 仍要跟手）；
            // stopped/error 进 idle 档——tick 只剩事件轮询在跑，没必要全刷新率空转。
            // 在这里改是因为 step() 就跑在渲染线程上，CADisplayLink 只能在自己的
            // runloop 线程上安全改动。
            if case .stateChanged(let value) = event {
                renderLoop.setTier(Self.tier(for: value))
            }
            continuation.yield(event)
        }
    }

    /// 每帧事件抽干上限。正常播放每帧个位数事件，256 只是风暴时的保险丝。
    private static let maxEventsPerFrame = 256

    private static func tier(for state: PlaybackState) -> RenderLoop.RateTier {
        switch state {
        case .paused: .paused
        case .stopped, .error: .idle
        default: .active
        }
    }
}
