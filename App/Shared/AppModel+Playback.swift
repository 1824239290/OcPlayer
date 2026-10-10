import CoreModel
import BangumiKit
import DanmakuKit
import DiagnosticsKit
import Foundation
import JellyfinKit
import PlaybackKit

extension AppModel {
    // MARK: - 弹幕设置（弹弹play 网关）

    func updateDanmakuGateway(urlString: String, apiKey: String) async {
        // Commit both values before restarting. This avoids ever pairing a new
        // gateway host with the previously saved credential.
        danmakuModel.updateGateway(urlString: urlString, apiKey: apiKey)
        // Bangumi 登录与弹幕共用同一个网关：设置变了要同步给 BangumiKit，
        // 否则换 Key 之后 Bangumi 授权还在用旧 Key。
        await bangumi.applyGatewayConfiguration(bangumiGatewayConfiguration)
        restartDanmakuForCurrentPlayback()
    }

    func setDanmakuAutoLoadingEnabled(_ enabled: Bool) {
        danmakuModel.danmaku.setAutoLoadingEnabled(enabled)
        if enabled { restartDanmakuForCurrentPlayback() }
    }

    // MARK: - 播放串联（UI 只调这里，不自己拼 URL）

    func play(_ item: MediaItem, resumeSeconds: Double?) {
        // 同一剧目重复点击：复用在飞的解析任务，不要 cancel 重来——
        // 否则每次点击都打断 PlaybackInfo 请求，越点越慢、永远跑不完。
        if case .loading = playbackPreparation, retryPlaybackItem?.id == item.id {
            return
        }
        cancelPlaybackOpen()
        retryPlaybackItem = item
        playbackPreparation = .loading(title: item.name)
        AppDiagnostics.logInfo("play() 进入加载态", fields: ["title": .string(item.name)])
        let generation = playbackOpenGeneration
        playbackOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.playbackOpenGeneration == generation {
                    self.playbackOpenTask = nil
                }
            }
            await self.openPlayback(item: item, resumeSeconds: resumeSeconds)
            AppDiagnostics.logInfo("play() 加载态结束", fields: ["preparation": .string(String(describing: self.playbackPreparation))])
        }
    }

    func cancelPlaybackOpen() {
        AppDiagnostics.logInfo("cancelPlaybackOpen 取消播放准备")
        playbackOpenGeneration &+= 1
        playbackOpenTask?.cancel()
        playbackOpenTask = nil
        preparationDismissTask?.cancel()
        preparationDismissTask = nil
        dismissFollowUpTask?.cancel()
        dismissFollowUpTask = nil
        playbackPreparation = nil
        danmakuModel.danmaku.cancel()
    }

    /// 取消正在解析的播放准备（loading 层「取消」按钮入口）：
    /// 准备阶段（URI 未就绪）→ 只撤 loading 回列表；
    /// 内核阶段（PlayerScreen 已 present）→ 连播放器一起退出。
    func cancelPlaybackOpening() {
        if presentedPlayer != nil {
            dismissPlayer()
        } else {
            cancelPlaybackOpen()
        }
    }

    @MainActor
    func openPlayback(item: MediaItem, resumeSeconds: Double?) async {
        guard let server else { return }
        finishReporting()   // 上一条的 Stopped（换片场景）

        // 首页「最近添加」等入口可以直接包含 Series，但 Jellyfin 的 PlaybackInfo/stream
        // 只接受可播放的叶子条目。沿用详情页的语义：优先「接下来看」，否则取
        // 首个未看完的常规剧集；避免把 Series ID 直接送进 /Videos/{id}/stream。
        // 合集（BoxSet）同理：它是容器，Id 送进 PlaybackInfo / stream 一律 400。
        let playableItem: MediaItem
        do {
            guard let resolved = try await resolvePlayableItem(for: item, server: server) else {
                playbackPreparation = .failed(title: item.name,
                                              error: Self.noPlayableContentMessage(for: item))
                return
            }
            guard !Task.isCancelled else { return }
            playableItem = resolved
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            playbackPreparation = .failed(title: item.name, error: "剧集加载失败：\(error)")
            AppDiagnostics.logWarning("播放剧集解析失败", fields: [
                "item": .string(item.name),
                "error": .string("\(error)"),
            ])
            return
        }

        let effectiveResume = playableItem.id == item.id
            ? resumeSeconds
            : playableItem.playState?.positionSeconds
        let title = playableItem.episodeLabel.map {
            "\(playableItem.seriesName ?? playableItem.name) \($0)"
        } ?? playableItem.name
        // 解析出集标题后刷新 loading 文案（从剧名更新到「S1E7」之类）
        if case .loading = playbackPreparation {
            playbackPreparation = .loading(title: title)
        }
        do {
            let info = try await server.playbackInfo(itemID: playableItem.id)
            let source = info.preferredSource
            let context = info.sessionContext(itemID: playableItem.id, selectedSource: source)
            let uri = try server.streamURL(
                itemID: playableItem.id,
                mediaSourceID: source?.id,
                playSessionID: info.playSessionID
            )
            guard !Task.isCancelled else { return }
            presentPlayback(title: title, uri: uri, authHeader: server.authorizationHeader,
                            resumeSeconds: effectiveResume, item: playableItem,
                            sessionContext: context)
        } catch {
            // PlaybackInfo 不可用（老版本 / 端点被关）时退回原来的直连 URL。
            if Task.isCancelled { return }
            AppDiagnostics.logWarning("PlaybackInfo 失败，回退直连", fields: [
                "item": .string(playableItem.name),
                "error": .string("\(error)"),
            ])
            if let uri = try? server.streamURL(itemID: playableItem.id, mediaSourceID: nil, playSessionID: nil) {
                presentPlayback(title: title, uri: uri, authHeader: server.authorizationHeader,
                                resumeSeconds: effectiveResume, item: playableItem,
                                sessionContext: PlaybackSessionContext(
                                    itemID: playableItem.id,
                                    durationSeconds: playableItem.runtimeSeconds
                                ))
            } else {
                playbackPreparation = .failed(title: title, error: "播放信息获取失败：\(error)")
                AppDiagnostics.logError("PlaybackInfo 失败且回退直连也失败", fields: [
                    "title": .string(title),
                    "error": .string("\(error)"),
                ])
            }
        }
    }

    /// 把浏览层条目归一化为可直接播放的叶子条目。
    /// 电影 / 集数 / 音频等已经是叶子，剧集则优先复用首页 nextUp / resume，避免额外请求。
    /// （半集会从「接下来看」去重进「继续观看」，所以 resume 也是该集的落点。）
    /// 合集是**容器**：解析成里面第一个可播的成员，绝不把合集自身的 id 送去协商。
    func resolvePlayableItem(for item: MediaItem, server: any MediaServer) async throws -> MediaItem? {
        if item.kind == .boxSet {
            return try await resolvePlayableMember(ofCollection: item, server: server)
        }
        guard item.kind == .series else { return item }

        if let next = home.nextUp.first(where: { $0.seriesID == item.id })
            ?? home.resume.first(where: { $0.seriesID == item.id }) {
            return next
        }

        let episodes = try await server.episodes(seriesID: item.id, seasonID: nil)
        let regularEpisodes = episodes.filter { $0.seasonNumber != 0 }
        return regularEpisodes.first(where: { !($0.playState?.played ?? false) })
            ?? regularEpisodes.first
    }

    /// 合集 → 第一个可播成员。
    ///
    /// `recursive: false` **不能省**（服务端源码口径：`recursive=true` 会走
    /// `DescendantOfId` 把链接条目的下一层一并递归出来，服务端单测
    /// `DescendantOfId_ReachesEpisodesOfALinkedSeries` 断言了这一点），
    /// `kinds` 也不能给（给合集 parentId 配 `includeItemTypes` 会被服务端把
    /// `parentId` 置空、改成从用户根查，见 jellyfin#16454）。
    /// 挑选规则与剧集那条一致：先取第一个没看过的叶子，其次第一个叶子；
    /// 成员里若只有剧集，则回到剧集自己的解析规则（它可能已经有续播进度）。
    private func resolvePlayableMember(
        ofCollection item: MediaItem,
        server: any MediaServer
    ) async throws -> MediaItem? {
        // 形态（`recursive: false` / 不传类型过滤 / 年份升序）与依据都收在
        // `MediaServer.collectionMembers(of:)` —— 这里只挑第一个可播成员，取默认页大小。
        let members = try await server.collectionMembers(of: item.id).items
        let leaves = members.filter { $0.kind == .movie || $0.kind == .episode }
        if let unwatched = leaves.first(where: { !($0.playState?.played ?? false) }) {
            return unwatched
        }
        if let first = leaves.first {
            return first
        }
        if let series = members.first(where: { $0.kind == .series }) {
            return try await resolvePlayableItem(for: series, server: server)
        }
        return nil
    }

    /// 解析不出可播条目时的用户可见文案（按条目类型说清楚是哪种情况）。
    nonisolated static func noPlayableContentMessage(for item: MediaItem) -> String {
        switch item.kind {
        case .boxSet:
            return "这个合集里还没有可播放的内容"
        case .series:
            return "该剧没有可播放的剧集"
        default:
            return "这个条目没有可播放的内容"
        }
    }

    func presentPlayback(
        title: String,
        uri: String,
        authHeader: String?,
        resumeSeconds: Double?,
        item: MediaItem,
        sessionContext: PlaybackSessionContext
    ) {
        let request = PlaybackRequest(
            title: title,
            uri: uri,
            authHeader: authHeader,
            resumeSeconds: resumeSeconds,
            sessionContext: sessionContext
        )
        playback?.prepareForPresentation(request)
        // URI 已就绪但内核未出帧：loading 层继续盖住 PlayerScreen，
        // 等 state 到 ready/playing 再清 preparation，消除
        // 「loading 退出后还要再等内核 open」的两段式等待。
        presentedPlayer = request
        schedulePreparationDismiss(for: request)
        retryPlaybackItem = item
        nowPlayingItem = item
        startReporting(item: item, resumeSeconds: resumeSeconds, request: request)
        startDanmaku(for: request, item: item)
        loadChapterMetadata(for: request, item: item)
    }

    /// 等 playback 内核真正渲染出首帧再撤 loading 层：state 到 ready/playing 只代表
    /// 文件加载完、播放启动，首帧像素可能还在渲染管线上——那时撤 loading 会让
    /// 还没上屏的（空）视频层露出来，出现白闪。
    /// 同时保底 400ms 显示时间：加载太快时 loading 闪现一下就消失会晃眼，
    /// 保底让 loading 有完整的「出现→稳定→淡出」节奏。
    /// 用 request id 绑定：换片 / 重开时旧任务自动失效，不会提前或延后撤别人的 loading。
    func schedulePreparationDismiss(for request: PlaybackRequest) {
        preparationDismissTask?.cancel()
        preparationDismissTask = Task { @MainActor [weak self, weak playback] in
            let clock = ContinuousClock()
            let startTime = clock.now
            var playingSince: ContinuousClock.Instant?
            while let self, !Task.isCancelled {
                guard self.presentedPlayer?.id == request.id else { return }
                // 控制器引用没了（极端情况）：宁可退回两段式也别让 loading 永转。
                guard let playback else {
                    self.playbackPreparation = nil
                    return
                }
                // 首帧已上屏 → 无论当前 state（哪怕已被暂停）都可以撤 loading。
                if playback.engine?.hasRenderedFirstFrame == true {
                    // 保底 400ms：加载太快时 loading 闪现即消失会晃眼。
                    // 这个等待要响应取消（换片/关闭）：吞掉取消错误的话，任务会在
                    // 别人已经接管 loading 之后醒来再改状态。
                    if clock.now - startTime < .milliseconds(400) {
                        do {
                            try await Task.sleep(until: startTime + .milliseconds(400), clock: clock)
                        } catch {
                            return
                        }
                    }
                    // 等待期间可能已换片：只有仍是本 request 的 loading 才归我撤。
                    guard self.presentedPlayer?.id == request.id else { return }
                    self.playbackPreparation = nil
                    return
                }
                // 内核打开失败 / App 层 setupError：撤 loading，让错误徽章接管。
                if playback.state.state == .error || playback.setupError != nil {
                    self.playbackPreparation = nil
                    return
                }
                // 纯音频 / 首帧迟迟不来的兜底：playing 持续 2.5s 仍无帧就放行，
                // 交给 PlayerScreen 的缓冲转圈（surface 已垫黑，不会白闪）。
                if playback.state.state == .playing {
                    let since = playingSince ?? clock.now
                    playingSince = since
                    if clock.now - since > .seconds(2.5) {
                        self.playbackPreparation = nil
                        return
                    }
                } else {
                    playingSince = nil
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    /// 本地文件（onOpenURL / 设置页 / 自检）：不走 Jellyfin，直接上覆盖层。
    /// 本地播放不依赖服务器 —— 登录页挡着就直接越过。
    /// loading 层与 Jellyfin 路径共用：等首帧/保底时长后再撤，避免黑一下再出画。
    func presentLocalFile(_ url: URL) {
        if phase == .onboarding { phase = .ready }
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        finishReporting()
        let request = PlaybackRequest(
            title: url.lastPathComponent,
            uri: url.path,
            securityScopedURL: url
        )
        playbackPreparation = .loading(title: request.title)
        playback?.prepareForPresentation(request)
        presentedPlayer = request
        schedulePreparationDismiss(for: request)
        startDanmaku(for: request, item: nil)
    }

    /// 直连链接（设置页入口）：请求由 `PlaybackController.request(uri:token:)` 构造好。
    func presentRequest(_ request: PlaybackRequest) {
        if phase == .onboarding { phase = .ready }
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        finishReporting()
        playbackPreparation = .loading(title: request.title)
        playback?.prepareForPresentation(request)
        presentedPlayer = request
        schedulePreparationDismiss(for: request)
        startDanmaku(for: request, item: nil)
    }

    /// 异步加载当前源的章节与可跳过片段(耗时网络请求,不阻塞呈现)。
    /// 只对 Jellyfin 源生效(有 sessionContext.itemID);本地文件静默跳过。
    /// 用 activePlaybackIdentity 做守卫,换片 / 退出自动失效。
    func loadChapterMetadata(for request: PlaybackRequest, item: MediaItem) {
        guard item.kind != .series, item.kind != .season,
              let server,
              let itemID = request.sessionContext?.itemID else { return }
        let identity = ActivePlaybackIdentity(
            sessionGeneration: sessionGeneration,
            itemID: item.id,
            requestID: request.id
        )
        Task { @MainActor [weak self, weak playback] in
            guard let self, let playback,
                  self.activePlaybackIdentity == identity,
                  self.presentedPlayer?.id == request.id,
                  !Task.isCancelled
            else { return }
            await playback.loadChapters(server: server, for: request, isMovie: item.kind == .movie)
        }
    }

    func startDanmaku(for request: PlaybackRequest, item: MediaItem?) {
        let context: DanmakuPlaybackContext
        if let item, let server {
            context = .jellyfin(
                item: item,
                request: request,
                serverProfileID: server.profile.id
            )
        } else {
            context = .standalone(request: request)
        }
        danmakuModel.danmaku.start(
            context: context,
            configuration: dandanplayConfiguration,
            playback: playback
        )
    }

    func restartDanmakuForCurrentPlayback() {
        guard let request = presentedPlayer else { return }
        startDanmaku(for: request, item: nowPlayingItem)
    }

    /// 剧集级 TMDB ID（TheIntroDB 跳过片头源用）。
    func seriesTmdbID(for seriesID: String) async -> Int? {
        guard let server else { return nil }
        guard let item = try? await server.item(seriesID) else { return nil }
        return item.tmdbID.flatMap(Int.init)
    }

    var dandanplayConfiguration: DandanplayConfiguration? {
        guard danmakuModel.dandanplayStore.isConfigured else { return nil }
        return DandanplayConfiguration(
            baseURL: danmakuModel.dandanplayStore.gatewayURL,
            apiKey: danmakuModel.dandanplayStore.apiKey,
            userAgent: Self.dandanplayUserAgent
        )
    }

    /// Bangumi OAuth 走同一个网关与同一把 Key（需含 `bgm:oauth` scope）。
    var bangumiGatewayConfiguration: BangumiGatewayConfiguration? {
        guard let configuration = dandanplayConfiguration else { return nil }
        return BangumiGatewayConfiguration(
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            userAgent: configuration.userAgent)
    }

    static var dandanplayUserAgent: String {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return "OcPlay/\(ClientIdentity.marketingVersion) (\(platform); \(architecture))"
    }

    func dismissPlayer() {
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        let stopped = finishReporting()   // 退出播放器 → Stopped,服务器记下续播位置
        // 引擎可能还在跑(loading 取消、自然播完自动关闭这两条路没停过引擎):
        // 兜底停掉,避免音频残留。正常关闭路径(closePlayer)已先 stopPlayback,
        // engineIsActive 为 false,这里不会重复停,也不干扰它的窗口还原动画时序。
        if playback?.engineIsActive == true {
            playback?.stopPlayback()
        }
        presentedPlayer = nil
        // 等 Stopped 上报落库后刷新首页与详情页,让「继续观看」和打开中的详情页立刻反映刚退出的进度。
        // 挂到 dismissFollowUpTask：快速退出/重进播放时 cancelPlaybackOpen 会取消旧收尾，
        // 不让 fire-and-forget 的刷新在旧会话上跑完。
        dismissFollowUpTask?.cancel()
        dismissFollowUpTask = Task {
            await stopped?.value
            guard !Task.isCancelled else { return }
            await loadHome()
            self.detailRefreshGeneration &+= 1
        }
    }

    /// Hook this to `scenePhase == .background`. It immediately snapshots the
    /// current position instead of waiting for the next ten-second heartbeat.
    ///
    /// iOS 上还要在这里把播放切进「后台档」：进程靠 `UIBackgroundModes: audio` +
    /// `.playback` 会话活着继续出声，但后台没有 vsync，帧驱动得从 `CADisplayLink`
    /// 换到定时器（`setBackgroundAudioOnly(true)`），内核在这一档里挂起视频解码，
    /// 避开「解码会话跨挂起往返后第一包数据就炸」（AVERROR_UNKNOWN -1313558101）
    /// 那条只能手动重试的死路。详见 `PlaybackController.beginSystemSuspension`。
    @discardableResult
    func playbackDidEnterBackground() -> Task<Void, Never>? {
        #if os(iOS)
        backgroundResumeIntent = playback?.beginSystemSuspension() ?? false
        #endif
        guard let report = playbackReporting?.reportBackgroundSnapshot() else { return nil }
        if case .terminal = report {
            clearPlaybackSessionState()
        }
        return report.task
    }

    /// Hook this to the foreground transition（`scenePhase == .active`）。
    ///
    /// 按离开前记下的意图把播放接回去：正常路径只需要**退出后台档**——内核在回前台
    /// 第一帧渲染 tick 里自行 flush 解码器 + 回关键帧恢复视频，不用重建任何东西。
    /// 只有内核确实没撑住（`.error` / `setupError`）才走一次**静默重建**——和用户点
    /// 「重试」是同一条路，只是不用他点。macOS 不挂起进程，这条路径整个是空转。
    func playbackDidEnterForeground() {
        #if os(iOS)
        guard let playback else { return }
        let action = Self.foregroundResumeAction(
            intentToResume: backgroundResumeIntent,
            state: playback.state.state,
            hasSetupError: playback.setupError != nil
        )
        backgroundResumeIntent = false
        // 三条分支都要经过它：内部把挂起时长记回账（open 看门狗按真正跑过的时长判超时）。
        let reusable = playback.endSystemSuspension(resumePlaying: action == .resume)
        switch action {
        case .none:
            break
        case .resume:
            // 退出后台档后，内核要在回前台的头几帧里 flush 解码器 + 回关键帧重建 VT
            // 会话，报错未必当场落地——盯一小段；连档位都没退成（内核已经不听使唤）
            // 就直接重建，不猜。
            if reusable {
                watchPlaybackAfterSystemResume()
            } else {
                recoverPlaybackAfterBackgroundFailure(reason: "resume-failed")
            }
        case .rebuild:
            recoverPlaybackAfterBackgroundFailure(reason: "foreground")
        }
        #endif
    }

    /// 回前台的动作决策（纯函数，便于单测）。
    enum ForegroundResumeAction: Equatable {
        /// 离开前没在播（用户自己按的暂停 / 本来就停在错误页）：什么都不做。
        case none
        /// 内核算健康：退出后台档接着播（没有后台档的内核则是解开那次暂停）。
        case resume
        /// 内核没撑过后台往返：按「重试」那条路重建后接着播。
        case rebuild
    }

    static func foregroundResumeAction(
        intentToResume: Bool,
        state: PlaybackState?,
        hasSetupError: Bool
    ) -> ForegroundResumeAction {
        guard intentToResume, let state else { return .none }
        if hasSetupError || state == .error { return .rebuild }
        switch state {
        case .paused, .ready, .playing:
            return .resume
        case .idle, .opening, .stopped, .closed, .error:
            return .none
        }
    }

    /// 回前台观察窗：250ms 一拍、盯 3 秒。
    private static let backgroundRecoveryWatchTick = Duration.milliseconds(250)
    private static let backgroundRecoveryWatchTicks = 12

    /// 挂起把内核弄坏的报错未必在 `play()` 当场落地——恢复后的第一包数据喂进
    /// `avcodec_send_packet` 才炸（用户截图那一刻）。所以在回前台后盯一小段：
    /// 一旦落进错误态就走一次静默重建，重建后仍然失败就按普通错误交给错误徽章，
    /// 不循环重试。
    private func watchPlaybackAfterSystemResume() {
        guard let requestID = presentedPlayer?.id else { return }
        backgroundRecoveryWatch?.cancel()
        backgroundRecoveryWatch = Task { @MainActor [weak self] in
            for _ in 0..<Self.backgroundRecoveryWatchTicks {
                do { try await Task.sleep(for: Self.backgroundRecoveryWatchTick) } catch { return }
                guard let self, !Task.isCancelled else { return }
                // 观察窗只认这一条请求：期间换片 / 退出播放器后，别人身上的错误与它无关。
                guard self.presentedPlayer?.id == requestID else { return }
                guard let playback = self.playback else { return }
                if playback.state.state == .error || playback.setupError != nil {
                    self.recoverPlaybackAfterBackgroundFailure(reason: "post-resume")
                    return
                }
            }
        }
    }

    /// 挂起往返把内核弄坏了：按用户点「重试」那条路静默重建，从当前位置接着播。
    ///
    /// `.error` 的引擎不可复用（内核 close 是终态，见 `PlaybackController.stopPlayback`
    /// 的注释），两条分支都得重建内核：Jellyfin 条目重走完整 `play()`（PlaybackInfo /
    /// Start 会话一起重来），本地文件 / 直连重开同一个请求（同一个 request id，
    /// 走 `open(request:)` 的「重开当前请求」分支换一台新引擎）。
    ///
    /// 位置直接取内核当前位置，**不走 `retryPlayback()` 的「≥30s 才算续播点」启发式**
    /// ——那条是给用户手动重试设计的（怕把刚开的片头当成续播点），系统往返里
    /// 位置退到 0 重来才是 bug。源没加载过（open 阶段就坏了）时位置不可信，
    /// 回落到请求上带的续播点。
    private func recoverPlaybackAfterBackgroundFailure(reason: String) {
        guard let request = presentedPlayer, let playback else { return }
        let resumeSeconds = playback.hasLoadedSource
            ? Double(playback.state.position.microseconds) / 1_000_000
            : request.resumeSeconds
        AppDiagnostics.logInfo("后台往返后自动重建播放", fields: [
            "reason": .string(reason),
            "title": .string(request.title),
            "resume_s": .double(resumeSeconds ?? -1),
        ])
        if let item = nowPlayingItem ?? retryPlaybackItem {
            play(item, resumeSeconds: resumeSeconds)
            return
        }
        // 本地 / 直连：盖 loading 层——重建期间不能让旧请求的错误徽章露着。
        let rebuilt = PlaybackRequest(
            id: request.id,
            title: request.title,
            uri: request.uri,
            authHeader: request.authHeader,
            resumeSeconds: resumeSeconds,
            securityScopedURL: request.securityScopedURL,
            sessionContext: request.sessionContext
        )
        playbackPreparation = .loading(title: request.title)
        presentedPlayer = rebuilt
        schedulePreparationDismiss(for: rebuilt)
        playback.open(request: rebuilt)
        restartDanmakuForCurrentPlayback()
    }

    /// Hook this to the platform's termination callback when available. The
    /// returned task lets a host with a termination grace period await Stopped.
    @discardableResult
    func playbackWillTerminate() -> Task<Void, Never>? {
        finishReporting()
    }

    /// 重试当前 Jellyfin 条目时重新走完整的 PlaybackInfo / Start 会话，
    /// 不复用旧请求的 UUID，避免旧引擎的异步资源串到新引擎。
    func retryPlayback() {
        // 解析进行中（loading）不重入；失败态（failed）允许重试。
        if case .loading = playbackPreparation { return }
        guard let item = nowPlayingItem ?? retryPlaybackItem else {
            playback?.retryLast()
            restartDanmakuForCurrentPlayback()
            return
        }
        let currentPosition = playback.map { Double($0.state.position.microseconds) / 1_000_000 }
        let fallbackPosition = presentedPlayer?.resumeSeconds
        let resumeSeconds = currentPosition.flatMap { $0 >= 30 ? $0 : nil } ?? fallbackPosition
        play(item, resumeSeconds: resumeSeconds)
    }

    // MARK: - 播放会话附属任务（M2）

    func startReporting(
        item: MediaItem,
        resumeSeconds: Double?,
        request: PlaybackRequest
    ) {
        nextEpisode = nil
        guard let server, let context = request.sessionContext,
              let playbackReporting else { return }
        let identity = ActivePlaybackIdentity(
            sessionGeneration: sessionGeneration,
            itemID: item.id,
            requestID: request.id
        )
        activePlaybackIdentity = identity
        resolveNextEpisode(after: item, identity: identity)
        loadExternalSubtitles(for: item, identity: identity, request: request)
        playbackReporting.start(
            reporter: server,
            context: context,
            requestID: request.id,
            resumeSeconds: resumeSeconds
        ) { [weak self] event in
            guard let self, self.activePlaybackIdentity == identity,
                  event.requestID == identity.requestID else { return }
            self.activePlaybackIdentity = nil
            if event.reachedEnd {
                if let next = self.nextEpisode {
                    self.play(next, resumeSeconds: 0)
                } else {
                    self.dismissPlayer()
                }
                // 自然看完：向 Bangumi 标记本集已看（尽力而为，失败不打断连播）。
                self.markWatchedOnBangumi(for: item)
            }
        }
    }

    /// 播放到尾后，把这一集对应的 Bangumi 章节标记为「看过」。
    ///
    /// 只在「有关联 + 已登录」时生效：按 Jellyfin 集号（episodeNumber）匹配
    /// Bangumi 章节 sort，找不到精确匹配就不动。失败静默，错误进诊断日志。
    /// ⚠️ 每个提前返回都要留日志：这条链路全是静默 return，出问题时没有
    /// 任何线索（此前整份日志里成功/失败记录都是 0 条）。
    private func markWatchedOnBangumi(for item: MediaItem) {
        // 集成停用（设置页「启用 Bangumi」关闭）时连日志都不发网络：第一个闸。
        // 用带默认值的读取：这个开关的默认值是 true 但从不落盘（Toggle 只写拨过的
        // 值），`bool(forKey:)` 对从未拨过的人返回 false，会把「默认开」误判成停用
        // ——全新安装的播放结束自动标记会永久静默关闭（review-20260914 P1-2）。
        guard UserDefaults.standard.bool(forKey: SettingsKeys.bangumiEnabled, default: true) else {
            BangumiDiagnostics.log("播放结束未标记：Bangumi 集成已停用")
            return
        }
        guard item.kind == .episode, let episodeNumber = item.episodeNumber else {
            let itemID = item.id
            BangumiDiagnostics.log("播放结束未标记：不是单集 item=\(itemID)")
            return
        }
        guard bangumi.isAuthenticated else {
            BangumiDiagnostics.log("播放结束未标记：Bangumi 未登录")
            return
        }
        let subjectID = (item.seasonID.flatMap { BangumiMatcher.linkedSubjectID(forJellyfinItemID: $0) })
            ?? (item.seriesID.flatMap { BangumiMatcher.linkedSubjectID(forJellyfinItemID: $0) })
            ?? BangumiMatcher.linkedSubjectID(forJellyfinItemID: item.id)
        guard let subjectID else {
            let desc = item.seasonID ?? item.seriesID ?? item.id
            BangumiDiagnostics.log("播放结束未标记：条目未关联 jellyfin=\(desc)")
            return
        }
        // 会话代次快照：这里是**唯一**没有守卫的异步写（对照 startReporting /
        // resolveNextEpisode 都带 generation）。不加的话，换服务器 / 登出之后这条
        // 迟到的任务仍会往**旧服务器**的 Bangumi 条目上 PATCH「看过」——用户看到的
        // 是"没播过的番莫名其妙被标了"。每个 await 之后都要重新确认。
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 关联过但从没打开过详情页时本地是空的，先补齐再匹配。
                try await self.bangumi.context.ensureSubjectLoaded(subjectID)
                guard generation == self.sessionGeneration else { return }
                let episodes = try await self.bangumi.context.fetchEpisodes(subjectId: subjectID)
                guard generation == self.sessionGeneration else { return }
                // 精确匹配主篇集号。sort 是 Float（特典可能是 12.5），只认整数集号相等的，
                // 匹配不上就不动——宁可不标，也不要标错集。
                let targetSort = Float(episodeNumber)
                func isMainEpisode(_ episode: BangumiEpisodeDTO) -> Bool {
                    episode.type == .main && episode.sort == targetSort
                }
                let matched = episodes.first(where: isMainEpisode)
                guard let episode = matched else {
                    BangumiDiagnostics.log(
                        "播放结束未标记：集号匹配不上 subject=\(subjectID) ep=\(episodeNumber)")
                    return
                }
                let alreadyWatched = episode.collectionTypeEnum == .collect
                guard !alreadyWatched else {
                    let episodeID = episode.id
                    BangumiDiagnostics.log(
                        "播放结束未标记：本集已是看过 subject=\(subjectID) ep=\(episodeID)")
                    return
                }
                // 条目不在看时先推为在看已下沉到 updateEpisodeCollection（标看过自动前置）。
                try await self.bangumi.context.updateEpisodeCollection(
                    episodeId: episode.id, type: .collect)
                let episodeID = episode.id
                BangumiDiagnostics.log(
                    "播放结束已标记 Bangumi subject=\(subjectID) episode=\(episodeID)")
                guard generation == self.sessionGeneration else { return }
                // 服务端对条目状态的连带推进（看完最后一集 → 在看变看过）本地猜不了，
                // 回读对齐并让进度页列表/计数立刻刷新。
                await self.bangumi.context.refreshSubjectAfterProgressChange(subjectID)
            } catch {
                BangumiDiagnostics.log("播放结束标记 Bangumi 已看失败 error=\(error)", level: .warning)
            }
        }
    }

    /// 换片 / 退出播放器：补 Stopped 后停表。返回 Stopped 上报任务（供调用方等待落库）。
    @discardableResult
    func finishReporting() -> Task<Void, Never>? {
        clearPlaybackSessionState()
        return playbackReporting?.stop()
    }

    func clearPlaybackSessionState() {
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        nextEpisode = nil
        nowPlayingItem = nil
        activePlaybackIdentity = nil
    }

    /// 连播窗口大小：当前集 + 往后几条。留出余量是为了跳过夹在正片之间的特典，
    /// 又远小于整部剧的集数。
    static let nextEpisodeWindow = 6

    func resolveNextEpisode(after item: MediaItem, identity: ActivePlaybackIdentity) {
        guard item.kind == .episode, let seriesID = item.seriesID, let server else { return }
        // 第 0 季是特典/花絮：看完特典就该停，让用户自己选下一步，不自动连播。
        guard item.seasonNumber != 0 else { return }
        nextEpisodeTask?.cancel()
        nextEpisodeTask = Task { [weak self] in
            // 只取当前集往后的一小窗，不再拉整部剧的集列表。
            let window: [MediaItem]
            do {
                window = try await server.episodes(
                    seriesID: seriesID,
                    startingAt: item.id,
                    limit: Self.nextEpisodeWindow
                )
            } catch is CancellationError {
                return
            } catch {
                // 拉不到连播窗口不该让播放出错，但静默吞掉的话「看完这集不连播」
                // 没有任何排查线索。
                AppDiagnostics.logWarning("拉取连播窗口失败 series=\(seriesID) after=\(item.id) error=\(error)")
                return
            }
            guard let self else { return }
            guard !Task.isCancelled,
                  self.activePlaybackIdentity == identity else { return }
            // 窗口是服务端顺序，当前集应该在第一条；找不到就不猜。
            guard let index = window.firstIndex(where: { $0.id == item.id }) else { return }
            // 往后第一条正片（跳过第 0 季特典）。
            self.nextEpisode = window[window.index(after: index)...]
                .first { $0.seasonNumber != 0 }
        }
    }

    /// 拼一条 Jellyfin 侧车字幕的菜单显示名：优先用标题，没有就语言兜底
    /// （"zh" 这类代码转成可读语言名）。和 `ExternalSubtitle.title` 一起喂给
    /// `addExternalSubtitle(fileURL:name:for:)`，内核不带这些元数据。
    static func subtitleDisplayName(for subtitle: ExternalSubtitle) -> String {
        if let title = subtitle.title, !title.isEmpty { return title }
        if let language = subtitle.language, !language.isEmpty {
            return language.lowercased()
        }
        return subtitle.codec.uppercased()
    }

    /// Jellyfin 侧车字幕（`.zh.srt` 这类不在容器里的）：列出 → 逐条下载 → 喂给内核。
    /// 整批装载结束后按偏好校正一次字幕选择（见 `endExternalSubtitleBatch`）。
    func loadExternalSubtitles(
        for item: MediaItem,
        identity: ActivePlaybackIdentity,
        request: PlaybackRequest
    ) {
        guard let server else { return }
        let itemID = item.id
        externalSubtitleTask?.cancel()
        externalSubtitleTask = Task { [weak self] in
            let subtitles: [ExternalSubtitle]
            do {
                subtitles = try await server.externalSubtitles(itemID: itemID)
            } catch is CancellationError {
                return
            } catch {
                // 列不出侧车字幕只是「没字幕可挂」，但不该静默——断网/服务端异常时
                // 用户看到的是「没字幕」，得有日志能区分。
                AppDiagnostics.logWarning("列出外挂字幕失败 item=\(itemID) error=\(error)")
                return
            }
            guard !subtitles.isEmpty, let self else { return }
            // 解析期间用户已换片 → 丢弃，避免字幕串台
            guard !Task.isCancelled,
                  self.activePlaybackIdentity == identity,
                  let playback = self.playback,
                  let source = await playback.waitUntilSourceReady(for: request.id)
            else { return }
            // 批次闸门：逐条 `addExternalSubtitle` 都会刷轨道列表，实时校正会让
            // 「繁體先下完、简体后下完」在这里连着切两次字幕轨。整批只校正一次。
            // 用 `defer` 收尾：循环里有多处提前 return（取消 / 换片 / 单条失败），
            // 少关一次 flag 就是这一整片再也不按偏好选字幕。
            playback.beginExternalSubtitleBatch()
            defer { playback.endExternalSubtitleBatch(for: source) }
            for subtitle in subtitles {
                guard !Task.isCancelled else { return }
                let file: URL
                do {
                    file = try await server.downloadSubtitle(subtitle)
                } catch is CancellationError {
                    return
                } catch {
                    // 单条下载失败跳过下一条，但留日志——静默的话用户只看到
                    // 「明明有字幕却挂不上」。
                    AppDiagnostics.logWarning("下载外挂字幕失败 item=\(itemID) track=\(subtitle.index) error=\(error)")
                    continue
                }
                // 下载的字幕进了受管目录：捎带触发一次限额维护（日定时器也会兜底）。
                AppDiagnostics.requestStorageMaintenance()
                guard !Task.isCancelled,
                      self.activePlaybackIdentity == identity else { return }
                // 名字和语言都喂过去：内核不带这些元数据，靠 App 层映射在菜单里显示。
                let name = Self.subtitleDisplayName(for: subtitle)
                guard playback.addExternalSubtitle(fileURL: file, name: name, for: source) else { return }
            }
        }
    }
}

