import CoreGraphics
import DanmakuKit
import DiagnosticsKit
import ErikaKit
import Foundation
import ImageIO
import JellyfinKit
import Observation
import UniformTypeIdentifiers

/// App 层播放链路日志。走统一诊断管线（JSONL + OSLog，敏感字段自动脱敏）。
/// 与 ErikaKit 的 PlaybackLog 同一份文件，时间线上无缝。
let playerLog = AppDiagnostics.logger

/// 播放偏好跨启动记忆。弹幕渲染偏好由 HUD 修改后也在此统一保存。
@MainActor
enum PlaybackPreferences {
    private static let rateKey = "dev.jumusu.ocplayer.playback.rate"
    private static let volumeKey = "dev.jumusu.ocplayer.playback.volume"
    private static let mutedKey = "dev.jumusu.ocplayer.playback.muted"
    private static let subtitleScaleKey = "dev.jumusu.ocplayer.playback.subtitleScale"
    private static let danmakuEnabledKey = "dev.jumusu.ocplayer.danmaku.enabled"
    private static let danmakuOpacityKey = "dev.jumusu.ocplayer.danmaku.opacity"
    private static let danmakuDisplayAreaKey = "dev.jumusu.ocplayer.danmaku.displayArea"
    private static let danmakuBlockTopKey = "dev.jumusu.ocplayer.danmaku.blockTop"
    private static let danmakuBlockBottomKey = "dev.jumusu.ocplayer.danmaku.blockBottom"
    private static let danmakuBlockScrollKey = "dev.jumusu.ocplayer.danmaku.blockScroll"

    static var rate: Double {
        get { storedDouble(forKey: rateKey, range: 0.5...2.0, default: 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: rateKey) }
    }
    static var volume: Double {
        get { storedDouble(forKey: volumeKey, range: 0...1, default: 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: volumeKey) }
    }
    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }
    static var subtitleScale: Double {
        get { storedDouble(forKey: subtitleScaleKey, range: 0.5...3.0, default: 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: subtitleScaleKey) }
    }
    static var danmakuEnabled: Bool {
        get { storedBool(forKey: danmakuEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuEnabledKey) }
    }
    static var danmakuOpacity: Double {
        get { storedDouble(forKey: danmakuOpacityKey, range: 0.25...1, default: 0.85) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuOpacityKey) }
    }
    static var danmakuDisplayArea: Double {
        get { storedDouble(forKey: danmakuDisplayAreaKey, range: 0.25...1, default: 0.75) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuDisplayAreaKey) }
    }
    static var danmakuBlockTop: Bool {
        get { storedBool(forKey: danmakuBlockTopKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuBlockTopKey) }
    }
    static var danmakuBlockBottom: Bool {
        get { storedBool(forKey: danmakuBlockBottomKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuBlockBottomKey) }
    }
    static var danmakuBlockScroll: Bool {
        get { storedBool(forKey: danmakuBlockScrollKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: danmakuBlockScrollKey) }
    }

    private static func storedDouble(
        forKey key: String,
        range: ClosedRange<Double>,
        default fallback: Double
    ) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.double(forKey: key).clamped(range)
    }

    private static func storedBool(forKey key: String, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// 一次播放请求：从浏览层（AppModel）带到播放页的纯值。
/// `authHeader` 是 Jellyfin 的 `MediaBrowser …` 头 —— 只走请求头，绝不进 URL。
struct PlaybackRequest: Hashable, Identifiable {
    let id: UUID
    let title: String
    let uri: String
    let authHeader: String?
    /// Security-scoped URL for a user-selected local file.
    let securityScopedURL: URL?
    /// 服务端记录的续播位置（秒）；小于 30 秒视作从头播。
    let resumeSeconds: Double?
    /// Jellyfin playback/source identity. Local files and manual URLs leave it nil.
    let sessionContext: PlaybackSessionContext?

    init(
        id: UUID = UUID(),
        title: String,
        uri: String,
        authHeader: String? = nil,
        resumeSeconds: Double? = nil,
        securityScopedURL: URL? = nil,
        sessionContext: PlaybackSessionContext? = nil
    ) {
        self.id = id
        self.title = title
        self.uri = uri
        self.authHeader = authHeader
        self.resumeSeconds = resumeSeconds
        self.securityScopedURL = securityScopedURL
        self.sessionContext = sessionContext
    }
}

/// A capability token for injecting an asynchronously loaded resource into the
/// exact engine generation it was requested for.
struct PlaybackSourceGeneration: Hashable, Sendable {
    let requestID: PlaybackRequest.ID
    let value: UInt64
}

/// PlaybackCoordinator：拿到源 → 喂内核 → 暴露状态给 UI。
/// 进度上报（M2）、弹幕装载（M3）都挂在这一层（内核细节始终留在 ErikaKit 里）。
@MainActor
@Observable
final class PlaybackController: DanmakuPlaybackHosting {
    /// Replaced for every engine generation so buffered events from an old
    /// engine can never mutate the new source's timeline.
    private(set) var state = PlayerState()

    private(set) var engine: ErikaEngine?
    private(set) var setupError: String?
    private(set) var currentTitle: String?
    /// Request-scoped synchronous source-open failure. Kept separate from
    /// setupError because subtitle/screenshot failures must not stop reporting.
    private(set) var failedRequestID: PlaybackRequest.ID?

    var rate: Double = PlaybackPreferences.rate {
        didSet { if rate != oldValue { PlaybackPreferences.rate = rate } }
    }
    var volume: Double = PlaybackPreferences.volume {
        didSet {
            if volume != oldValue {
                PlaybackPreferences.volume = volume
                if volume > 0, muted { muted = false }
            }
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

    private(set) var danmakuTracks: [DanmakuTrackInfo] = []
    private(set) var danmakuEnabled = PlaybackPreferences.danmakuEnabled
    private(set) var danmakuOpacity = PlaybackPreferences.danmakuOpacity
    private(set) var danmakuDisplayArea = PlaybackPreferences.danmakuDisplayArea
    private(set) var danmakuBlockTop = PlaybackPreferences.danmakuBlockTop
    private(set) var danmakuBlockBottom = PlaybackPreferences.danmakuBlockBottom
    private(set) var danmakuBlockScroll = PlaybackPreferences.danmakuBlockScroll
    private(set) var danmakuGlobalOffsetSeconds = 0.0

    /// 当前内核里打开的源（去重用：覆盖层出现时不重复 open 同一个源）。
    private(set) var currentlyOpenURI: String?
    /// Changes as soon as a new request is presented, before its engine opens.
    private(set) var sourceGeneration: UInt64 = 0
    /// 最近一次请求（出错重试用）。
    private(set) var lastRequest: PlaybackRequest?

    private var eventTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var expectedRequestID: PlaybackRequest.ID?
    private var activeRequest: PlaybackRequest?
    private var activeSecurityScopedURL: URL?
    private var activeSecurityScope = false
    private var hasLoadedSource = false

    /// 引擎懒创建：创建失败（缺内核 / 显卡不支持）时把原因留给 UI 显示。
    @discardableResult
    func prepareEngine() -> ErikaEngine? {
        if let engine { return engine }
        do {
            let engine = try ErikaEngine()
            eventTask = state.start(consuming: engine)
            self.engine = engine
            setupError = nil
            PlaybackLog.append("PlaybackController prepareEngine 成功")
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
        var authHeader: String?
        if let token = jellyfinToken, !token.isEmpty {
            authHeader = #"MediaBrowser Client="OcPlayer", Device="Mac", DeviceId="ocplayer-m0", Version="0.1", Token="\#(token)""#
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
        _ operation: (ErikaEngine) throws -> Void
    ) rethrows -> Bool {
        guard source.value == sourceGeneration,
              source.requestID == activeRequest?.id,
              isSourceReady,
              let engine
        else { return false }
        try operation(engine)
        return true
    }

    private var isSourceReady: Bool {
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

    private func openPreparedRequest(_ request: PlaybackRequest) {
        currentTitle = request.title
        lastRequest = request
        activeRequest = nil
        failedRequestID = nil
        PlaybackLog.append("PlaybackController open(request) title=\(request.title) hasLoadedSource=\(hasLoadedSource)")
        var headers: [String: String] = [:]
        if let authHeader = request.authHeader {
            headers["Authorization"] = authHeader
        }
        let opened = open(
            PlaybackSource(uri: request.uri, headers: headers),
            securityScopedURL: request.securityScopedURL
        )
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
    private func seekPendingResumeIfNeeded(
        resumeSeconds: Double,
        requestID: PlaybackRequest.ID,
        generation: UInt64,
        engineID: ObjectIdentifier
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard sourceGeneration == generation,
                  expectedRequestID == requestID,
                  activeRequest?.id == requestID,
                  let engine,
                  ObjectIdentifier(engine) == engineID
            else { return }
            if state.state == .error || state.state == .stopped || state.state == .closed {
                return
            }
            guard isSourceReady, state.duration > .zero else { continue }

            let duration = Double(state.duration.microseconds) / 1_000_000
            let target = min(max(resumeSeconds, 0), max(duration - 0.5, 0))
            do {
                try engine.seek(to: .seconds(target))
            } catch {
                setupError = "续播定位失败：\(error)"
            }
            return
        }
    }

    private func samePlaybackSource(_ lhs: PlaybackRequest, _ rhs: PlaybackRequest) -> Bool {
        lhs.uri == rhs.uri
            && lhs.authHeader == rhs.authHeader
            && lhs.securityScopedURL == rhs.securityScopedURL
            && lhs.sessionContext == rhs.sessionContext
    }

    @discardableResult
    private func open(_ source: PlaybackSource, securityScopedURL: URL? = nil) -> Bool {
        // 换片：先 stop 旧源，再整体丢弃重建引擎。内核 close() 是终态——同一 presenter
        // close 后不能再 open（实测抛 ErikaError "player is closed"），所以换片不复用旧引擎，
        // 对齐 stopPlayback 的做法 stop + resetEngine；prepareEngine() 在下面会重建新引擎。
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
            // 成功打开 → 清掉上一次的报错，别让错误条残留。
            setupError = nil
            currentlyOpenURI = source.uri
            activeSecurityScopedURL = acquiredScope ? securityScopedURL : nil
            activeSecurityScope = acquiredScope
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
        try? engine?.stop()
        // 清空去重标记：否则下次打开同一视频时 openIfNeeded 会误判「已打开同一个源」
        // 直接跳过（画面停在旧帧/黑屏，进度丢失）。
        // 注意：这里只 stop 不 close。内核 close() 是终态——closed 后不能再 open，
        // 所以 App 层一律不复用引擎：退出（这里）和换片（open() 里）都走 stop +
        // resetEngine 重建，避免引擎进入不可 reopen 的 closed 状态。
        // stop 之后旧源已经不算“已加载”，必须清掉标记，否则下一次 open 会误以为要换片，
        // 白白把还没加载新源的引擎丢掉重建（无害但没必要）。
        hasLoadedSource = false
        currentlyOpenURI = nil
        activeRequest = nil
        expectedRequestID = nil
        sourceGeneration &+= 1
        releaseSecurityScopedResource()
        // 退出播放后把引擎整个丢掉，下次播放重新创建。
        // 这样即使 Erika 的 stop/detach 组合在个别版本里会让旧 presenter 进入不可 reopen 的状态，
        // 也不会影响下一次播放。
        resetEngine()
        PlaybackLog.append("stopPlayback() 完成 hasLoadedSource=\(hasLoadedSource)")
    }

    private func resetEngine() {
        resumeTask?.cancel()
        resumeTask = nil
        eventTask?.cancel()
        eventTask = nil
        engine = nil
        failedRequestID = nil
        danmakuTracks = []
        danmakuGlobalOffsetSeconds = 0
        // 注意：这里不要 state.reset()。closePlayer 的调用顺序是
        // stopPlayback() → dismissPlayer()，dismissPlayer 还要读 state.position 上报 Stopped。
        // 等下次 open 时自然会 reset。
        setupError = nil
        PlaybackLog.append("resetEngine 完成")
    }

    private func releaseSecurityScopedResource() {
        guard activeSecurityScope, let url = activeSecurityScopedURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        activeSecurityScope = false
    }

    // MARK: - 轨道（音轨 / 字幕菜单用）

    /// Replace the current source's danmaku only while its generation token is valid.
    @discardableResult
    func replaceDanmaku(
        json: String,
        name: String,
        offset: Duration,
        for source: PlaybackSourceGeneration
    ) throws -> Bool {
        var tracks: [DanmakuTrackInfo] = []
        do {
            let accepted = try withReadyEngine(for: source) { engine in
                try engine.clearDanmaku()
                _ = try engine.addDanmakuTrack(json: json, name: name, offset: offset)
                do {
                    try applyDanmakuPreferences(to: engine)
                } catch {
                    playerLog.warning("弹幕已装载，但偏好应用失败 error=\(error)")
                    PlaybackLog.append("danmaku loaded without preferences error=\(error)")
                }
                tracks = try engine.danmakuTracks()
            }
            if accepted { danmakuTracks = tracks }
            return accepted
        } catch {
            refreshDanmakuTracks(for: source)
            throw error
        }
    }

    @discardableResult
    func clearDanmaku(for source: PlaybackSourceGeneration) throws -> Bool {
        do {
            let accepted = try withReadyEngine(for: source) { engine in
                try engine.clearDanmaku()
            }
            if accepted { danmakuTracks = [] }
            return accepted
        } catch {
            refreshDanmakuTracks(for: source)
            throw error
        }
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        danmakuEnabled = enabled
        PlaybackPreferences.danmakuEnabled = enabled
        try? engine?.setDanmakuEnabled(enabled)
    }

    func setDanmakuOpacity(_ opacity: Double) {
        danmakuOpacity = opacity.clamped(0.25...1)
        PlaybackPreferences.danmakuOpacity = danmakuOpacity
        updateDanmakuConfig { $0.opacity = Float(danmakuOpacity) }
    }

    func setDanmakuDisplayArea(_ area: Double) {
        danmakuDisplayArea = area.clamped(0.25...1)
        PlaybackPreferences.danmakuDisplayArea = danmakuDisplayArea
        updateDanmakuConfig { $0.displayArea = Float(danmakuDisplayArea) }
    }

    func setDanmakuBlocked(top: Bool? = nil, bottom: Bool? = nil, scroll: Bool? = nil) {
        if let top {
            danmakuBlockTop = top
            PlaybackPreferences.danmakuBlockTop = top
        }
        if let bottom {
            danmakuBlockBottom = bottom
            PlaybackPreferences.danmakuBlockBottom = bottom
        }
        if let scroll {
            danmakuBlockScroll = scroll
            PlaybackPreferences.danmakuBlockScroll = scroll
        }
        updateDanmakuConfig {
            $0.blockTop = danmakuBlockTop
            $0.blockBottom = danmakuBlockBottom
            $0.blockScroll = danmakuBlockScroll
        }
    }

    func adjustDanmakuOffset(by seconds: Double) {
        setDanmakuOffset(danmakuGlobalOffsetSeconds + seconds)
    }

    func resetDanmakuOffset() {
        setDanmakuOffset(0)
    }

    private func setDanmakuOffset(_ seconds: Double) {
        danmakuGlobalOffsetSeconds = seconds.clamped(-30...30)
        try? engine?.setDanmakuGlobalOffset(.seconds(danmakuGlobalOffsetSeconds))
    }

    private func applyDanmakuPreferences(to engine: ErikaEngine) throws {
        var config = try engine.danmakuConfig()
        config.enabled = danmakuEnabled
        config.opacity = Float(danmakuOpacity)
        config.displayArea = Float(danmakuDisplayArea)
        config.blockTop = danmakuBlockTop
        config.blockBottom = danmakuBlockBottom
        config.blockScroll = danmakuBlockScroll
        try engine.setDanmakuConfig(config)
        try engine.setDanmakuGlobalOffset(.seconds(danmakuGlobalOffsetSeconds))
    }

    private func updateDanmakuConfig(_ update: (inout DanmakuConfig) -> Void) {
        guard let engine, var config = try? engine.danmakuConfig() else { return }
        update(&config)
        try? engine.setDanmakuConfig(config)
    }

    private func refreshDanmakuTracks(for source: PlaybackSourceGeneration) {
        var tracks: [DanmakuTrackInfo] = []
        let accepted = (try? withReadyEngine(for: source) { engine in
            tracks = try engine.danmakuTracks()
        }) ?? false
        if accepted { danmakuTracks = tracks }
    }

    func selectAudio(_ track: TrackInfo) {
        guard let engine else { return }
        try? engine.selectAudioTrack(track.id)
        state.refreshTracks(from: engine)
    }

    /// `nil` = 关闭字幕。
    func setSubtitle(_ track: TrackInfo?) {
        guard let engine else { return }
        try? engine.selectSubtitleTrack(track?.id)
        state.refreshTracks(from: engine)
    }

    /// 加外挂字幕轨道（用户手动选文件：加载并立即选中）。
    func loadExternalSubtitle(fileURL: URL) {
        guard let engine else { return }
        guard let localURL = copyImportedSubtitle(fileURL) else { return }
        do {
            let id = try engine.addExternalSubtitle(localURL.path)
            try engine.selectSubtitleTrack(id)
            state.refreshTracks(from: engine)
        } catch {
            setupError = "字幕加载失败：\(error)"
        }
    }

    /// 只加轨道不改变当前选择（Jellyfin 侧车字幕批量装载用）。
    func addExternalSubtitle(fileURL: URL) {
        guard let engine else { return }
        do {
            _ = try engine.addExternalSubtitle(fileURL.path)
            state.refreshTracks(from: engine)
        } catch {
            setupError = "字幕加载失败：\(error)"
        }
    }

    /// Generation-safe variant for asynchronously downloaded resources.
    @discardableResult
    func addExternalSubtitle(
        fileURL: URL,
        for source: PlaybackSourceGeneration
    ) -> Bool {
        do {
            return try withReadyEngine(for: source) { engine in
                _ = try engine.addExternalSubtitle(fileURL.path)
                state.refreshTracks(from: engine)
            }
        } catch {
            setupError = "字幕加载失败：\(error)"
            return false
        }
    }

    /// 当前没有任何字幕被选中时自动挑一条：中文优先，否则第一条。
    /// （内核对内封字幕有自己的默认选择；这里只兜「全是外挂字幕」的场。）
    func autoSelectSubtitleIfNone() {
        guard let engine, !state.subtitleTracks.isEmpty else { return }
        guard !state.subtitleTracks.contains(where: { $0.selected }) else { return }
        let tracks = state.subtitleTracks
        let picked = tracks.first {
            let lang = $0.language?.lowercased() ?? ""
            return lang.contains("zh") || lang.contains("chi")
        } ?? tracks[0]
        try? engine.selectSubtitleTrack(picked.id)
        state.refreshTracks(from: engine)
    }

    @discardableResult
    func autoSelectSubtitleIfNone(for source: PlaybackSourceGeneration) -> Bool {
        guard source.value == sourceGeneration,
              source.requestID == activeRequest?.id,
              isSourceReady,
              let engine
        else { return false }
        guard !state.subtitleTracks.isEmpty,
              !state.subtitleTracks.contains(where: { $0.selected })
        else { return true }
        let tracks = state.subtitleTracks
        let picked = tracks.first {
            let lang = $0.language?.lowercased() ?? ""
            return lang.contains("zh") || lang.contains("chi")
        } ?? tracks[0]
        do {
            try engine.selectSubtitleTrack(picked.id)
            state.refreshTracks(from: engine)
            return true
        } catch {
            setupError = "字幕选择失败：\(error)"
            return false
        }
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
        let target = Double(state.position.microseconds) + seconds * 1_000_000
        try? engine.seek(to: .microseconds(Int64(max(0, target))))
    }

    func applyRate(_ newRate: Double) {
        rate = newRate
        try? engine?.setRate(newRate)
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

    private func copyImportedSubtitle(_ source: URL) -> URL? {
        let scope = source.startAccessingSecurityScopedResource()
        defer { if scope { source.stopAccessingSecurityScopedResource() } }
        do {
            let directory = URL.applicationSupportDirectory
                .appending(path: "OcPlayer/Subtitles", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(UUID().uuidString)-\(source.lastPathComponent)")
            try FileManager.default.copyItem(at: source, to: destination)
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

    /// 截当前帧（视频 + 字幕合成）为 PNG，保存到「图片」，返回文件名（失败给错误文案）。
    func captureScreenshot() -> String? {
        guard let engine, let params = state.videoParams,
              params.width > 0, params.height > 0
        else {
            setupError = "还没有可截的画面"
            return nil
        }
        do {
            let rgba = try engine.captureFrameRGBA(width: params.width, height: params.height)
            guard let image = Self.pngImage(fromRGBA: rgba, width: params.width, height: params.height) else {
                setupError = "截图编码失败"
                return nil
            }
            let directory = URL.picturesDirectory
                .appending(path: "OcPlayer", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "截图-\(currentTitle?.prefix(40) ?? "frame")-\(formatter.string(from: Date())).png"
                .replacingOccurrences(of: "/", with: "-")
            let url = directory.appending(path: name)
            try image.write(to: url)
            return name
        } catch {
            setupError = "截图失败：\(error)"
            return nil
        }
    }

    /// RGBA8 缓冲 → PNG Data（截图用，双端同一套 CoreGraphics）。
    private static func pngImage(fromRGBA pixels: [UInt8], width: Int, height: Int) -> Data? {
        var data = pixels
        let space = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { pointer -> Data? in
            guard let base = pointer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage()
            else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, "public.png" as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }

    /// 硬解 / 丢帧等实时数字，播放页的调试行用。
    func statsLine() -> String {
        guard let engine else { return "—" }
        let s = engine.latestStats
        return """
        解码 \(s.decoded_video_frames) · 渲染 \(s.rendered_video_frames) · \
        硬解 \(s.hardware_video_frames) · 软解 \(s.software_video_frames) · \
        零拷贝 \(s.zero_copy_video_frames) · 音频 \(s.pushed_audio_frames) · \
        渲染失败 \(s.render_failures) · 音频失败 \(s.audio_failures)
        """
    }

    // MARK: - DanmakuPlaybackHosting（弹幕编排器注入入口）

    func replaceDanmaku(uuid: UUID, json: String, name: String, offset: Duration) throws -> Bool {
        guard let source = currentSourceToken(uuid: uuid) else { return false }
        return try replaceDanmaku(json: json, name: name, offset: offset, for: source)
    }

    func clearDanmaku(uuid: UUID) throws -> Bool {
        guard let source = currentSourceToken(uuid: uuid) else { return false }
        return try clearDanmaku(for: source)
    }

    /// 当前播放源代次 token；弹幕编排器用 `uuid`（请求 id）跨 await 后重新绑定。
    private func currentSourceToken(uuid: UUID) -> PlaybackSourceGeneration? {
        guard expectedRequestID == uuid, let activeRequest, activeRequest.id == uuid, isSourceReady else {
            return nil
        }
        return PlaybackSourceGeneration(requestID: uuid, value: sourceGeneration)
    }
}
