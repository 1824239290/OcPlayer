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
///   play / pause / seek / 改速率音量在 open 期间直接丢弃（那时没有媒体内容，操作无意义）；
///   其余全部入口（轨道 / 字幕 / 截图 / 弹幕 / 统计直查）同样让位——读方法返回默认值、
///   动作方法丢弃并记日志，任何主线程调用都不允许在 open 期间撞上主锁（7adb4be 之后
///   open 在飞时 UI 是活的，漏一处就是把弱网卡死从侧门放回来）。
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
        version: ErikaVersion.tag,
        summary: "Rust · FFmpeg · libass · Metal",
        supportsKernelDanmaku: true,
        // 别在这里重复弹幕开关自己的说明——设置页两行紧挨着，会读成同一句话说两遍。
        notes: "宿主驱动渲染：CAMetalLayer + CADisplayLink，画面由 App 逐帧驱动。"
            + "MPL-2.0，静态链接 LGPL 的 FFmpeg / libass。"
    )

    public static let supportsKernelDanmaku = true

    /// 内核支持字幕外观（`erika_presenter_set_subtitle_style`，v0.1.9 起）。
    /// 设置页按它决定要不要提示「当前内核不支持」。
    public static let supportsSubtitleStyle = true

    /// 内核内建后台播放通路：`audio_only_tick` 会挂起视频解码、只推进音频，
    /// 回前台第一次 `render_tick` 再 flush 解码器 + 回关键帧续上画面。
    public static let supportsBackgroundAudio = true

    private let lock = NSLock()
    private let presenter: ErikaPresenter
    private let renderLoop: RenderLoop
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    // MARK: 后台档位（改这块前先读 setBackgroundAudioOnly）

    /// 后台档位状态。独立小锁：渲染线程每帧要在**进主锁之前**判档位，
    /// 而切档发生在主线程，不能用主锁保护（主锁会被 open 长持）。
    private let backgroundLock = NSLock()
    private var _backgroundAudioOnly = false
    /// 后台档的音频推进定时器；非后台档时为 nil。
    private var backgroundTimer: DispatchSourceTimer?
    /// 定时器队列。**不能复用渲染线程**：那条线程跑的是 `CADisplayLink` 的 runloop，
    /// 后台没有 vsync，它跟着一起停摆。
    private static let backgroundQueueLabel = "dev.jumusu.OcPlayer.audio-only"
    private let backgroundQueue = DispatchQueue(
        label: ErikaEngine.backgroundQueueLabel,
        qos: .userInteractive
    )
    /// 已 attach 的承载视图（弱引用）。回前台要重启 `RenderLoop`，而
    /// `RenderLoop.start` 要摸视图（macOS 靠 `NSView.displayLink` 跟随所在显示器）。
    ///
    /// 槽位由 `backgroundLock` 保护，**不是**因为指针本身会被并发解引用，而是写方
    /// 分布在两个隔离域：`attach()` 在主线程，`detach()` 可能从视图的 `deinit` 过来
    /// （`MetalHostView` 的 deinit / teardown），读方是主 actor 上的重启路径。
    /// 与 `_deferredSurface` 存 `PlatformView` 是同一套处理：锁只保护槽位，
    /// 真正使用指针只在主 actor 里（`RenderLoop.start`）。
    private weak var _attachedView: PlatformView?

    private func storedAttachedView() -> PlatformView? {
        backgroundLock.lock()
        defer { backgroundLock.unlock() }
        // 出锁即转强引用：调用方拿到的视图不会被半路释放。
        return _attachedView
    }

    private func setAttachedView(_ view: PlatformView?) {
        backgroundLock.lock()
        _attachedView = view
        backgroundLock.unlock()
    }

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

    /// 内核当前实际生效的输出编码。信息面板的动态范围标注按它区分
    /// 「源是 HDR 但输出端映射成了 SDR」和「真的在出 HDR」。
    /// 直查型读入口，遵守 open 让位契约（open 在飞返回 `.unknown`，不撞长持锁）。
    public var latestOutputEncoding: PlaybackOutputEncoding {
        guard let status = currentOutputStatus() else { return .unknown }
        return Self.encoding(of: status)
    }

    /// 输出细节（面格式 / 回退原因 / 有效 headroom）。与 `latestOutputEncoding`
    /// 共用同一把锁与同一个 C 调用，同一帧里两个都读也不会调两次内核。
    public var latestOutputSnapshot: PlaybackOutputSnapshot {
        guard let status = currentOutputStatus() else { return .unknown }
        return PlaybackOutputSnapshot(status)
    }

    /// 直查型读入口的公共段：open 在飞让位（返回 nil，不撞长持锁），其余情况
    /// 持主锁取一次 `get_output_status`。
    private func currentOutputStatus() -> ErikaOutputStatus? {
        if dropControlDuringOpen("outputStatus") { return nil }
        return try? withLock { try presenter.outputStatus() }
    }

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

    /// 上次真正下发的 EDR headroom：屏参通知风暴（一次播放实测 3155 条同值记录）
    /// 里同值重复下发既白刷日志也白调内核，这里直接挡掉。
    private var lastPushedEDRHeadroom: Float?

    /// tick 内存采样的降噪基准：只有关键分项有实质变化才写日志
    /// （播放中每 5s 一条 = 1 小时片子多 ~700 行噪声，而真正要看的是趋势拐点）。
    private var lastLoggedTickMemory: ErikaMemorySnapshot?
    private static let memoryLogThresholdBytes: UInt64 = 8 * 1024 * 1024
    private static let memoryLogThresholdRatio: Double = 0.10
    /// 采样失败只报一次，避免逐帧刷屏。
    private var memorySampleFailed = false

    /// 上次记录过的输出状态。与内存采样同一个 5s 窗口，**只在变化时**写日志
    /// （输出状态是低频量：一次播放里通常只在起播与换屏时变，逐次记就是噪声）。
    /// 只被渲染线程访问（同 `lastMemorySampleAt`），不加锁。
    private var lastLoggedOutputStatus: ErikaOutputStatus?

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

    /// `positionChanged` 的发布闸门。**只由渲染线程访问**（`step` 是唯一消费者），
    /// 因此不加锁。见 `PositionPublishGate` 的类型注释。
    private var positionGate = PositionPublishGate()

    public init(outputMode: ErikaPresenterOutputMode = ErikaPresenterOutputMode_Auto,
                edrHeadroom: Float = 0,
                upscaler: PlaybackUpscalerMode = .off) throws {
        presenter = try ErikaPresenter(outputMode: outputMode, edrHeadroom: edrHeadroom, upscaler: upscaler)
        var sink: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
        continuation = sink
        renderLoop = RenderLoop()
        // 所有存储属性就位之后才能捕获 self；用 weak 断开 engine → renderLoop → engine 的环。
        renderLoop.onTick = { [weak self] time, delay in
            self?.step(presentationTime: time, presentationDelay: delay)
        }
        PlaybackLog.info("ErikaEngine init")
    }

    deinit {
        renderLoop.stop()
        // 后台档的定时器要显式取消：handler 虽是 weak self，但定时器本身会活到 cancel。
        stopBackgroundTimer()
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
        PlaybackLog.info("attach 成功 size=\(pixelWidth)x\(pixelHeight) scale=\(scale)")
        setAttachedView(view)
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
        PlaybackLog.info("detach surface")
        if deferSurfaceDuringOpen(.detach, pixelWidth: 0, pixelHeight: 0, scale: 0) {
            return false
        }
        renderLoop.stop()
        setAttachedView(nil)
        do {
            try withLock { try presenter.detachSurface() }
            PlaybackLog.info("detach surface 成功")
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
            PlaybackLog.info("open 让位收尾：补 stop")
            try? withLock { try presenter.stop() }
        }
        guard let surface else { return }
        switch surface.op {
        case .detach:
            PlaybackLog.info("open 让位收尾：补 detach")
            renderLoop.stop()
            try? withLock { try presenter.detachSurface() }
        case .resize:
            PlaybackLog.info("open 让位收尾：补 resize \(surface.pixelWidth)x\(surface.pixelHeight)")
            try? withLock {
                try presenter.resizeSurface(pixelWidth: surface.pixelWidth,
                                            pixelHeight: surface.pixelHeight, scale: surface.scale)
            }
        case .attach(let view, let layerToken):
            PlaybackLog.info("open 让位收尾：补 attach \(surface.pixelWidth)x\(surface.pixelHeight) scale=\(surface.scale)")
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
            setAttachedView(view)
            Task { @MainActor in
                loopBox.value.start(on: viewBox.value)
            }
        }
    }

    private static let resizeThrottle = DiagnosticThrottle(key: "resize-surface", interval: 1)

    // MARK: - 后台档位

    /// 进后台（`true`）/ 回前台（`false`）切换帧驱动。
    ///
    /// **为什么要切**：后台没有 vsync，`CADisplayLink` 不再回调；而进程靠
    /// `UIBackgroundModes: audio` + `.playback` 会话活着，必须有人继续推进音频，
    /// 否则几百毫秒后音频队列就饿了。切过去之后内核走 `audio_only_tick`，
    /// 它会挂起视频解码（`set_video_decode_suspended(true)`）并丢掉待解码帧——
    /// 回前台第一次 `render_tick` 再 flush 解码器 + 回关键帧续上。
    /// 这条通路是内核内建的，宿主只需要负责换驱动 + 保证 surface 还在。
    ///
    /// **顺序有讲究**：进档先停 `RenderLoop`（等渲染线程真正退出）再起定时器，
    /// 保证不会再有一次 `render_tick` 把刚挂起的解码解开；退档反着来。
    /// 两边都由 `step` 的档位闸门兜底，跨线程迟到的回调不会造成档位来回翻。
    ///
    /// 幂等：重复进/退档直接返回，不会反复重建定时器。
    public func setBackgroundAudioOnly(_ active: Bool) {
        backgroundLock.lock()
        guard _backgroundAudioOnly != active else {
            backgroundLock.unlock()
            return
        }
        _backgroundAudioOnly = active
        backgroundLock.unlock()

        if active {
            // 等渲染线程退出（内部最长等 1s），之后不会再有人调 render_tick。
            renderLoop.stop()
            startBackgroundTimer()
            PlaybackLog.info("进后台档：帧驱动交给定时器，内核将挂起视频解码")
        } else {
            stopBackgroundTimer()
            restartRenderLoop()
            PlaybackLog.info("退后台档：帧驱动交回 CADisplayLink，内核在渲染帧里恢复视频解码")
        }
    }

    private var isBackgroundAudioOnly: Bool {
        backgroundLock.lock()
        defer { backgroundLock.unlock() }
        return _backgroundAudioOnly
    }

    /// 后台档的音频推进：16ms 一拍（≈60Hz，与内核的音频泵一致）。
    /// leeway 给 4ms —— 后台不追求画面级时序，让系统有机会合并唤醒省电。
    private func startBackgroundTimer() {
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.step(presentationTime: CACurrentMediaTime(), audioOnly: true)
        }
        timer.resume()
        backgroundLock.lock()
        backgroundTimer = timer
        backgroundLock.unlock()
    }

    private func stopBackgroundTimer() {
        backgroundLock.lock()
        let timer = backgroundTimer
        backgroundTimer = nil
        backgroundLock.unlock()
        // cancel 是异步的：已经在跑的 handler 会走完，由 step 的档位闸门丢弃。
        timer?.cancel()
    }

    /// 回前台重启帧驱动。`RenderLoop.start` 要摸视图，只能在主线程做。
    /// 没有已挂载的 surface 时不重启——此时内核的 `try_resume_video_decode` 也会因为
    /// `surface_is_ready()` 不成立而保持挂起，等下一次 attach 自己把帧驱动带起来。
    private func restartRenderLoop() {
        guard let view = storedAttachedView() else {
            PlaybackLog.warning("退后台档时没有已挂载的 surface，帧驱动未重启")
            return
        }
        let viewBox = UncheckedSendableBox(value: view)
        Task { @MainActor in
            self.renderLoop.start(on: viewBox.value)
        }
    }

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
        PlaybackLog.info("open() 开始")
        markOpeningStarted()
        defer { finishOpening() }
        do {
            var snapshot: ErikaMemorySnapshot?
            try withLock {
                try presenter.open(source)
                // 基线快照：open 一结束先采一条，尖峰若发生在打开瞬间也能留下第一现场。
                snapshot = captureMemorySnapshotLocked()
            }
            publishMemorySample(snapshot, reason: "open")
            PlaybackLog.info("open() 成功")
        } catch {
            PlaybackLog.error("open() 失败 error=\(error)")
            throw error
        }
    }

    public func play() throws {
        if dropControlDuringOpen("play") { return }
        // 音频会话必须在 play 之前配好：内核只推 AudioQueue，不碰 AVAudioSession，
        // 默认类别下退后台 / 锁屏时系统会把会话和队列一起收走（见 ErikaAudioSession）。
        #if os(iOS)
        ErikaAudioSession.activateForPlayback()
        #endif
        do {
            try withLock { try presenter.play() }
            PlaybackLog.info("play() 成功")
        } catch {
            PlaybackLog.warning("play() 失败 error=\(error)")
            throw error
        }
    }

    public func pause() throws {
        if dropControlDuringOpen("pause") { return }
        do {
            try withLock { try presenter.pause() }
            PlaybackLog.info("pause() 成功")
        } catch {
            PlaybackLog.warning("pause() 失败 error=\(error)")
            throw error
        }
    }

    public func stop() throws {
        PlaybackLog.info("stop() 开始")
        if deferStopDuringOpen() { return }
        do {
            var snapshot: ErikaMemorySnapshot?
            try withLock {
                try presenter.stop()
                // 收尾快照：对比 open/停止前各分项，看释放路径该清的是否清干净。
                snapshot = captureMemorySnapshotLocked()
            }
            publishMemorySample(snapshot, reason: "stop")
            PlaybackLog.info("stop() 成功")
        } catch {
            PlaybackLog.warning("stop() 失败 error=\(error)")
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
        PlaybackLog.info("close() 开始")
        do {
            try withLock { try presenter.close() }
            PlaybackLog.info("close() 成功")
        } catch {
            PlaybackLog.warning("close() 失败 error=\(error)")
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
        PlaybackLog.info("open 在飞，stop 让位登记")
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

    /// 宿主推送的显示器 EDR headroom（见 PlaybackEngine 协议注释）。钳到内核
    /// capi 接受区间；open 在飞时丢弃（与其它控制调用同一契约）；失败只记日志
    /// 不打断播放——提示性调用，内核侧（如 macOS Metal）没实现时静默无效果。
    public func updateDisplayEDRHeadroom(_ headroom: Double) {
        if dropControlDuringOpen("updateDisplayEDRHeadroom") { return }
        let clamped = Float(min(max(headroom, 1.0), 10_000))
        guard clamped != lastPushedEDRHeadroom else { return }
        do {
            try withLock { try presenter.setOutputHeadroom(clamped) }
            lastPushedEDRHeadroom = clamped
            PlaybackLog.info(String(format: "displayEDRHeadroom → %.2f", clamped))
        } catch {
            PlaybackLog.warning("updateDisplayEDRHeadroom 失败 error=\(error)")
        }
    }

    public func stats() throws -> ErikaPresenterStats {
        if dropControlDuringOpen("stats") { return ErikaPresenterStats() }
        return try withLock { try presenter.stats() }
    }

    /// 没有画面（窗口隐藏 / 纯音频推进）时的帧驱动。Erika 独有：
    /// 宿主驱动帧的内核才需要这个，App 层目前没有用到。
    @discardableResult
    public func audioOnlyTick() throws -> ErikaPresenterStats {
        if dropControlDuringOpen("audioOnlyTick") { return ErikaPresenterStats() }
        return try withLock { try presenter.audioOnlyTick() }
    }

    // MARK: - 轨道与字幕

    /// open 在飞时返回空列表：宿主加载轨道列表本来就要等源 ready，丢一拍无副作用。
    public func tracks() throws -> [TrackInfo] {
        if dropControlDuringOpen("tracks") { return [] }
        return try withLock { try presenter.tracks() }
    }

    public func selectAudioTrack(_ id: Int64) throws {
        if dropControlDuringOpen("selectAudioTrack") { return }
        try withLock { try presenter.selectAudioTrack(id) }
    }

    public func selectSubtitleTrack(_ id: Int64?) throws {
        if dropControlDuringOpen("selectSubtitleTrack") { return }
        try withLock { try presenter.selectSubtitleTrack(id) }
    }

    /// 外挂字幕（本地路径 / URL），返回新轨道 id。open 在飞时丢弃，返回 -1 哨兵
    /// （内核轨道 id 恒非负；调用方拿着它继续 selectSubtitleTrack 也一并被让位）。
    @discardableResult
    public func addExternalSubtitle(_ uri: String) throws -> Int64 {
        if dropControlDuringOpen("addExternalSubtitle") { return -1 }
        return try withLock { try presenter.addExternalSubtitle(uri) }
    }

    /// 移除一条字幕轨。open 在飞时丢弃（那时轨道列表本来就还没就绪）。
    ///
    /// 调用方必须先看 `TrackInfo.canRemove`：内嵌轨内核会拒绝，这里会把错误抛出去。
    public func removeSubtitleTrack(_ id: Int64) throws {
        if dropControlDuringOpen("removeSubtitleTrack") { return }
        try withLock { try presenter.removeSubtitleTrack(id) }
    }

    /// 字幕整体缩放（1.0 = 默认字号；HUD 的「字号 +/-」用）。
    /// open 在飞时丢弃：open 成功路径会按宿主快照重放字幕缩放，无需登记。
    public func setSubtitleScale(_ scale: Double) throws {
        if dropControlDuringOpen("setSubtitleScale") { return }
        try withLock { try ErikaError.check(erika_presenter_set_subtitle_scale(presenter.handle, scale)) }
    }

    /// 设置字幕外观（颜色 / 描边 / 位置 / 边距 / 加粗）。
    ///
    /// `overrides` 为空时是「只填空缺」：片源自带的 ASS 排版与特效字体全部保留；
    /// 非空时把对应项变成替换（用户显式要求「覆盖字幕自带样式」）。
    /// open 在飞时丢弃——open 成功路径会按宿主快照重放，无需登记。
    ///
    /// **免抛**：外观是提示性设置，内核拒绝（例如没有可用字幕）不该打断播放。
    public func setSubtitleStyle(_ style: SubtitleStyle, overrides: SubtitleStyleOverrides) {
        if dropControlDuringOpen("setSubtitleStyle") { return }
        do {
            // 字体名 / 文件不在这里传（需要 C 字符串存活到调用结束），由随后的
            // setSubtitleFont 单独下发；本仓库暂不开放字体选择，所以是 nil。
            let raw = ErikaSubtitleStyle(style, overrides: overrides)
            try withLock { try presenter.setSubtitleStyle(raw) }
        } catch {
            PlaybackLog.warning("设置字幕外观失败 error=\(error)")
        }
    }

    // MARK: - 画质增强（亮度上采样）

    /// 运行时切换亮度上采样档位。open 在飞时丢弃（那时还没有画面可增强）；
    /// 宿主的 open 收尾会按当前偏好重放一次，所以丢弃不会留下不一致。
    ///
    /// **免抛**：目标后端不支持时内核保留原生亮度采样并在状态里报 `inactive`，
    /// 这不是错误，不该打断播放。
    public func setLumaUpscaler(_ mode: PlaybackUpscalerMode) {
        if dropControlDuringOpen("setLumaUpscaler") { return }
        do {
            try withLock { try presenter.setUpscaler(mode) }
        } catch {
            PlaybackLog.warning("切换亮度上采样失败 mode=\(mode.rawValue) error=\(error)")
        }
    }

    /// 上采样后端状态。遵守 open 让位契约（open 在飞返回中性值）。
    public var lumaUpscalerState: PlaybackUpscalerState {
        if dropControlDuringOpen("lumaUpscalerState") { return .unknown }
        return (try? withLock { try presenter.upscalerStatus() }) ?? .unknown
    }

    // MARK: - 截图

    /// 离屏截当前合成帧（视频 + 字幕），RGBA8，尺寸传视频物理分辨率。
    /// open 在飞时返回空缓冲（宿主侧还有 videoParams 守卫双保险）。
    public func captureFrameRGBA(width: Int, height: Int) throws -> [UInt8] {
        if dropControlDuringOpen("captureFrameRGBA") { return [] }
        return try withLock { try presenter.captureFrameRGBA(width: width, height: height) }
    }

    // MARK: - 内核内置弹幕（DFM+）

    // 弹幕入口在 open 期间全部让位：当前版本弹幕统一走 App 层 overlay
    // （usesOverlayDanmakuRenderer 恒 true），open 后宿主会用快照统一装载，
    // 中途让位登记没有意义，丢弃 + 日志即可。恢复内核弹幕后，装载入口
    // （loadDanmaku / addDanmakuTrack / clearDanmaku）需要评估改成登记补做。

    /// Replace all current danmaku with one anonymous Bilibili XML source.
    public func loadDanmaku(fileURI: String) throws {
        if dropControlDuringOpen("loadDanmaku(fileURI:)") { return }
        try withLock { try presenter.loadDanmaku(fileURI: fileURI) }
    }

    /// Replace all current danmaku with one anonymous inline JSON source.
    public func loadDanmaku(json: String) throws {
        if dropControlDuringOpen("loadDanmaku(json:)") { return }
        try withLock { try presenter.loadDanmaku(json: json) }
    }

    @discardableResult
    public func addDanmakuTrack(
        fileURI: String,
        name: String,
        offset: Duration = .zero
    ) throws -> UInt64 {
        if dropControlDuringOpen("addDanmakuTrack(fileURI:)") { return 0 }
        return try withLock {
            try presenter.addDanmakuTrack(fileURI: fileURI, name: name, offset: offset)
        }
    }

    @discardableResult
    public func addDanmakuTrack(
        json: String,
        name: String,
        offset: Duration = .zero
    ) throws -> UInt64 {
        if dropControlDuringOpen("addDanmakuTrack(json:)") { return 0 }
        return try withLock {
            try presenter.addDanmakuTrack(json: json, name: name, offset: offset)
        }
    }

    public func removeDanmakuTrack(_ id: UInt64) throws {
        if dropControlDuringOpen("removeDanmakuTrack") { return }
        try withLock { try presenter.removeDanmakuTrack(id) }
    }

    public func setDanmakuTrack(_ id: UInt64, enabled: Bool) throws {
        if dropControlDuringOpen("setDanmakuTrack(enabled:)") { return }
        try withLock { try presenter.setDanmakuTrack(id, enabled: enabled) }
    }

    public func setDanmakuTrack(_ id: UInt64, offset: Duration) throws {
        if dropControlDuringOpen("setDanmakuTrack(offset:)") { return }
        try withLock { try presenter.setDanmakuTrack(id, offset: offset) }
    }

    public func setDanmakuGlobalOffset(_ offset: Duration) throws {
        if dropControlDuringOpen("setDanmakuGlobalOffset") { return }
        try withLock { try presenter.setDanmakuGlobalOffset(offset) }
    }

    public func danmakuTracks() throws -> [DanmakuTrackInfo] {
        if dropControlDuringOpen("danmakuTracks") { return [] }
        return try withLock { try presenter.danmakuTracks() }
    }

    public func clearDanmaku() throws {
        if dropControlDuringOpen("clearDanmaku") { return }
        try withLock { try presenter.clearDanmaku() }
    }

    public func setDanmakuEnabled(_ enabled: Bool) throws {
        if dropControlDuringOpen("setDanmakuEnabled") { return }
        try withLock { try presenter.setDanmakuEnabled(enabled) }
    }

    public func danmakuConfig() throws -> DanmakuConfig {
        if dropControlDuringOpen("danmakuConfig") { return DanmakuConfig() }
        return try withLock { try presenter.danmakuConfig() }
    }

    public func setDanmakuConfig(_ config: DanmakuConfig) throws {
        if dropControlDuringOpen("setDanmakuConfig") { return }
        try withLock { try presenter.setDanmakuConfig(config) }
    }

    public func setDanmakuFont(family: String?, filePath: String?) throws {
        if dropControlDuringOpen("setDanmakuFont") { return }
        try withLock { try presenter.setDanmakuFont(family: family, filePath: filePath) }
    }

    public func setDanmakuBlockWords(json: String) throws {
        if dropControlDuringOpen("setDanmakuBlockWords") { return }
        try withLock { try presenter.setDanmakuBlockWords(json: json) }
    }

    // MARK: - 内部

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// 采样内核内存分项。拆两段：**锁内段**只调 presenter.resourceStatus()
    /// （摸 presenter 必须持锁），失败记录 memorySampleFailed（只报一次——
    /// 通常意味着该能力在某版本不可用，不该逐帧刷屏）；footprint / 日志 / 落库
    /// 在 publishMemorySample 锁外做——纯进程读数 + 字符串拼串，不该拉长主锁持有期。
    private func captureMemorySnapshotLocked() -> ErikaMemorySnapshot? {
        do {
            let snapshot = ErikaMemorySnapshot(try presenter.resourceStatus())
            memorySampleFailed = false
            return snapshot
        } catch {
            if !memorySampleFailed {
                memorySampleFailed = true
                PlaybackLog.error("内核内存采样失败 error=\(error)")
            }
            return nil
        }
    }

    /// 锁外段：落库 + 进程 footprint + 日志。快照已在手，不碰 presenter，无需主锁。
    /// tick 采样走「变化才记」（见 `shouldLogMemorySample`），open/stop 基线始终记。
    private func publishMemorySample(_ snapshot: ErikaMemorySnapshot?, reason: String) {
        guard let snapshot else { return }
        statsLock.lock()
        _latestMemory = snapshot
        statsLock.unlock()
        guard shouldLogMemorySample(snapshot, reason: reason) else { return }
        let process = ProcessFootprint.current()
        var fields = snapshot.logFields
        for (key, value) in process.logFields { fields[key] = value }
        PlaybackLog.info(
            "内核内存 reason=\(reason) \(snapshot.summaryLine) · \(process.summaryLine)",
            fields: fields
        )
    }

    /// 锁外段：输出状态变化时记一条。
    ///
    /// 为什么值得单独记：`latestOutputEncoding` 只让 UI 看到「现在出的是什么」，
    /// 而**回退**（请求了 HDR 却落到 SDR）在 UI 上几乎看不出来——画面照常、用户
    /// 只会觉得「怎么不够亮」。内核把原因写在 `fallback_reason` 里，App 此前
    /// 连读都没读。这里的变化才记口径与内存采样一致：一次播放通常只有起播与
    /// 换屏两三次变化，逐次记就是噪声。
    private func publishOutputStatus(_ raw: ErikaOutputStatus?) {
        guard let raw else { return }
        guard lastLoggedOutputStatus.map({ Self.isMeaningfulOutputChange(from: $0, to: raw) }) ?? true else {
            return
        }
        lastLoggedOutputStatus = raw
        let snapshot = PlaybackOutputSnapshot(raw)
        var fields = snapshot.logFields
        fields["encoding"] = .string(Self.encoding(of: raw).rawValue)
        fields["requested_mode"] = .integer(Int64(raw.requested_mode))
        fields["active_headroom"] = raw.active_headroom_known
            ? .double(Double(raw.active_headroom))
            : .null
        fields["data_space_failures"] = .unsignedInteger(raw.data_space_failures)
        fields["headroom_updates"] = .unsignedInteger(raw.headroom_updates)
        PlaybackLog.info("内核输出 \(snapshot.summaryLine)", fields: fields)
    }

    /// 是否值得为这次输出状态再记一条日志。
    ///
    /// 只看**会变的语义量**：面格式 / 回退原因 / 回退次数 / headroom / 编码。
    /// `headroom_updates`、`data_space_failures` 这类**累计计数不进比较**——它们每次
    /// 采样都在涨，算进来就等于「每次都记」，把「变化才记」变成逐次刷屏。
    /// internal 供测试直接钉住这张清单（纯值比较，不需要 GPU）。
    static func isMeaningfulOutputChange(
        from lhs: ErikaOutputStatus,
        to rhs: ErikaOutputStatus
    ) -> Bool {
        lhs.surface_format != rhs.surface_format
            || lhs.fallback_reason != rhs.fallback_reason
            || lhs.fallback_count != rhs.fallback_count
            || lhs.active_headroom != rhs.active_headroom
            || lhs.active_headroom_known != rhs.active_headroom_known
            || lhs.extended_linear_active != rhs.extended_linear_active
            || lhs.active_encoding != rhs.active_encoding
    }

    /// `active_encoding` → 中立枚举。`latestOutputEncoding` 与输出日志共用一份映射
    /// （两处各写一份 switch 就是等着漂移）。
    private static func encoding(of raw: ErikaOutputStatus) -> PlaybackOutputEncoding {
        switch Int32(raw.active_encoding) {
        case Int32(ErikaActiveOutputEncoding_SdrSrgb.rawValue): .sdr
        case Int32(ErikaActiveOutputEncoding_AppleEdr.rawValue): .appleEdr
        case Int32(ErikaActiveOutputEncoding_AndroidExtendedLinearScRgb.rawValue): .extendedLinear
        case Int32(ErikaActiveOutputEncoding_Hdr10Pq.rawValue): .hdr10Pq
        default: .unknown
        }
    }

    /// tick 采样只在「与上次记录相比有实质变化」时写日志：关键分项变化 ≥8 MiB
    /// 或 ≥10%，或 drawable 数 / 输出模式切换计数变了（后者正是显示器侧切 HDR /
    /// 刷新率的证据，issue #2 要用）。open/stop 的基线永远写——那是一段播放的头尾锚点。
    private func shouldLogMemorySample(_ snapshot: ErikaMemorySnapshot, reason: String) -> Bool {
        guard reason == "tick" else { return true }
        statsLock.lock()
        defer { statsLock.unlock() }
        guard let previous = lastLoggedTickMemory else {
            lastLoggedTickMemory = snapshot
            return true
        }
        guard Self.isMemoryMeaningfullyChanged(from: previous, to: snapshot) else { return false }
        lastLoggedTickMemory = snapshot
        return true
    }

    private static func isMemoryMeaningfullyChanged(
        from old: ErikaMemorySnapshot, to new: ErikaMemorySnapshot
    ) -> Bool {
        if old.drawableCount != new.drawableCount { return true }
        if old.outputModeSwitches != new.outputModeSwitches { return true }
        let pairs: [(UInt64, UInt64)] = [
            (old.rendererTrackedBytes, new.rendererTrackedBytes),
            (old.videoFrameBytes, new.videoFrameBytes),
            (old.danmakuAtlasBytes, new.danmakuAtlasBytes),
            (old.deviceCurrentAllocatedBytes, new.deviceCurrentAllocatedBytes),
        ]
        for (before, after) in pairs {
            let delta = UInt64(abs(Int64(after) - Int64(before)))
            if delta >= memoryLogThresholdBytes { return true }
            if before > 0, Double(delta) / Double(before) >= memoryLogThresholdRatio { return true }
        }
        return false
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

    /// 内核原始诊断计数器 + 输出状态，供宿主在会话收尾落一条日志。
    ///
    /// 覆盖 `ErikaPresenterStats` 的**全部**字段（此前只有 8 个进了中立层，其余 26 个
    /// 从没有任何读取点）加输出细节。字段名与内核 C 字段同名，便于和内核自己的
    /// stderr trace 对照。
    ///
    /// ⚠️ 两个前提必须知道，否则会误读这些数字：
    /// - `audio_recovery_*` / `audio_last_error_code` 那套音频自恢复状态机**只在
    ///   Windows WASAPI / Android AAudio / OHOS OHAudio 后端实现**，Apple 后端恒为
    ///   stable/0、对应事件也永不触发——用它判断 iOS 的音频问题会永远看到「一切正常」。
    /// - HDR 相关计数（`hdr_source_frames` / `sdr_tonemap_frames` …）只在真的走过
    ///   HDR 链路时非零，SDR 片源全程为 0 是正常的。
    public func kernelDiagnosticsFields() -> [String: DiagnosticValue] {
        let s = latestErikaStats
        var fields: [String: DiagnosticValue] = [:]
        // 逐项赋值而不是一个大字典字面量：几十个混合类型的条目会让类型检查器超时
        //（`PlayerState.finishSession` 里踩过同一个坑）。
        fields["decoded_video_frames"] = .unsignedInteger(s.decoded_video_frames)
        fields["rendered_video_frames"] = .unsignedInteger(s.rendered_video_frames)
        fields["rendered_test_frames"] = .unsignedInteger(s.rendered_test_frames)
        fields["pushed_audio_frames"] = .unsignedInteger(s.pushed_audio_frames)
        fields["overlay_frames"] = .unsignedInteger(s.overlay_frames)
        fields["danmaku_frames"] = .unsignedInteger(s.danmaku_frames)
        fields["danmaku_items"] = .unsignedInteger(s.danmaku_items)
        fields["import_failures"] = .unsignedInteger(s.import_failures)
        fields["render_failures"] = .unsignedInteger(s.render_failures)
        fields["audio_failures"] = .unsignedInteger(s.audio_failures)
        fields["software_video_frames"] = .unsignedInteger(s.software_video_frames)
        fields["hardware_video_frames"] = .unsignedInteger(s.hardware_video_frames)
        fields["zero_copy_video_frames"] = .unsignedInteger(s.zero_copy_video_frames)
        fields["cpu_video_frame_fallbacks"] = .unsignedInteger(s.cpu_video_frame_fallbacks)
        fields["video_frame_backpressure_drops"] = .unsignedInteger(s.video_frame_backpressure_drops)
        fields["direct_zero_copy_video_frames"] = .unsignedInteger(s.direct_zero_copy_video_frames)
        fields["shared_handle_video_frames"] = .unsignedInteger(s.shared_handle_video_frames)
        fields["last_render_micros"] = .unsignedInteger(s.last_render_micros)
        fields["last_render_current_micros"] = .unsignedInteger(s.last_render_current_micros)
        fields["audio_clock_read_frames"] = .unsignedInteger(s.audio_clock_read_frames)
        fields["audio_clock_queued_frames"] = .unsignedInteger(s.audio_clock_queued_frames)
        fields["audio_clock_underflow_frames"] = .unsignedInteger(s.audio_clock_underflow_frames)
        fields["audio_recovery_state"] = .integer(Int64(s.audio_recovery_state))
        fields["audio_last_error_code"] = .integer(Int64(s.audio_last_error_code))
        fields["audio_recovery_attempts"] = .unsignedInteger(s.audio_recovery_attempts)
        fields["audio_recovery_count"] = .unsignedInteger(s.audio_recovery_count)
        fields["audio_recovery_failures"] = .unsignedInteger(s.audio_recovery_failures)
        fields["hdr_source_frames"] = .unsignedInteger(s.hdr_source_frames)
        fields["hdr10_output_frames"] = .unsignedInteger(s.hdr10_output_frames)
        fields["sdr_tonemap_frames"] = .unsignedInteger(s.sdr_tonemap_frames)
        fields["hdr10_metadata_updates"] = .unsignedInteger(s.hdr10_metadata_updates)
        fields["hdr10_metadata_failures"] = .unsignedInteger(s.hdr10_metadata_failures)
        fields["hdr10_output_failures"] = .unsignedInteger(s.hdr10_output_failures)
        fields["hdr10_output_active"] = .boolean(s.hdr10_output_active)
        // 输出细节加前缀，避免与统计字段重名。
        for (key, value) in latestOutputSnapshot.logFields {
            fields["output_\(key)"] = value
        }
        fields["output_encoding"] = .string(latestOutputEncoding.rawValue)
        return fields
    }

    /// 渲染线程每帧一次。失败在故障期间会逐帧触发，日志走 1s 节流，
    /// 只留下首条 + flush 时的一条汇总。
    private static let renderThrottle = DiagnosticThrottle(key: "render-failure", interval: 1)

    /// 渲染线程每帧一次。
    ///
    /// `audioOnly` 为真时走 `audio_only_tick`（后台档）：内核据此**挂起视频解码**，
    /// 只推进音频；事件抽干、统计采样、帧率档位这些外围逻辑两条路完全共用，
    /// 否则后台期间的 position 事件会断供，锁屏进度条就冻住了。
    ///
    /// `presentationDelay` 是这一帧到显示目标的延迟（见 `RenderLoop`）：非 nil 时
    /// 走 `render_tick_with_timing`，字幕与渲染上下文按同一个显示目标时刻采样。
    /// 后台档用不到它（没有显示目标）。
    private func step(presentationTime: Double,
                      presentationDelay: Double? = nil,
                      audioOnly: Bool = false) {
        // 档位闸门：切档与 tick 来自不同线程，迟到的回调必须丢掉。
        //  - 退出后台档后迟到的定时器回调若放行，会把内核刚解开的视频解码又挂起；
        //  - 后台档期间若还有 render_tick 在跑（例如期间重新 attach 起了渲染线程），
        //    放行等于把刚挂起的解码立刻解开，这一档就白切了。
        guard audioOnly == isBackgroundAudioOnly else { return }
        var pending: [PlayerEvent] = []

        lock.lock()
        var memorySnapshot: ErikaMemorySnapshot?
        var outputStatus: ErikaOutputStatus?
        do {
            let stats = audioOnly
                ? try presenter.audioOnlyTick()
                : try presenter.renderTick(at: presentationTime, presentationDelay: presentationDelay)
            statsLock.lock()
            _latestStats = stats
            statsLock.unlock()            // 每 5s 采一次内核内存，渲染线程时间基准，形成整段播放的内存时间线。
            if presentationTime - lastMemorySampleAt >= Self.memorySampleIntervalSeconds {
                lastMemorySampleAt = presentationTime
                memorySnapshot = captureMemorySnapshotLocked()
                // 输出状态搭同一趟车：多一次极短的 C 调用，换「HDR 为什么没出」的第一手证据。
                outputStatus = try? presenter.outputStatus()
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
        // footprint / 日志不在主锁内做（纯进程读数 + 拼串，5s 一次也该让渲染不受扰）。
        publishMemorySample(memorySnapshot, reason: "tick")
        publishOutputStatus(outputStatus)

        for event in pending {
            // 帧率档位跟随播放状态：paused 降帧 15-30（拖窗口/resize 仍要跟手）；
            // stopped/error 进 idle 档——tick 只剩事件轮询在跑，没必要全刷新率空转。
            // 在这里改是因为 step() 就跑在渲染线程上，CADisplayLink 只能在自己的
            // runloop 线程上安全改动。
            if case .stateChanged(let value) = event {
                renderLoop.setTier(Self.tier(for: value))
            }
            // 高频 position 过闸；控制事件（状态/轨道/错误）即时发布，永不被丢。
            // 见 PositionPublishGate：不然 256 的缓冲会被 position 灌满，
            // `.bufferingNewest` 丢掉最旧的——可能正好是 stopped / failed。
            if case .positionChanged = event, !positionGate.shouldPublish() {
                continue
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
