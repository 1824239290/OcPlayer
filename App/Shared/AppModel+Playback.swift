import CoreModel
import DanmakuKit
import DiagnosticsKit
import Foundation
import JellyfinKit

extension AppModel {
    // MARK: - 弹幕设置（弹弹play 网关）

    func updateDanmakuGateway(urlString: String, apiKey: String) {
        // Commit both values before restarting. This avoids ever pairing a new
        // gateway host with the previously saved credential.
        danmakuModel.updateGateway(urlString: urlString, apiKey: apiKey)
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
        let playableItem: MediaItem
        do {
            guard let resolved = try await resolvePlayableItem(for: item, server: server) else {
                playbackPreparation = .failed(title: item.name, error: "该剧没有可播放的剧集")
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
            let source = info.mediaSources.first { $0.supportsDirectPlay == true }
                ?? info.mediaSources.first { $0.supportsDirectStream == true }
                ?? info.mediaSources.first
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
            if let uri = try? server.streamURL(itemID: playableItem.id) {
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
    /// 电影 / 集数 / 音频等已经是叶子，剧集则优先复用首页 nextUp，避免额外请求。
    func resolvePlayableItem(for item: MediaItem, server: JellyfinServer) async throws -> MediaItem? {
        guard item.kind == .series else { return item }

        if let next = home.nextUp.first(where: { $0.seriesID == item.id }) {
            return next
        }

        let episodes = try await server.episodes(seriesID: item.id, seasonID: nil)
        let regularEpisodes = episodes.filter { $0.seasonNumber != 0 }
        return regularEpisodes.first(where: { !($0.playState?.played ?? false) })
            ?? regularEpisodes.first
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
            await playback.loadChapters(server: server, for: request)
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

    var dandanplayConfiguration: DandanplayConfiguration? {
        guard danmakuModel.dandanplayStore.isConfigured else { return nil }
        return DandanplayConfiguration(
            baseURL: danmakuModel.dandanplayStore.gatewayURL,
            apiKey: danmakuModel.dandanplayStore.apiKey,
            userAgent: Self.dandanplayUserAgent
        )
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
        Task {
            await stopped?.value
            await loadHome()
            self.detailRefreshGeneration &+= 1
        }
    }

    /// Hook this to `scenePhase == .background`. It immediately snapshots the
    /// current position instead of waiting for the next ten-second heartbeat.
    @discardableResult
    func playbackDidEnterBackground() -> Task<Void, Never>? {
        guard let report = playbackReporting?.reportBackgroundSnapshot() else { return nil }
        if case .terminal = report {
            clearPlaybackSessionState()
        }
        return report.task
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 关联过但从没打开过详情页时本地是空的，先补齐再匹配。
                try await self.bangumi.context.ensureSubjectLoaded(subjectID)
                let episodes = try await self.bangumi.context.fetchEpisodes(subjectId: subjectID)
                // 精确匹配主篇集号。sort 是 Float（特典可能是 12.5），只认整数集号相等的，
                // 匹配不上就不动——宁可不标，也不要标错集。
                let matched = episodes.first(where: {
                    $0.type == .main && $0.sort == Float(episodeNumber)
                })
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
                try await self.bangumi.context.updateEpisodeCollection(
                    episodeId: episode.id, type: .collect)
                let episodeID = episode.id
                BangumiDiagnostics.log(
                    "播放结束已标记 Bangumi subject=\(subjectID) episode=\(episodeID)")
                // 服务端对条目状态的连带推进（看完最后一集 → 在看变看过）本地猜不了，
                // 回读对齐并让进度页列表/计数立刻刷新。
                await self.bangumi.context.refreshSubjectAfterProgressChange(subjectID)
            } catch {
                BangumiDiagnostics.log("播放结束标记 Bangumi 已看失败 error=\(error)")
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
    /// 装载完如果一条字幕都没选，自动挑中文优先的一条。
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
            _ = playback.autoSelectSubtitleIfNone(for: source)
        }
    }
}

