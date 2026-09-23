import CoreGraphics
import DanmakuKit
import DiagnosticsKit
import Foundation
import ImageIO
import JellyfinKit
import Observation
import PlaybackKit
import UniformTypeIdentifiers

/// App 层播放链路日志。走统一诊断管线（JSONL + OSLog，敏感字段自动脱敏）。
/// 与 PlaybackKit 的 PlaybackLog 同一份文件，时间线上无缝。
let playerLog = AppDiagnostics.logger

final class PlaybackSecurityScopeLease: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseAction: @Sendable () -> Void
    private var isReleased = false

    init(releaseAction: @escaping @Sendable () -> Void) {
        self.releaseAction = releaseAction
    }

    func releaseOnce() {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        if shouldRelease { releaseAction() }
    }
}

private final class PlaybackOpenAttempt: @unchecked Sendable {
    let scopeLease: PlaybackSecurityScopeLease?
    private let lock = NSLock()
    private var isCancelled = false

    init(scopeLease: PlaybackSecurityScopeLease?) {
        self.scopeLease = scopeLease
    }

    var cancelled: Bool { lock.withLock { isCancelled } }

    func cancel() {
        lock.withLock { isCancelled = true }
    }
}

/// PlaybackCoordinator：拿到源 → 喂内核 → 暴露状态给 UI。
/// 进度上报（M2）、弹幕装载（M3）都挂在这一层。
///
/// **不认识任何具体内核**：只用 `PlaybackKit` 的 `any PlaybackEngine`。
/// 用哪个内核由 `PlaybackEngineRegistry` 决定，在 `prepareEngine()` 里现取。
@MainActor
@Observable
final class PlaybackController: DanmakuPlaybackHosting {
    /// Replaced for every engine generation so buffered events from an old
    /// engine can never mutate the new source's timeline.
    var state = PlayerState()

    var engine: (any PlaybackEngine)?
    var setupError: String?
    var currentTitle: String?
    /// Request-scoped synchronous source-open failure. Kept separate from
    /// setupError because subtitle/screenshot failures must not stop reporting.
    var failedRequestID: PlaybackRequest.ID?
    /// Identifies the request that owns the current position snapshot. Unlike
    /// `activeRequest`, this survives `stopPlayback()` until AppModel reports
    /// the final position.
    var reportableRequestID: PlaybackRequest.ID?
    /// 播放器窗口所在屏最近的 EDR headroom 报告（macOS 探针写）。引擎懒创建
    /// 时探针可能还没挂上/已经报过，这里记最近值，创建后补推一次，保证
    /// 换片重建引擎不丢显示状态。
    private var lastDisplayEDRHeadroom: Double?

    /// 本次 open 的起点（`open.done` 的 elapsed_ms 用）。
    @ObservationIgnored private var openStartedAt: Date?
    /// 卡死看门狗：在播、位置不动、内核又**没**报缓冲 = demux/解码卡住的信号。
    @ObservationIgnored private var stallWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var lastStallCheckPosition: Duration = .zero
    @ObservationIgnored private var frozenSeconds: Double = 0
    @ObservationIgnored private var stallReported = false

    var rate: Double = PlaybackPreferences.rate {
        didSet {
            guard rate != oldValue else { return }
            // 长按 2x 的临时倍速不落盘：加速中杀 App，下次启动不该默认 2 倍速。
            if holdFastForwardRate == nil { PlaybackPreferences.rate = rate }
        }
    }
    /// 音量尾去抖任务：连续调节每 tick 都写 volume，落盘合并到最后一次之后。
    private var volumePersistTask: Task<Void, Never>?
    var volume: Double = PlaybackPreferences.volume {
        didSet {
            guard volume != oldValue else { return }
            if volume > 0, muted { muted = false }
            scheduleVolumePersist()
        }
    }

    /// 音量落盘用 300ms 尾去抖：iOS 纵滑 / macOS 滑杆拖动期间每秒可产生上百次
    /// volume 写入，逐次同步写 UserDefaults 太重；最终值总会落一次盘。
    private func scheduleVolumePersist() {
        volumePersistTask?.cancel()
        volumePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            PlaybackPreferences.volume = self.volume
        }
    }
    /// 静音（保留原音量，解除时还原）。
    var muted = PlaybackPreferences.muted {
        didSet { if muted != oldValue { PlaybackPreferences.muted = muted } }
    }
    /// 字幕整体缩放（1.0 默认），跨启动记住。
    var subtitleScale = PlaybackPreferences.subtitleScale {
        didSet {
            if subtitleScale != oldValue {
                PlaybackPreferences.subtitleScale = subtitleScale
            }
        }
    }

    var danmakuTracks: [DanmakuTrackInfo] = []
    /// 章节与跳过判定(当前源)。
    var chapterSession = ChapterSession()
    /// 跳过片头提示（弹幕报点 / AniSkip 任一来源,永久缓存随弹幕匹配下发）。
    /// 章节与弹幕两条异步链路都可能后到,这里存住提示,谁后到谁负责合并进
    /// `chapterSession.skipMarks`。
    var skipTimesHint: DanmakuKit.DanmakuIntroHint?
    /// 外挂字幕轨道 id → 显示名（Jellyfin 侧车字幕的标题）。内核不带名字，
    /// App 层在下载时记录；换源 / 拆引擎时清空（见 resetEngine）。
    var externalSubtitleNames: [Int64: String] = [:]
    var danmakuEnabled = PlaybackPreferences.danmakuEnabled
    var danmakuOpacity = PlaybackPreferences.danmakuOpacity
    var danmakuDisplayArea = PlaybackPreferences.danmakuDisplayArea
    var danmakuBlockTop = PlaybackPreferences.danmakuBlockTop
    var danmakuBlockBottom = PlaybackPreferences.danmakuBlockBottom
    var danmakuBlockScroll = PlaybackPreferences.danmakuBlockScroll
    var danmakuMergeDuplicates = PlaybackPreferences.danmakuMergeDuplicates
    var danmakuAllowStacking = PlaybackPreferences.danmakuAllowStacking
    var danmakuFontSize = PlaybackPreferences.danmakuFontSize
    var danmakuGlobalOffsetSeconds = 0.0

    /// 弹幕渲染路线：true = App 层 DanmakuRenderKit overlay（内核弹幕不装载），
    /// false = 内核内置弹幕渲染器。详见 DanmakuOverlay.swift 头注释。
    ///
    /// **在 `prepareEngine()` 里跟内核一起锁定**，播放期间不变：中途翻转会让
    /// 同一条弹幕数据同时进内核和 overlay（双份弹幕）。设置页改动因此在
    /// 下一次播放生效，和换内核的语义一致。
    ///
    /// **当前版本一律 true**：内核弹幕因跳轨问题被禁用，详见
    /// `resolveOverlayDanmakuRoute()`。恢复内核渲染后，此处语义回到
    /// 「所选内核不支持内核弹幕时强制 overlay，否则听用户偏好」。
    private(set) var usesOverlayDanmakuRenderer: Bool

    var danmakuPayloadFormat: DanmakuPayloadFormat {
        usesOverlayDanmakuRenderer ? .overlay : .kernelTrack
    }
    let danmakuOverlay: DanmakuOverlayController

    /// 当前生效的内核描述（设置页 / 诊断显示用）。引擎还没创建时给注册表的当前选择。
    var activeEngineDescriptor: PlaybackEngineDescriptor? {
        engine?.descriptor ?? PlaybackEngineRegistry.selected
    }

    /// 当前版本统一强制 overlay：内核 DFM+ 的滑窗重排仍会让在屏弹幕跳轨，
    /// 内核弹幕渲染暂时禁用（设置页「用内核渲染弹幕」开关同步置灰并附说明）。
    /// 内核修复后恢复旧判定：内核不支持弹幕时强制 overlay，否则走
    /// `PlaybackPreferences.danmakuUseOverlayRenderer`（key 保留着，用户旧选择还在）。
    private static func resolveOverlayDanmakuRoute() -> Bool {
        true
    }

    init() {
        usesOverlayDanmakuRenderer = PlaybackController.resolveOverlayDanmakuRoute()
        // 先占位再注入：闭包捕获 self 必须等全部存储属性初始化完成。
        danmakuOverlay = DanmakuOverlayController(engineProvider: { nil })
        danmakuOverlay.engineProvider = { [weak self] in self?.engine }
        danmakuOverlay.playbackStateProvider = { [weak self] in
            guard let self else { return nil }
            // 冻结/续播的判据用迟滞后的 UI 态：单帧饿数据不该让弹幕顿一下（issue #2）。
            return (self.state.state == .playing, self.state.isBufferingSustained)
        }
        danmakuOverlay.update {
            $0.enabled = danmakuEnabled
            $0.opacity = danmakuOpacity
            $0.displayArea = danmakuDisplayArea
            $0.blockTop = danmakuBlockTop
            $0.blockBottom = danmakuBlockBottom
            $0.blockScroll = danmakuBlockScroll
            $0.allowStacking = danmakuAllowStacking
            $0.fontSize = danmakuFontSize
        }
    }

    /// 当前内核里打开的源（去重用：覆盖层出现时不重复 open 同一个源）。
    var currentlyOpenURI: String?
    // MARK: open 在飞状态（open 已移出主线程,见 engineOpenQueue 注释）
    /// 在飞的 open。用途：同请求重入去重、换片时判定「旧引擎还在 open」、看门狗。
    /// 每次尝试独立关联，迟到回调不得清除重试请求的状态。
    private(set) var openingRequestID: PlaybackRequest.ID?
    private(set) var openingSourceURI: String?
    private var openingWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var openingAttempt: PlaybackOpenAttempt?
    /// open 在飞期间按下的暂停意图：引擎对 play/pause 让位丢弃，且 open 成功后
    /// 队列闭包的 play() 会盖掉任何早于它的 pause——只有 open 成功落状态后再补
    /// 一次 pause 才能真正生效。换片 / 失败 / 停播路径随 resetEngine 一并清除。
    private(set) var openingPauseIntent = false
    private static let engineOpenQueue = DispatchQueue(
        label: "dev.jumusu.OcPlayer.engine-open", qos: .userInitiated, attributes: .concurrent)
    private static let maximumConcurrentOpenAttempts = 2
    private static var activeOpenAttempts = 0
    /// open 看门狗时长。默认 60s；测试注入缩短。
    static var openWatchdogTimeout: Duration = .seconds(60)
    /// Changes as soon as a new request is presented, before its engine opens.
    var sourceGeneration: UInt64 = 0
    /// 最近一次请求（出错重试用）。
    var lastRequest: PlaybackRequest?

    var eventTask: Task<Void, Never>?
    var resumeTask: Task<Void, Never>?
    var expectedRequestID: PlaybackRequest.ID?
    var activeRequest: PlaybackRequest?
    private var activeSecurityScopeLease: PlaybackSecurityScopeLease?
    var hasLoadedSource = false
    /// 引擎是否还在运行(open 成功置 true,stopPlayback/open 失败置 false)。
    /// 供关闭播放器的多条收口路径共用:引擎已被停掉的不再重复 stop。
    var engineIsActive = false

    /// 播放期间阻止息屏。不参与 Observation：它没有任何 UI 表示。
    @ObservationIgnored private let wakeLock = PlaybackWakeLock()
    /// 系统「正在播放」与媒体键 / 控制中心命令。同样没有 UI 表示。
    @ObservationIgnored private let nowPlaying = PlaybackNowPlayingCenter()

    /// 按当前状态对齐息屏抑制与系统「正在播放」。
    ///
    /// 由 `PlayerScreen` 在 state / 进度 / 标题变化时调用；拆引擎的路径
    /// （stopPlayback → resetEngine）也兜一次。覆盖层被移除走的是下面的
    /// `releaseSystemPlaybackState()`，不是这里。
    func syncSystemPlaybackState() {
        let isActive = engine != nil && hasLoadedSource
        let isPlaying = isActive && state.state == .playing
        wakeLock.setActive(isPlaying)
        nowPlaying.publish(
            durationSeconds: Double(state.duration.microseconds) / 1_000_000,
            positionSeconds: Double(state.position.microseconds) / 1_000_000,
            rate: rate,
            isPlaying: isPlaying,
            isActive: isActive
        )
    }

    /// 播放器覆盖层被移除时调用：无条件交还息屏令牌与系统「正在播放」登记。
    ///
    /// 不能只重新推导一遍状态——`cancelPlaybackOpening()` 和注销
    /// （`AppModel+Session`）都会直接把 `presentedPlayer` 置空而**不**停引擎，
    /// 那时 state 还是 .playing，推导出来的结论会是「继续压着不让息屏」，
    /// 于是播放器已经不在了，屏幕还一直亮着。
    func releaseSystemPlaybackState() {
        wakeLock.setActive(false)
        nowPlaying.clear()
    }

    /// 系统「正在播放」显示的标题。剧名 + 集号住在 AppModel 侧，所以从外面传进来。
    func updateNowPlayingMetadata(title: String, subtitle: String) {
        nowPlaying.setMetadata(
            title: title.isEmpty ? (currentTitle ?? "") : title,
            subtitle: subtitle
        )
        syncSystemPlaybackState()
    }

    /// 装远程命令回调。`RootView` 注入控制器后调一次即可。
    /// 闭包捕获 `self` 用 weak：命令中心是全局单例，强引用会把控制器永久钉住。
    func installRemoteCommandHandlers() {
        nowPlaying.install(handlers: .init(
            play: { [weak self] in
                guard let self, self.state.state != .playing else { return }
                self.togglePlayPause()
            },
            pause: { [weak self] in
                guard let self, self.state.state == .playing else { return }
                self.togglePlayPause()
            },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] seconds in self?.skip(by: seconds) },
            seek: { [weak self] position in
                guard let self, let engine else { return }
                try? engine.seek(to: .microseconds(Int64(max(0, position) * 1_000_000)))
            }
        ))
    }

    /// 引擎懒创建：创建失败（缺内核 / 显卡不支持）时把原因留给 UI 显示。
    ///
    /// **用哪个内核在这里定**（`PlaybackEngineRegistry` 读 UserDefaults 里的选择），
    /// 所以设置页换内核在下一次播放生效，不用重启。弹幕渲染路线同时锁定，
    /// 保证一次播放里两者一致。
    @discardableResult
    func prepareEngine() -> (any PlaybackEngine)? {
        if let engine { return engine }
        // 内核和弹幕路线必须一起锁。当前版本内核弹幕被禁用，恒为 overlay；
        // 恢复内核渲染后回到「所选内核不支持内核弹幕时强制 overlay」的旧判定。
        usesOverlayDanmakuRenderer = Self.resolveOverlayDanmakuRoute()
        do {
            let engine = try PlaybackEngineRegistry.makeSelected()
            eventTask = state.start(consuming: engine)
            self.engine = engine
            setupError = nil
            // 创建 config 里的 headroom 取自工厂时刻的屏幕查询；探针若已报过
            // 更新的值（或工厂查询没拿到屏），创建后立即补推对齐。
            if let headroom = lastDisplayEDRHeadroom {
                engine.updateDisplayEDRHeadroom(headroom)
            }
            PlaybackLog.info(
                "PlaybackController prepareEngine 成功 kernel=\(engine.descriptor.id) "
                    + "danmaku=\(usesOverlayDanmakuRenderer ? "overlay" : "kernel")"
            )
            return engine
        } catch {
            setupError = "\(error)"
            return nil
        }
    }

    /// macOS 显示器探针入口：播放器出现 / 换屏 / 显示配置变化时调用。
    /// 记住最近值（引擎重建时补推），引擎在就转推内核。
    func updateDisplayEDRHeadroom(_ headroom: Double) {
        lastDisplayEDRHeadroom = headroom
        engine?.updateDisplayEDRHeadroom(headroom)
    }

    // MARK: - 打开源

    /// 手动直连链接（设置页入口）：构造带认证头的播放请求。
    static func request(uri: String, jellyfinToken: String?) -> PlaybackRequest {
        let authHeader: String?
        if let token = jellyfinToken, !token.isEmpty {
            authHeader = ClientIdentity.mediaBrowserAuthorizationHeader(token: token)
        } else {
            authHeader = nil
        }
        let title = URL(string: uri)?.lastPathComponent ?? uri
        return PlaybackRequest(title: title, uri: uri, authHeader: authHeader)
    }

    func open(fileURL: URL) {
        open(request: PlaybackRequest(
            title: fileURL.lastPathComponent,
            uri: fileURL.path,
            securityScopedURL: fileURL
        ))
    }

    /// Register a request before SwiftUI presents `PlayerScreen`. Async resource
    /// loaders use this boundary to invalidate work for the previous source even
    /// if the new engine has not been created yet.
    func prepareForPresentation(_ request: PlaybackRequest) {
        guard expectedRequestID != request.id else { return }
        openingAttempt?.cancel()
        openingWatchdogTask?.cancel()
        openingWatchdogTask = nil
        sourceGeneration &+= 1
        expectedRequestID = request.id
        failedRequestID = nil
        danmakuTracks = []
        danmakuGlobalOffsetSeconds = 0
        resumeTask?.cancel()
        resumeTask = nil
        PlaybackLog.append("source generation=\(sourceGeneration) request=\(request.id)")
    }

    /// Wait until the requested source has reached an engine state that accepts
    /// subtitle/danmaku injection. The returned token must be checked again at
    /// the actual injection point because the user can switch sources meanwhile.
    func waitUntilSourceReady(
        for requestID: PlaybackRequest.ID,
        timeout: Duration? = nil
    ) async -> PlaybackSourceGeneration? {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }

        while !Task.isCancelled {
            if let deadline, clock.now >= deadline { return nil }
            guard expectedRequestID == requestID else { return nil }
            if activeRequest?.id == requestID, isSourceReady {
                return PlaybackSourceGeneration(requestID: requestID, value: sourceGeneration)
            }
            if activeRequest?.id == requestID, state.state == .error {
                return nil
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Execute an engine mutation only if the ready token still identifies the
    /// current source. Future danmaku loading should cross this same boundary.
    @discardableResult
    func withReadyEngine(
        for source: PlaybackSourceGeneration,
        _ operation: (any PlaybackEngine) throws -> Void
    ) rethrows -> Bool {
        guard source.value == sourceGeneration,
              source.requestID == activeRequest?.id,
              isSourceReady,
              let engine
        else { return false }
        try operation(engine)
        return true
    }

    var isSourceReady: Bool {
        switch state.state {
        case .ready, .playing, .paused:
            return engine != nil
        case .idle, .opening, .stopped, .closed, .error:
            return false
        }
    }

    /// `uri` 是本地文件路径（`URL.path`）时直接开；已打开同一个源则跳过。
    func openIfNeeded(_ request: PlaybackRequest) {
        guard !Task.isCancelled else {
            PlaybackLog.append("openIfNeeded 忽略已取消任务 title=\(request.title)")
            return
        }
        if expectedRequestID == nil {
            // onOpenURL can present a local file before RootView's setup task
            // has injected the controller into AppModel. This is the only case
            // where the presentation task is allowed to register itself.
            prepareForPresentation(request)
        } else if expectedRequestID != request.id {
            PlaybackLog.append("openIfNeeded 忽略过期请求 title=\(request.title)")
            return
        }
        if let activeRequest, samePlaybackSource(activeRequest, request), engine != nil {
            self.activeRequest = request
            reportableRequestID = request.id
            PlaybackLog.append("openIfNeeded 跳过（已打开同一个源） title=\(request.title)")
            return
        }
        if openingRequestID == request.id {
            // 同一请求的 open 还在后台跑（视图重建触发 .task 重跑）：跳过。
            PlaybackLog.append("openIfNeeded 跳过（open 在飞） title=\(request.title)")
            return
        }
        openPreparedRequest(request)
    }

    /// 浏览层发起的播放：Jellyfin 直连流 + 认证头 + 服务端续播位置。
    func open(request: PlaybackRequest) {
        let isReopeningCurrentRequest = expectedRequestID == request.id
        prepareForPresentation(request)
        if isReopeningCurrentRequest {
            // Retry/reopen gets a new engine identity even when the request UUID
            // is reused by a lower-level caller. Old danmaku/subtitle tokens must
            // never be accepted by the replacement engine.
            openingAttempt?.cancel()
            sourceGeneration &+= 1
            resumeTask?.cancel()
            resumeTask = nil
        }
        openPreparedRequest(request)
    }

    func openPreparedRequest(_ request: PlaybackRequest) {
        currentTitle = request.title
        lastRequest = request
        activeRequest = nil
        failedRequestID = nil
        PlaybackLog.info("PlaybackController open(request) title=\(request.title) hasLoadedSource=\(hasLoadedSource)")
        openStartedAt = Date()
        var headers: [String: String] = [:]
        if let authHeader = request.authHeader {
            headers["Authorization"] = authHeader
        }
        let readAhead = PlaybackPreferences.httpReadAheadBytes
        let backBuffer = PlaybackPreferences.httpBackBufferBytes
        // 诊断「改了预读/回退档位没生效」：把本次真正传给内核的值打进日志。
        PlaybackLog.info(
            "openPreparedRequest readAhead=\(readAhead.map { "\($0 / 1024 / 1024) MiB" } ?? "默认(2 MiB)")"
            + " backBuffer=\(backBuffer.map { "\($0 / 1024 / 1024) MiB" } ?? "默认(16 MiB)")"
        )
        PlaybackLog.event(.openStart, fields: [
            "source": .string(Self.sourceKind(for: request.uri)),
            "read_ahead_bytes": readAhead.map { .integer(Int64($0)) } ?? .null,
            "back_buffer_bytes": backBuffer.map { .integer(Int64($0)) } ?? .null,
            "has_resume": .boolean(request.resumeSeconds != nil),
        ])
        open(
            PlaybackSource(
                uri: request.uri,
                headers: headers,
                // 本地文件路径没有预取语义，内核会忽略；统一带上无妨。
                readAheadBytes: readAhead,
                backBufferBytes: backBuffer
            ),
            securityScopedURL: request.securityScopedURL,
            request: request
        )
        reportableRequestID = request.id
        // 续播位置不立刻 seek（源还没就绪），挂到 pending 等 duration 到达。
        // open 失败时完成路径会失效 generation，这个等待循环按代次守卫自行退出。
        if let resume = request.resumeSeconds, resume >= 30, let engine {
            let generation = sourceGeneration
            let engineID = ObjectIdentifier(engine)
            resumeTask = Task { [weak self] in
                await self?.seekPendingResumeIfNeeded(
                    resumeSeconds: resume,
                    requestID: request.id,
                    generation: generation,
                    engineID: engineID
                )
            }
        }
    }

    /// Wait for this exact engine generation to become seekable. A same-URI
    /// reopen cannot consume or clear the new generation's pending resume.
    ///
    /// 先判断再睡：反过来的话，即使源一开始就绪也要白等 100 ms，
    /// 片头那一百多毫秒会先放出画面和声音再跳走（观感上"闪一下"）。
    func seekPendingResumeIfNeeded(
        resumeSeconds: Double,
        requestID: PlaybackRequest.ID,
        generation: UInt64,
        engineID: ObjectIdentifier
    ) async {
        if PlaybackPreferences.danmakuDiagnosticsEnabled {
            // 与弹幕「时间轴对齐」日志同落 diagnostics.jsonl，时间戳可比：
            // 判断弹幕注入与续播 seek 的先后竞态。
            PlaybackLog.info(
                "续播定位等待开始 resume=\(String(format: "%.1f", resumeSeconds))s request=\(requestID)"
            )
        }
        while !Task.isCancelled {
            guard sourceGeneration == generation,
                  expectedRequestID == requestID,
                  let engine,
                  ObjectIdentifier(engine) == engineID
            else { return }
            if state.state == .error || state.state == .stopped || state.state == .closed {
                return
            }
            // open 在后台执行期间 activeRequest 尚未就绪，等 finishOpenSuccess 完成且源 ready
            if activeRequest?.id == requestID, isSourceReady, state.duration > .zero {
                let duration = Double(state.duration.microseconds) / 1_000_000
                let target = min(max(resumeSeconds, 0), max(duration - 0.5, 0))
                if PlaybackPreferences.danmakuDiagnosticsEnabled {
                    PlaybackLog.info(
                        "续播定位 seek target=\(String(format: "%.1f", target))s duration=\(String(format: "%.1f", duration))s"
                    )
                }
                do {
                    recordSeek(toSeconds: target, kind: "resume")
                    try engine.seek(to: .seconds(target))
                } catch {
                    setupError = "续播定位失败：\(error)"
                    if PlaybackPreferences.danmakuDiagnosticsEnabled {
                        PlaybackLog.warning("续播定位失败 error=\(error)")
                    }
                }
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    func samePlaybackSource(_ lhs: PlaybackRequest, _ rhs: PlaybackRequest) -> Bool {
        lhs.uri == rhs.uri
            && lhs.authHeader == rhs.authHeader
            && lhs.securityScopedURL == rhs.securityScopedURL
            && lhs.sessionContext == rhs.sessionContext
    }

    /// 打开源。**open 的阻塞段在 `engineOpenQueue` 执行**；完成/失败回主线程落状态。
    ///
    /// 换片 / 上一发 open 还在飞：旧引擎**让位退役**——`stop()` 在 open 期间只登记
    /// 意图（ErikaKit 让位契约），由旧 open 收尾在后台补做；引擎引用随旧 open 的
    /// 闭包移交后台，析构也发生在后台，主线程全程不碰旧引擎。
    func open(_ source: PlaybackSource, securityScopedURL: URL? = nil, request: PlaybackRequest) {
        let generation = sourceGeneration
        let hadOpeningAttempt = openingAttempt != nil
        if let openingAttempt {
            openingAttempt.cancel()
            clearOpeningState(attempt: openingAttempt)
        }
        if hasLoadedSource || hadOpeningAttempt {
            // 换片：先把上一段会话的账结掉（播放时长/缓冲次数/卡死次数），再退役旧引擎。
            state.finishSession(reason: "superseded")
            playerLog.info("open 前 stop 旧源并重建引擎（换片/上一发 open 在飞）")
            try? engine?.stop()
            hasLoadedSource = false
            currentlyOpenURI = nil
            releaseSecurityScopedResource()
            resetEngine()
        }
        // A fresh state object is the event-generation boundary. The cancelled
        // old consumer only holds the old state weakly, so buffered events cannot
        // overwrite this source's position or duration.
        state = PlayerState()
        guard let engine = prepareEngine() else {
            finishOpenFailure(request: request, generation: generation,
                              attempt: nil,
                              error: setupError ?? "内核创建失败")
            return
        }
        guard Self.activeOpenAttempts < Self.maximumConcurrentOpenAttempts else {
            finishOpenFailure(
                request: request,
                generation: generation,
                attempt: nil,
                error: "后台媒体打开任务已满（可能有超时请求仍未退出），请稍后重试"
            )
            return
        }
        Self.activeOpenAttempts += 1
        let scopeLease: PlaybackSecurityScopeLease?
        if let securityScopedURL, securityScopedURL.startAccessingSecurityScopedResource() {
            scopeLease = PlaybackSecurityScopeLease {
                securityScopedURL.stopAccessingSecurityScopedResource()
            }
        } else {
            scopeLease = nil
        }
        let attempt = PlaybackOpenAttempt(scopeLease: scopeLease)
        openingAttempt = attempt
        openingRequestID = request.id
        openingSourceURI = source.uri
        scheduleOpenWatchdog(for: request, generation: generation, attempt: attempt)
        PlaybackLog.append("open() 派发到后台 title=\(request.title)")
        // 主线程快照：队列闭包只碰引擎，不读 @MainActor 状态。
        let volumeNow = muted ? 0.0 : volume
        let rateNow = rate
        let scaleNow = subtitleScale
        let danmakuPrefs = danmakuPrefsSnapshot()
        let engineID = ObjectIdentifier(engine)
        Self.engineOpenQueue.async { [weak self] in
            var openError: Error?
            do {
                try engine.open(source)
            } catch {
                openError = error
            }
            // open 期间被让位的 stop（取消/换片）意味着成果已被放弃，收尾已补 stop：
            // 必须跳过 play/参数设置——内核 stop 之后 play 是合法的重播，不能让
            // 已放弃的源幽灵出声。
            let interrupted = engine.openWasInterrupted
            if openError == nil, !interrupted, !attempt.cancelled {
                try? engine.setVolume(volumeNow)
                try? engine.setRate(rateNow)
                if scaleNow != 1.0 {
                    try? engine.setSubtitleScale(scaleNow)
                }
                do {
                    try Self.applyDanmakuPrefs(danmakuPrefs, to: engine)
                } catch {
                    playerLog.warning("弹幕偏好应用失败，继续播放 error=\(error)")
                }
                if !attempt.cancelled {
                    try? engine.play()
                }
            }
            if attempt.cancelled, !interrupted, openError == nil {
                try? engine.stop()
            }
            let error = openError
            Task { @MainActor [weak self] in
                defer { Self.activeOpenAttempts -= 1 }
                guard let self else {
                    try? engine.stop()
                    attempt.scopeLease?.releaseOnce()
                    return
                }
                if attempt.cancelled {
                    self.finishOpenSuperseded(request: request, generation: generation, attempt: attempt)
                } else if let error {
                    self.finishOpenFailure(request: request, generation: generation,
                                           attempt: attempt, error: "\(error)")
                } else if interrupted {
                    self.finishOpenSuperseded(request: request, generation: generation,
                                              attempt: attempt)
                } else {
                    self.finishOpenSuccess(request: request, generation: generation, uri: source.uri,
                                           attempt: attempt, engine: engine, engineID: engineID)
                }
            }
        }
    }

    /// open 成功完成（主线程）：仍然是当前代次才落状态，否则按孤儿引擎处理。
    private func finishOpenSuccess(
        request: PlaybackRequest,
        generation: UInt64,
        uri: String,
        attempt: PlaybackOpenAttempt,
        engine: any PlaybackEngine,
        engineID: ObjectIdentifier
    ) {
        clearOpeningState(attempt: attempt)
        guard !attempt.cancelled,
              sourceGeneration == generation,
              let currentEngine = self.engine,
              ObjectIdentifier(currentEngine) == engineID
        else {
            // 期间已换片/取消：孤儿引擎在队列上补 stop（防幽灵音频），作用域即刻释放。
            PlaybackLog.info("open() 成功但已过期，孤儿引擎补 stop title=\(request.title)")
            Self.engineOpenQueue.async { try? engine.stop() }
            attempt.scopeLease?.releaseOnce()
            return
        }
        hasLoadedSource = true
        activeRequest = request
        // open 在飞期间音量/倍速可能又变了（让位路径会丢弃引擎侧设置），按当前值重同步。
        try? engine.setVolume(muted ? 0 : volume)
        try? engine.setRate(rate)
        // 队列闭包的 play() 已经走完，这里补放 open 在飞期间暂存的暂停意图才不被盖掉。
        if openingPauseIntent {
            openingPauseIntent = false
            try? engine.pause()
            PlaybackLog.append("open() 成功，补放 open 在飞期间的暂停意图 title=\(request.title)")
        }
        setupError = nil
        currentlyOpenURI = uri
        activeSecurityScopeLease = attempt.scopeLease
        engineIsActive = true
        playerLog.info("open 成功 title=\(currentTitle ?? "?")")
        // 结构化结果行：`elapsed_ms` 就是 issue 里「open 花了 16/36/18 秒」那个数。
        PlaybackLog.event(.openDone, fields: [
            "ok": .boolean(true),
            "elapsed_ms": .integer(openElapsedMilliseconds()),
        ])
        startStallWatchdog()
    }

    /// open 失败（主线程）：过期时只释放作用域；当前代次走完整失败路径
    /// （失效 expectedRequestID、记 failedRequestID、丢弃半开引擎）。
    private func finishOpenFailure(
        request: PlaybackRequest,
        generation: UInt64,
        attempt: PlaybackOpenAttempt?,
        releaseScope: Bool = true,
        error: String
    ) {
        if let attempt { clearOpeningState(attempt: attempt) }
        guard sourceGeneration == generation else {
            attempt?.scopeLease?.releaseOnce()
            return
        }
        if releaseScope { attempt?.scopeLease?.releaseOnce() }
        if expectedRequestID == request.id {
            expectedRequestID = nil
            sourceGeneration &+= 1
        }
        // 引擎可能停在半开状态，直接丢弃重建；close 是终态，留着复用到下次 open 必失败。
        resetEngine()
        failedRequestID = request.id
        setupError = error
        playerLog.error("open 失败 error=\(error) title=\(request.title)")
        PlaybackLog.event(.openDone, fields: [
            "ok": .boolean(false),
            "elapsed_ms": .integer(openElapsedMilliseconds()),
            "error": .string(error),
        ], level: .error)
    }

    /// open 成功但成果已被让位（open 期间用户取消/换片，收尾已补 stop）：释放作用域即可。
    private func finishOpenSuperseded(
        request: PlaybackRequest,
        generation: UInt64,
        attempt: PlaybackOpenAttempt
    ) {
        clearOpeningState(attempt: attempt)
        attempt.scopeLease?.releaseOnce()
        PlaybackLog.info("open() 成果已让位（收尾已 stop）title=\(request.title)")
        guard sourceGeneration == generation else { return }
        // 同代次却被让位：代次没动说明没有换片/取消落地，理论上到不了；记日志留痕。
        PlaybackLog.info("open() 让位但代次未变（异常路径）title=\(request.title)")
    }

    private func clearOpeningState(attempt: PlaybackOpenAttempt) {
        guard openingAttempt === attempt else { return }
        openingWatchdogTask?.cancel()
        openingWatchdogTask = nil
        openingAttempt = nil
        openingRequestID = nil
        openingSourceURI = nil
    }

    /// open 看门狗：内核对 DNS 解析没有任何超时，弱网下 open 理论上可无限挂。
    /// 60s 仍未完成就强制转失败，给用户确定的错误 + 重试入口；后台 open 继续跑，
    /// 完成时按过期/让位处理，不会串台。
    private func scheduleOpenWatchdog(
        for request: PlaybackRequest,
        generation: UInt64,
        attempt: PlaybackOpenAttempt
    ) {
        openingWatchdogTask?.cancel()
        openingWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.openWatchdogTimeout)
            guard let self, !Task.isCancelled else { return }
            guard self.openingAttempt === attempt,
                  self.openingRequestID == request.id,
                  self.expectedRequestID == request.id,
                  self.sourceGeneration == generation else { return }
            PlaybackLog.info("open 看门狗触发（60s）title=\(request.title)")
            attempt.cancel()
            try? self.engine?.stop()
            self.finishOpenFailure(request: request, generation: generation,
                                   attempt: attempt,
                                   releaseScope: false,
                                   error: "连接媒体服务器超时，请检查网络后重试")
        }
    }

    /// 弹幕偏好快照（主线程采集，open 队列闭包里应用到引擎）。
    /// 这是**唯一的**偏好→引擎映射；实例路径（`applyDanmakuPreferences`）
    /// 也走它，不再各写一份字段对应表。
    struct DanmakuPrefsSnapshot {
        var enabled: Bool
        var opacity: Double
        var displayArea: Double
        var blockTop: Bool
        var blockBottom: Bool
        var blockScroll: Bool
        var mergeDuplicates: Bool
        var allowStacking: Bool
        var globalOffsetSeconds: Double
    }

    /// 主线程采集当前偏好为快照。
    func danmakuPrefsSnapshot() -> DanmakuPrefsSnapshot {
        DanmakuPrefsSnapshot(
            enabled: danmakuEnabled,
            opacity: danmakuOpacity,
            displayArea: danmakuDisplayArea,
            blockTop: danmakuBlockTop,
            blockBottom: danmakuBlockBottom,
            blockScroll: danmakuBlockScroll,
            mergeDuplicates: danmakuMergeDuplicates,
            allowStacking: danmakuAllowStacking,
            globalOffsetSeconds: danmakuGlobalOffsetSeconds)
    }

    /// 弹幕偏好 → 引擎的唯一映射（open 队列闭包与实例路径共用）。
    static func applyDanmakuPrefs(_ prefs: DanmakuPrefsSnapshot, to engine: any PlaybackEngine) throws {
        var config = try engine.danmakuConfig()
        config.enabled = prefs.enabled
        config.opacity = Float(prefs.opacity)
        config.displayArea = Float(prefs.displayArea)
        config.blockTop = prefs.blockTop
        config.blockBottom = prefs.blockBottom
        config.blockScroll = prefs.blockScroll
        config.mergeDuplicates = prefs.mergeDuplicates
        config.allowStacking = prefs.allowStacking
        try engine.setDanmakuConfig(config)
        try engine.setDanmakuGlobalOffset(.seconds(prefs.globalOffsetSeconds))
    }

    func stopPlayback() {
        playerLog.info("stopPlayback hasLoadedSource=\(hasLoadedSource) state=\(state.state)")
        state.finishSession(reason: "user")
        // open 在飞时的收口：看门狗与在飞标记全部清掉。在飞引擎的让位登记
        // （下面的 stop()）由其 open 收尾补做，完成回调按过期代次落空。
        openingWatchdogTask?.cancel()
        openingWatchdogTask = nil
        openingAttempt?.cancel()
        openingAttempt = nil
        openingRequestID = nil
        openingSourceURI = nil
        // 音量尾去抖的落盘任务大概率等不到 300ms（控制器即将销毁）：收口补写一次，
        // 否则「调完音量立刻退出」会丢掉最后一拍音量。
        volumePersistTask?.cancel()
        PlaybackPreferences.volume = volume
        try? engine?.stop()
        // 清空去重标记：否则下次打开同一视频时 openIfNeeded 会误判「已打开同一个源」
        // 直接跳过（画面停在旧帧/黑屏，进度丢失）。
        // 注意：这里只 stop 不 close。Erika 的 close() 是终态——closed 后不能再 open，
        // 所以 App 层一律不复用引擎：退出（这里）和换片（open() 里）都走 stop +
        // resetEngine 重建。顺带也让设置页换内核在下一次播放自然生效。
        // stop 之后旧源已经不算“已加载”，必须清掉标记，否则下一次 open 会误以为要换片，
        // 白白把还没加载新源的引擎丢掉重建（无害但没必要）。
        hasLoadedSource = false
        currentlyOpenURI = nil
        activeRequest = nil
        expectedRequestID = nil
        sourceGeneration &+= 1
        // 先记 false:stopPlayback 执行到后半段时引擎已被 stop + resetEngine,
        // 关闭播放器的另一条收口路径若在这期间查 engineIsActive 不会再误停。
        engineIsActive = false
        releaseSecurityScopedResource()
        // 退出播放后把引擎整个丢掉，下次播放重新创建。
        // 这样即使某个内核的 stop/detach 组合在个别版本里会让旧实例进入不可 reopen 的状态，
        // 也不会影响下一次播放；换内核也在下一次播放自然落地。
        resetEngine()
        // 引擎析构后 malloc 仍攥着空闲页不还系统（phys_footprint 高位横盘）：
        // 2s / 25s 两拍 pressure relief（第二拍等内核 demux 线程尾巴退出）。
        MallocPressureRelief.scheduleAfterStop()
        PlaybackLog.info("stopPlayback() 完成 hasLoadedSource=\(hasLoadedSource)")
    }

    func playbackReportSnapshot(for requestID: PlaybackRequest.ID) -> PlaybackReportSnapshot? {
        guard reportableRequestID == requestID else { return nil }
        let reportState: PlaybackReportSnapshot.State
        switch state.state {
        case .paused:
            reportState = .paused
        case .stopped:
            reportState = .stopped
        case .error:
            reportState = .error
        case .idle, .opening, .ready, .playing, .closed:
            reportState = .active
        }
        return PlaybackReportSnapshot(
            state: reportState,
            positionSeconds: Double(state.position.microseconds) / 1_000_000,
            durationSeconds: Double(state.duration.microseconds) / 1_000_000,
            sourceOpenFailed: failedRequestID == requestID
        )
    }

    func resetEngine() {
        stopStallWatchdog()
        resumeTask?.cancel()
        resumeTask = nil
        eventTask?.cancel()
        eventTask = nil
        danmakuOverlay.reset()
        engine = nil
        engineIsActive = false
        openingPauseIntent = false
        failedRequestID = nil
        danmakuTracks = []
        danmakuGlobalOffsetSeconds = 0
        externalSubtitleNames = [:]
        chapterSession.reset()
        skipTimesHint = nil
        // engine 没了就一定不在播，息屏令牌和系统登记立刻还回去（stopPlayback 也经过这里）。
        syncSystemPlaybackState()
        // 注意：这里不要 state.reset()。closePlayer 的调用顺序是
        // stopPlayback() → dismissPlayer()，dismissPlayer 还要读 state.position 上报 Stopped。
        // 等下次 open 时自然会 reset。
        setupError = nil
    }

    func releaseSecurityScopedResource() {
        activeSecurityScopeLease?.releaseOnce()
        activeSecurityScopeLease = nil
    }

    // MARK: - 播放事件与卡死看门狗

    private static func sourceKind(for uri: String) -> String {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return "network" }
        if uri.hasPrefix("/") || uri.hasPrefix("file://") { return "local" }
        return "other"
    }

    /// 距本次 open 起点多少毫秒（没记起点时给 0，不编数）。
    private func openElapsedMilliseconds() -> Int64 {
        guard let openStartedAt else { return 0 }
        return Int64(Date().timeIntervalSince(openStartedAt) * 1000)
    }

    /// 每 2s 查一次：**在播且不在缓冲**，位置却连续 5s 不动 —— 这正是「播到一半就停」
    /// 的形态（demux 线程死掉/事件断供，连 buffering 事件都没有，UI 上看不出在等什么）。
    /// 触发时记 warning 级 stall（recovered=false），位置恢复后补一条 info（recovered=true），
    /// 两条的 `frozen_ms` 相减即这轮卡死时长；`stall_count` 会进 `session.end` 汇总。
    private func startStallWatchdog() {
        stallWatchdogTask?.cancel()
        lastStallCheckPosition = state.position
        frozenSeconds = 0
        stallReported = false
        stallWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.checkStall()
            }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
    }

    private func checkStall() {
        // 暂停 / 缓冲 / 已停都不算卡死：缓冲有自己的 buffer.* 事件记账。
        // 这里刻意用**原始**缓冲态（不是 `isBufferingSustained`）：卡死看门狗是诊断真值，
        // 不能被 UI 侧的迟滞挡住。
        guard state.state == .playing, !state.isBuffering else {
            lastStallCheckPosition = state.position
            frozenSeconds = 0
            stallReported = false
            return
        }
        if state.position == lastStallCheckPosition {
            frozenSeconds += 2
            if frozenSeconds >= 5, !stallReported {
                stallReported = true
                state.noteStall()
                PlaybackLog.event(.stall, fields: [
                    "recovered": .boolean(false),
                    "frozen_ms": .integer(Int64(frozenSeconds * 1000)),
                    "position_ms": .integer(state.position.microseconds / 1000),
                ], level: .warning)
            }
        } else {
            if stallReported {
                PlaybackLog.event(.stall, fields: [
                    "recovered": .boolean(true),
                    "frozen_ms": .integer(Int64(frozenSeconds * 1000)),
                    "position_ms": .integer(state.position.microseconds / 1000),
                ])
            }
            frozenSeconds = 0
            stallReported = false
            lastStallCheckPosition = state.position
        }
    }

    // MARK: - 控制

    func togglePlayPause() {
        // open 在飞（loading 层）时按下播放/暂停：把意图记下来，open 成功后补 pause。
        // 此时没有媒体内容，引擎侧 play/pause 都是丢弃；而 open 成功路径的 play()
        // 在队列闭包里，任何更早的 pause 都会被它盖掉。
        if openingRequestID != nil {
            openingPauseIntent = true
            PlaybackLog.append("open 在飞，暂存暂停意图（open 成功后生效）")
            return
        }
        guard let engine else { return }
        do {
            if state.state == .playing { try engine.pause() } else { try engine.play() }
        } catch {
            setupError = "\(error)"
        }
    }

    func seek(toFraction fraction: Double) {
        guard let engine, state.duration > .zero else { return }
        let micros = Double(state.duration.microseconds) * min(max(fraction, 0), 1)
        recordSeek(toSeconds: micros / 1_000_000, kind: "scrub")
        try? engine.seek(to: .microseconds(Int64(micros)))
    }

    func skip(by seconds: Double) {
        guard let engine else { return }
        var target = Double(state.position.microseconds) + seconds * 1_000_000
        // 别越过片长：seek 到 EOF 之后内核会进「audio output stalled at EOF」
        // 错误风暴（逐帧重发 .failed，实测一次刷了 6302 条），画面冻结假死。
        if state.duration > .zero {
            target = min(target, Double(state.duration.microseconds) - 500_000)
        }
        recordSeek(toSeconds: max(0, target) / 1_000_000, kind: "skip")
        try? engine.seek(to: .microseconds(Int64(max(0, target))))
    }

    /// 记一条 seek 事件（来源区分见 `PlaybackEvent.seek`）。在真正调内核之前记，
    /// 这样即使 seek 本身失败，日志里也有「用户想跳去哪」这一笔。
    private func recordSeek(toSeconds target: Double, kind: String) {
        PlaybackLog.event(.seek, fields: [
            "from_ms": .integer(state.position.microseconds / 1000),
            "to_ms": .integer(Int64(target * 1000)),
            "kind": .string(kind),
        ])
    }

    // MARK: - 章节 / 跳过片头片尾

    /// 当前应展示的「跳过」提示(由 UI 在 position 变化时读取)。
    /// 设置里的跳过片头/片尾开关在这里门控——关闭对应类别的提示直接静默,
    /// 播放中改动即时生效(SkipPromptView 每拍进度都会重读本属性)。
    var currentSkipPrompt: SkipPrompt? {
        guard let prompt = chapterSession.prompt(
            at: Double(state.position.microseconds) / 1_000_000,
            duration: Double(state.duration.microseconds) / 1_000_000,
            isPlaying: state.state == .playing
        ) else { return nil }
        return Self.promptGatedByPreferences(
            prompt,
            skipIntro: PlaybackPreferences.skipIntroEnabled,
            skipOutro: PlaybackPreferences.skipOutroEnabled
        )
    }

    /// 跳过偏好门控（纯函数便于单测）：两个开关各自静默对应类别的提示。
    static func promptGatedByPreferences(
        _ prompt: SkipPrompt,
        skipIntro: Bool,
        skipOutro: Bool
    ) -> SkipPrompt? {
        switch prompt.kind {
        case .opening:
            return skipIntro ? prompt : nil
        case .credits:
            return skipOutro ? prompt : nil
        }
    }

    /// 保底片尾跳过落点（纯函数便于单测）：片长 − 保留秒数（设置可选 0–30s，
    /// 默认 10），不小于当前位置（不往回跳）；保留 0 时落点贴 EOF，钳到
    /// 片长 − 0.5s，与 skip(by:) 同一道防线防内核 EOF 错误风暴。
    static func endCreditsSkipTarget(
        position: Double,
        duration: Double,
        retentionSeconds: Int
    ) -> Double {
        let retention = Double(retentionSeconds)
        return max(min(duration - retention, duration - 0.5), position)
    }

    /// 跳到某个章节起点。
    func seek(toChapter chapter: PlaybackChapter) {
        guard let engine else { return }
        recordSeek(toSeconds: max(0, chapter.startSeconds), kind: "chapter")
        try? engine.seek(to: .seconds(max(0, chapter.startSeconds)))
    }

    /// 弹幕装载完成后由 `DanmakuCoordinator` 调用,下发跳过片头提示。
    /// requestID 守卫:提示与当前播放请求不匹配(旧代的迟到回调)直接丢弃。
    func applySkipTimesHint(_ hint: DanmakuKit.DanmakuIntroHint, requestID: PlaybackRequest.ID) {
        guard activeRequest?.id == requestID else { return }
        skipTimesHint = hint
        if chapterSession.applySkipTimesHint(
            startSeconds: hint.startSeconds,
            endSeconds: hint.endSeconds,
            source: SkipMarkSource(rawValue: hint.source.rawValue) ?? .danmaku
        ) {
            PlaybackLog.info(
                "跳过片头提示 source=\(hint.source.rawValue)"
                    + " start=\(hint.startSeconds.map { String(format: "%.0f", $0) } ?? "0")"
                    + " end=\(String(format: "%.0f", hint.endSeconds)) evidence=\(hint.evidenceCount)"
            )
        }
    }

    /// 处理当前「跳过」提示并跳到段末 / 接近结尾。
    func performSkip() {
        guard let prompt = currentSkipPrompt else { return }
        let target: Double
        switch prompt {
        case .mark(let mark):
            // 与 skip(by:) 同一道防线:跳过目标越过片长会触发内核 EOF 错误风暴。
            var markEnd = mark.endSeconds
            if state.duration > .zero {
                let duration = Double(state.duration.microseconds) / 1_000_000
                markEnd = min(markEnd, max(duration - 0.5, 0))
            }
            target = markEnd
            chapterSession.noteSkipped(mark)
            PlaybackLog.info("跳过 \(mark.kind) → \(target)s")
        case .endCredits(let position):
            let duration = Double(state.duration.microseconds) / 1_000_000
            target = Self.endCreditsSkipTarget(
                position: position,
                duration: duration,
                retentionSeconds: PlaybackPreferences.outroRetentionSeconds
            )
            chapterSession.noteEndCreditsSkipped()
            PlaybackLog.append("保底跳过片尾 → \(target)s 保留=\(PlaybackPreferences.outroRetentionSeconds)s")
        }
        recordSeek(toSeconds: max(0, target), kind: "auto")
        try? engine?.seek(to: .seconds(max(0, target)))
    }

    /// 章节列表(供 UI 的章节面板用)。
    var chapters: [PlaybackChapter] { chapterSession.chapters }

    /// 加载当前源的章节与可跳过片段。
    ///
    /// - 优先拉 MediaSegments(智能片头 / 片尾识别);失败(老版本 / 禁用)静默回退。
    /// - 章节列表走 `Chapters` field;从 MediaSegments 拿到的 Intro / Outro 优先作为
    ///   `skipMarks`(比名字启发式准),否则用章节列表跑 `ChapterNameHeuristicEvaluator`。
    /// - 时效守卫只认 `chapterRequestIsCurrent`:本链路与引擎 `open` 并发跑,此时
    ///   `activeRequest` 尚未就位、同请求的引擎重建也会推 `sourceGeneration`,两者
    ///   都不能当失效判据(否则守卫必败、章节静默全丢);跨请求换片由
    ///   `expectedRequestID` 同步更新兜住。
    ///
    /// 在 `@MainActor` 上调用(控制器本身就是 @MainActor)。
    func loadChapters(server: any JellyfinKit.MediaServer, for request: PlaybackRequest) async {
        guard let itemID = request.sessionContext?.itemID else {
            // 本地文件 / 无 item 时没有服务端章节,仅保留 90s 保底条,静默。
            return
        }

        // 章节列表。
        let fetchedChapters: [PlaybackChapter]
        do {
            let raw = try await server.chapters(itemID: itemID)
            fetchedChapters = buildChapters(from: raw)  // tick→秒,补 end
        } catch {
            PlaybackLog.info("章节拉取失败,仅保底:\(error)")
            fetchedChapters = []
        }
        guard chapterRequestIsCurrent(request) else {
            PlaybackLog.append("章节加载作废（已换片）")
            return
        }

        // 可跳过片段:优先 MediaSegments,回退章节启发式。
        let segmentMarks: [SkipMark]
        do {
            let segments = try await server.mediaSegments(itemID: itemID)
            segmentMarks = segments.map { segment in
                let skipKind: SkipKind = segment.kind == .intro ? .opening : .credits
                return SkipMark(
                    id: "\(segment.kind.rawValue)-\(segment.id)",
                    source: .mediaSegment,
                    kind: skipKind,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds
                )
            }
        } catch {
            // Emby 老版本 / 未装 Intro 插件没有这个端点，静默回退可；但其余失败
            // （网络 / 鉴权）无线索就没法排查「为什么没跳片头」，落一条 info（默认档可见）。
            PlaybackLog.info("MediaSegments 拉取失败,回退章节启发式:\(error)")
            segmentMarks = []
        }
        guard chapterRequestIsCurrent(request) else {
            return
        }

        let skipMarks: [SkipMark]
        if !segmentMarks.isEmpty {
            skipMarks = segmentMarks
        } else {
            // 启发式按章节名/位置判片头片尾需要片长；本链路与引擎 open 并发，
            // 呈现瞬间 duration 可能还是 0（totalSeconds=0 直接返回空，标记静默丢）。
            // 等 duration 到达再算，10s 兜底（超时按原行为回落），换片每拍即退。
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while state.duration <= .zero, clock.now < deadline {
                guard chapterRequestIsCurrent(request) else { return }
                if state.state == .error { break }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            let total = Double(state.duration.microseconds) / 1_000_000
            skipMarks = ChapterNameHeuristicEvaluator()
                .skipMarks(chapters: fetchedChapters, totalSeconds: max(total, 0))
        }
        guard chapterRequestIsCurrent(request) else {
            return
        }

        chapterSession.chapters = fetchedChapters
        chapterSession.skipMarks = skipMarks
        // 章节链路后到时补合并跳过片头提示(章节先到的情况由 applySkipTimesHint
        // 即时注入,两向覆盖)。MediaSegments 已给片头时注入内部会让位,无需区分。
        if let hint = skipTimesHint {
            _ = chapterSession.applySkipTimesHint(
                startSeconds: hint.startSeconds,
                endSeconds: hint.endSeconds,
                source: SkipMarkSource(rawValue: hint.source.rawValue) ?? .danmaku
            )
        }
        PlaybackLog.info("章节加载 chapters=\(fetchedChapters.count) skips=\(skipMarks.count)")
    }

    /// 章节加载的时效守卫:装配层当前请求是否仍是这条。
    /// 只防「用户已换片」;与引擎 open / 引擎重建无关(见 loadChapters 头注释)。
    private func chapterRequestIsCurrent(_ request: PlaybackRequest) -> Bool {
        expectedRequestID == request.id && !Task.isCancelled
    }

    /// 把 Jellyfin 章节(tick→秒)补上结束边界变成 UI 章节列表。
    private func buildChapters(from raw: [JellyfinKit.JellyfinChapter]) -> [PlaybackChapter] {
        raw.enumerated().map { index, jchapter in
            var nextStart: Double?
            let nextIndex = raw.index(raw.startIndex, offsetBy: index + 1)
            if index + 1 < raw.count {
                nextStart = raw[nextIndex].startSeconds
            }
            return PlaybackChapter(
                id: index,
                name: jchapter.name,
                startSeconds: jchapter.startSeconds,
                endSeconds: nextStart
            )
        }
    }

    func applyRate(_ newRate: Double) {
        rate = newRate
        try? engine?.setRate(newRate)
        if usesOverlayDanmakuRenderer { danmakuOverlay.setRate(newRate) }
    }

    // MARK: - 按住快进（右箭头长按 2x，松手恢复）

    /// 长按期间暂存的原速；nil = 不在长按态。
    /// 可观察：2x 提示徽章（PlayerHoldFastForwardBadge）按它显隐。
    private(set) var holdFastForwardRate: Double?

    var isHoldFastForwarding: Bool { holdFastForwardRate != nil }

    /// 进入临时 2 倍速。重复调用无副作用（autorepeat 每帧都会来）。
    func beginHoldFastForward() {
        guard holdFastForwardRate == nil else { return }
        holdFastForwardRate = rate
        applyRate(2.0)
    }

    /// 松手恢复原速。keyUp 丢失（切走 App 等）时由兜底路径调用，幂等。
    func endHoldFastForward() {
        guard let previous = holdFastForwardRate else { return }
        holdFastForwardRate = nil
        applyRate(previous)
    }

    func applyVolume(_ newVolume: Double) {
        volume = min(max(newVolume, 0), 1)
        try? engine?.setVolume(muted ? 0 : volume)
    }

    func adjustVolume(by delta: Double) {
        applyVolume(volume + delta)
    }

    func toggleMute() {
        muted.toggle()
        try? engine?.setVolume(muted ? 0 : volume)
    }

    /// 字幕字号 +/-（0.1 步进，0.5…3.0 夹紧）。
    func adjustSubtitleScale(by delta: Double) {
        subtitleScale = min(max(subtitleScale + delta, 0.5), 3.0)
        try? engine?.setSubtitleScale(subtitleScale)
    }

    func resetSubtitleScale() {
        subtitleScale = 1.0
        try? engine?.setSubtitleScale(1.0)
    }

    func copyImportedSubtitle(_ source: URL) -> URL? {
        let scope = source.startAccessingSecurityScopedResource()
        defer { if scope { source.stopAccessingSecurityScopedResource() } }
        do {
            let directory = AppStorageDirectories.importedSubtitles
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(UUID().uuidString)-\(source.lastPathComponent)")
            try FileManager.default.copyItem(at: source, to: destination)
            AppDiagnostics.requestStorageMaintenance()
            return destination
        } catch {
            setupError = "字幕文件读取失败：\(error)"
            return nil
        }
    }

    /// 出错后重试：用最近的请求重新打开。
    func retryLast() {
        guard let request = lastRequest else {
            PlaybackLog.info("retryLast 没有 lastRequest")
            return
        }
        PlaybackLog.append("retryLast title=\(request.title)")
        open(request: request)
    }


    /// 硬解 / 丢帧等实时数字的单行快照，诊断日志用（播放页信息面板已改为
    /// 直接读 `latestStats` 分列排版，不走这条拼接线）。
    /// 具体列由 `PlaybackEngine.debugStatsLine()` 决定（拿不到的内核填 0）。
    func statsLine() -> String {
        engine?.debugStatsLine() ?? "—"
    }

    // MARK: - DanmakuPlaybackHosting（弹幕编排器注入入口）

    func waitUntilReady(uuid: UUID, timeout: Duration) async -> Bool {
        await waitUntilSourceReady(for: uuid, timeout: timeout) != nil
    }

    func replaceDanmaku(
        uuid: UUID,
        entries: [DanmakuJSONParser.Entry],
        json: String?,
        name: String,
        offset: Duration
    ) throws -> Bool {
        guard let source = currentSourceToken(uuid: uuid) else { return false }
        return try replaceDanmaku(
            entries: entries, json: json, name: name, offset: offset, for: source
        )
    }

    func clearDanmaku(uuid: UUID) throws -> Bool {
        guard let source = currentSourceToken(uuid: uuid) else { return false }
        return try clearDanmaku(for: source)
    }

    /// 当前播放源代次 token；弹幕编排器用 `uuid`（请求 id）跨 await 后重新绑定。
    func currentSourceToken(uuid: UUID) -> PlaybackSourceGeneration? {
        guard expectedRequestID == uuid, let activeRequest, activeRequest.id == uuid, isSourceReady else {
            return nil
        }
        return PlaybackSourceGeneration(requestID: uuid, value: sourceGeneration)
    }
}
