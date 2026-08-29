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
            return (self.state.state == .playing, self.state.isBuffering)
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
    /// Changes as soon as a new request is presented, before its engine opens.
    var sourceGeneration: UInt64 = 0
    /// 最近一次请求（出错重试用）。
    var lastRequest: PlaybackRequest?

    var eventTask: Task<Void, Never>?
    var resumeTask: Task<Void, Never>?
    var expectedRequestID: PlaybackRequest.ID?
    var activeRequest: PlaybackRequest?
    var activeSecurityScopedURL: URL?
    var activeSecurityScope = false
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
            PlaybackLog.append(
                "PlaybackController prepareEngine 成功 kernel=\(engine.descriptor.id) "
                    + "danmaku=\(usesOverlayDanmakuRenderer ? "overlay" : "kernel")"
            )
            return engine
        } catch {
            setupError = "\(error)"
            PlaybackLog.append("PlaybackController prepareEngine 失败 error=\(error)")
            return nil
        }
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
        PlaybackLog.append("openIfNeeded title=\(request.title)")
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
        PlaybackLog.append("PlaybackController open(request) title=\(request.title) hasLoadedSource=\(hasLoadedSource)")
        var headers: [String: String] = [:]
        if let authHeader = request.authHeader {
            headers["Authorization"] = authHeader
        }
        let readAhead = PlaybackPreferences.httpReadAheadBytes
        // 诊断「改了预读档位没生效」：把本次真正传给内核的值打进日志。
        PlaybackLog.append("openPreparedRequest readAhead=\(readAhead.map { "\($0 / 1024 / 1024) MiB" } ?? "默认(2 MiB)")")
        let opened = open(
            PlaybackSource(
                uri: request.uri,
                headers: headers,
                // 本地文件路径没有预取语义，内核会忽略；统一带上无妨。
                readAheadBytes: readAhead
            ),
            securityScopedURL: request.securityScopedURL
        )
        reportableRequestID = request.id
        guard opened, let engine else {
            // A failed open may leave the fresh PlayerState in idle without an
            // error event. Invalidate the presentation boundary so async
            // subtitle/danmaku waiters finish instead of polling forever.
            if expectedRequestID == request.id {
                expectedRequestID = nil
                sourceGeneration &+= 1
            }
            failedRequestID = request.id
            return
        }
        activeRequest = request
        // 续播位置不立刻 seek（源还没就绪），挂到 pending 等 duration 到达。
        if let resume = request.resumeSeconds, resume >= 30 {
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
        while !Task.isCancelled {
            guard sourceGeneration == generation,
                  expectedRequestID == requestID,
                  activeRequest?.id == requestID,
                  let engine,
                  ObjectIdentifier(engine) == engineID
            else { return }
            if state.state == .error || state.state == .stopped || state.state == .closed {
                return
            }
            if isSourceReady, state.duration > .zero {
                let duration = Double(state.duration.microseconds) / 1_000_000
                let target = min(max(resumeSeconds, 0), max(duration - 0.5, 0))
                do {
                    try engine.seek(to: .seconds(target))
                } catch {
                    setupError = "续播定位失败：\(error)"
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

    @discardableResult
    func open(_ source: PlaybackSource, securityScopedURL: URL? = nil) -> Bool {
        // 换片：先 stop 旧源，再整体丢弃重建引擎。
        //
        // 两个理由：
        // 1. Erika 的 `close()` 是终态——同一 presenter close 后不能再 open（实测抛
        //    `ErikaError "player is closed"`），所以一律不复用旧引擎；
        // 2. 重建是「换内核」的落地时机——`prepareEngine()` 会重新读注册表的选择。
        //
        // `prepareEngine()` 在下面会重建新引擎。
        if hasLoadedSource {
            playerLog.info("open 前 stop 旧源并重建引擎（换片）")
            PlaybackLog.append("open() 前 stop 旧源并重建引擎（换片）")
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
        guard let engine = prepareEngine() else { return false }
        let acquiredScope = securityScopedURL?.startAccessingSecurityScopedResource() == true
        do {
            PlaybackLog.append("open() 开始")
            try engine.open(source)
            hasLoadedSource = true
            try engine.setVolume(muted ? 0 : volume)
            try engine.setRate(rate)
            if subtitleScale != 1.0 {
                try? engine.setSubtitleScale(subtitleScale)
            }
            do {
                try applyDanmakuPreferences(to: engine)
            } catch {
                playerLog.warning("弹幕偏好应用失败，继续播放 error=\(error)")
                PlaybackLog.append("danmaku preferences skipped error=\(error)")
            }
try engine.play()
            // 成功打开 → 清掉上一次的报错,别让错误条残留。
            setupError = nil
            currentlyOpenURI = source.uri
            activeSecurityScopedURL = acquiredScope ? securityScopedURL : nil
            activeSecurityScope = acquiredScope
            engineIsActive = true
            playerLog.info("open 成功")
            PlaybackLog.append("open() 成功 title=\(currentTitle ?? "?")")
            return true
        } catch {
            playerLog.error("open 失败 \(error)")
            PlaybackLog.append("open() 失败 error=\(error) title=\(currentTitle ?? "?")")
            currentlyOpenURI = nil
            if acquiredScope {
                securityScopedURL?.stopAccessingSecurityScopedResource()
            }
            // 引擎可能停在半开状态，直接丢弃重建；close 是终态，留着复用到下次 open 必失败。
            resetEngine()
            setupError = "\(error)"
            return false
        }
    }

    func stopPlayback() {
        playerLog.info("stopPlayback")
        PlaybackLog.append("stopPlayback() hasLoadedSource=\(hasLoadedSource) state=\(state.state)")
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
        PlaybackLog.append("stopPlayback() 完成 hasLoadedSource=\(hasLoadedSource)")
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
        resumeTask?.cancel()
        resumeTask = nil
        eventTask?.cancel()
        eventTask = nil
        danmakuOverlay.reset()
        engine = nil
        engineIsActive = false
        failedRequestID = nil
        danmakuTracks = []
        danmakuGlobalOffsetSeconds = 0
        externalSubtitleNames = [:]
        chapterSession.reset()
        // engine 没了就一定不在播，息屏令牌和系统登记立刻还回去（stopPlayback 也经过这里）。
        syncSystemPlaybackState()
        // 注意：这里不要 state.reset()。closePlayer 的调用顺序是
        // stopPlayback() → dismissPlayer()，dismissPlayer 还要读 state.position 上报 Stopped。
        // 等下次 open 时自然会 reset。
        setupError = nil
        PlaybackLog.append("resetEngine 完成")
    }

    func releaseSecurityScopedResource() {
        guard activeSecurityScope, let url = activeSecurityScopedURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        activeSecurityScope = false
    }

    // MARK: - 控制

    func togglePlayPause() {
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
        try? engine.seek(to: .microseconds(Int64(max(0, target))))
    }

    // MARK: - 章节 / 跳过片头片尾

    /// 当前应展示的「跳过」提示(由 UI 在 position 变化时读取)。
    var currentSkipPrompt: SkipPrompt? {
        chapterSession.prompt(
            at: Double(state.position.microseconds) / 1_000_000,
            duration: Double(state.duration.microseconds) / 1_000_000,
            isPlaying: state.state == .playing
        )
    }

    /// 跳到某个章节起点。
    func seek(toChapter chapter: PlaybackChapter) {
        guard let engine else { return }
        try? engine.seek(to: .seconds(max(0, chapter.startSeconds)))
    }

    /// 处理当前「跳过」提示并跳到段末 / 接近结尾。
    func performSkip() {
        guard let prompt = currentSkipPrompt else { return }
        let target: Double
        switch prompt {
        case .mark(let mark):
            target = mark.endSeconds
            chapterSession.noteSkipped(mark)
            PlaybackLog.append("跳过 \(mark.kind) → \(target)s")
        case .endCredits(let position):
            let duration = Double(state.duration.microseconds) / 1_000_000
            // 跳到片尾结束前 20 秒,保留一点尾声画面。
            target = max(duration - 20, position)
            chapterSession.noteEndCreditsSkipped()
            PlaybackLog.append("保底跳过片尾 → \(target)s")
        }
        try? engine?.seek(to: .seconds(max(0, target)))
    }

    /// 章节列表(供 UI 的章节面板用)。
    var chapters: [PlaybackChapter] { chapterSession.chapters }

    /// 加载当前源的章节与可跳过片段。
    ///
    /// - 优先拉 MediaSegments(智能片头 / 片尾识别);失败(老版本 / 禁用)静默回退。
    /// - 章节列表走 `Chapters` field;从 MediaSegments 拿到的 Intro / Outro 优先作为
    ///   `skipMarks`(比名字启发式准),否则用章节列表跑 `ChapterNameHeuristicEvaluator`。
    /// - 用 `source` 做代次守卫:换片 / 重开自动失效,不会把上一集的章节串进来。
    ///
    /// 在 `@MainActor` 上调用(控制器本身就是 @MainActor)。
    func loadChapters(server: JellyfinKit.JellyfinServer, for request: PlaybackRequest) async {
        guard let itemID = request.sessionContext?.itemID else {
            // 本地文件 / 无 item 时没有服务端章节,仅保留 90s 保底条,静默。
            return
        }
        let source = PlaybackSourceGeneration(requestID: request.id, value: sourceGeneration)

        // 章节列表。
        let fetchedChapters: [PlaybackChapter]
        do {
            let raw = try await server.chapters(itemID: itemID)
            fetchedChapters = buildChapters(from: raw)  // tick→秒,补 end
        } catch {
            PlaybackLog.append("章节拉取失败,仅保底:\(error)")
            fetchedChapters = []
        }
        guard !Task.isCancelled, currentSourceMatches(source) else { return }

        // 可跳过片段:优先 MediaSegments,回退章节启发式。
        let segmentMarks: [SkipMark]
        do {
            let segments = try await server.mediaSegments(itemID: itemID)
            segmentMarks = segments.map { segment in
                let skipKind: SkipKind = segment.kind == .intro ? .opening : .credits
                return SkipMark(
                    id: "\(segment.kind.rawValue)-\(segment.id)",
                    kind: skipKind,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds
                )
            }
        } catch {
            segmentMarks = []
        }
        guard !Task.isCancelled, currentSourceMatches(source) else { return }

        let total = Double(state.duration.microseconds) / 1_000_000
        let skipMarks: [SkipMark]
        if !segmentMarks.isEmpty {
            skipMarks = segmentMarks
        } else {
            skipMarks = ChapterNameHeuristicEvaluator()
                .skipMarks(chapters: fetchedChapters, totalSeconds: max(total, 0))
        }
        guard currentSourceMatches(source) else { return }

        chapterSession.chapters = fetchedChapters
        chapterSession.skipMarks = skipMarks
        PlaybackLog.append("章节加载 chapters=\(fetchedChapters.count) skips=\(skipMarks.count)")
    }

    @discardableResult
    private func currentSourceMatches(_ source: PlaybackSourceGeneration) -> Bool {
        source.value == sourceGeneration
            && source.requestID == activeRequest?.id
            && expectedRequestID == source.requestID
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
            PlaybackLog.append("retryLast 没有 lastRequest")
            return
        }
        PlaybackLog.append("retryLast title=\(request.title)")
        open(request: request)
    }


    /// 硬解 / 丢帧等实时数字，播放页的调试行用。
    /// 具体列由 `PlaybackEngine.debugStatsLine()` 决定（拿不到的内核填 0）。
    func statsLine() -> String {
        engine?.debugStatsLine() ?? "—"
    }

    // MARK: - DanmakuPlaybackHosting（弹幕编排器注入入口）

    func waitUntilReady(uuid: UUID, timeout: Duration) async -> Bool {
        await waitUntilSourceReady(for: uuid, timeout: timeout) != nil
    }

    func replaceDanmaku(uuid: UUID, json: String, name: String, offset: Duration) throws -> Bool {
        guard let source = currentSourceToken(uuid: uuid) else { return false }
        return try replaceDanmaku(json: json, name: name, offset: offset, for: source)
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
