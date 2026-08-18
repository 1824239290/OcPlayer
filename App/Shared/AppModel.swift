import CoreModel
import Foundation
import JellyfinKit
import Observation

/// 应用的中枢状态机：登录 → 浏览 → 播放串联。
///
/// UI 只读这个类的属性、调它的方法；Jellyfin 细节被挡在 `JellyfinServer` 后面，
/// 内核细节被挡在 `PlaybackController` 后面。
@MainActor
@Observable
final class AppModel {

    // MARK: - 登录态

    enum Phase {
        /// 刚启动，正在从磁盘恢复会话
        case boot
        /// 没有可用会话，进登录流程
        case onboarding
        case ready
    }

    private(set) var phase: Phase = .boot

    private let store: ServerStore
    private(set) var server: JellyfinServer?

    /// Every authenticated session gets a new generation. Async responses keep
    /// their generation and may only mutate state while it is still current.
    private var sessionGeneration = 0
    private var initialDataTask: Task<Void, Never>?

    // MARK: - Onboarding 中间态

    /// `startLogin` 成功后非 nil（已探明这是台 Jellyfin，等用户选登录方式）。
    private(set) var loginSession: LoginSession?
    private(set) var isProbingServer = false
    private(set) var isAuthenticating = false
    /// Quick Connect 轮询期间展示的配对码。
    private(set) var quickConnectCode: String?
    private(set) var onboardingError: String?

    private var quickConnectTask: Task<Void, Never>?
    private var loginAttemptGeneration = 0

    // MARK: - 浏览

    private(set) var libraries: [MediaLibrary] = []

    struct HomeData {
        /// 轮播素材（最多 5 张，都带背景图）。
        var heroes: [MediaItem] = []
        /// 轮播眉题前缀，与 `heroes` 的实际来源一致（收藏为空回落时会显示「最近添加」）。
        var heroLabel = "最近添加"
        var resume: [MediaItem] = []
        var nextUp: [MediaItem] = []
        var latest: [MediaItem] = []
        var isLoading = false
        var error: String?
    }

    private(set) var home = HomeData()
    /// 同一会话内可能同时发生下拉刷新和设置切换；只有最新一次首页请求可以写回。
    private var homeLoadGeneration: UInt64 = 0

    // MARK: - 首页轮播（设置里可选）

    enum HeroSource: String, CaseIterable, Identifiable, Sendable {
        case latest
        case favorites

        var id: String { rawValue }

        var label: String {
            switch self {
            case .latest: "最近添加"
            case .favorites: "我的收藏"
            }
        }
    }

    private static let heroCarouselEnabledKey = "dev.jumusu.ocplayer.heroCarouselEnabled"
    private static let heroSourceKey = "dev.jumusu.ocplayer.heroSource"

    /// 未写入偏好时 `bool(forKey:)` 返回 false，因此轮播默认关闭。
    private(set) var isHeroCarouselEnabled: Bool
    private(set) var heroSource: HeroSource

    func setHeroSource(_ source: HeroSource) {
        guard source != heroSource else { return }
        heroSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.heroSourceKey)
        if isHeroCarouselEnabled {
            Task { await loadHome() }
        }
    }

    func setHeroCarouselEnabled(_ enabled: Bool) {
        guard enabled != isHeroCarouselEnabled else { return }
        isHeroCarouselEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.heroCarouselEnabledKey)

        if !enabled {
            home.heroes = []
        }
        Task { await loadHome() }
    }

    // MARK: - 导航

    enum Section: Hashable {
        case home
        case settings
        case library(MediaLibrary.ID)
    }

    enum Route: Hashable {
        case detail(MediaItem)
    }

    var selectedSection: Section = .home {
        didSet { if selectedSection != oldValue { path = [] } }
    }

    /// Mac / iPad 的 push 栈。iPhone 不用它（多 Tab 多栈会串），走下面的模态。
    var path: [Route] = []

    /// iPhone：详情页 sheet。
    var presentedDetail: MediaItem?

    /// 播放覆盖层：非 nil 时播放器盖住整个 App（双端同一套，见 RootView）。
    var presentedPlayer: PlaybackRequest?

    private(set) var isCompact = false

    /// 播放器控制引用（RootView 装配时注入）：进度上报 / 连播要读实时位置。
    weak var playback: PlaybackController?

    /// 由外壳在布局定型时告知（iPhone → compact），详情导航方式随之切换。
    func setCompact(_ compact: Bool) {
        isCompact = compact
    }

    func openDetail(_ item: MediaItem) {
        if isCompact {
            presentedDetail = item
        } else {
            path.append(.detail(item))
        }
    }

    /// 首页的续播条目通常是 Episode；详情入口应落到所属电视剧，而不是单集。
    /// 先复用首页已有的 Series 数据，没有缓存时用父级 ID 构造轻量占位，
    /// DetailView 随后会按该 ID 拉取完整详情、季和分集。
    func openSeriesDetail(for item: MediaItem) {
        guard let seriesID = item.seriesID else {
            openDetail(item)
            return
        }

        let cachedSeries = (home.heroes + home.latest).first {
            $0.id == seriesID && $0.kind == .series
        }
        let series = cachedSeries ?? MediaItem(
            id: seriesID,
            name: item.seriesName ?? item.name,
            kind: .series
        )
        openDetail(series)
    }

    // MARK: - 初始化

    init(store: ServerStore = ServerStore()) {
        self.store = store
        isHeroCarouselEnabled = UserDefaults.standard.bool(forKey: Self.heroCarouselEnabledKey)
        heroSource = UserDefaults.standard.string(forKey: Self.heroSourceKey)
            .flatMap { HeroSource(rawValue: $0) } ?? .latest
    }

    /// 启动时调用：有档案 + token 就静默恢复，否则进 onboarding。
    func bootstrap() {
        guard phase == .boot else { return }
        if let restored = JellyfinServer(restoringFrom: store) {
            activate(server: restored)
        } else {
            phase = .onboarding
        }
    }

    // MARK: - 登录流程

    /// Onboarding 第一步：验证服务器地址。
    func connectServer(_ rawURL: String) async {
        loginAttemptGeneration &+= 1
        let attempt = loginAttemptGeneration
        isProbingServer = true
        onboardingError = nil
        defer {
            if loginAttemptGeneration == attempt {
                isProbingServer = false
            }
        }
        do {
            let session = try await JellyfinServer.startLogin(urlString: rawURL)
            guard loginAttemptGeneration == attempt, phase == .onboarding else { return }
            loginSession = session
            await startQuickConnect()
        } catch let error as JellyfinError {
            if loginAttemptGeneration == attempt { onboardingError = error.errorDescription }
        } catch {
            if loginAttemptGeneration == attempt { onboardingError = "\(error)" }
        }
    }

    /// 服务器确认后自动开始 Quick Connect 轮询（失败了也不阻塞密码登录）。
    func startQuickConnect() async {
        guard let session = loginSession else { return }
        quickConnectTask?.cancel()
        quickConnectCode = nil
        quickConnectTask = Task { [weak self] in
            do {
                for try await event in session.quickConnectEvents {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case let .polling(code):
                        self.quickConnectCode = code
                    case let .authenticated(secret):
                        await self.completeLogin { try await session.signIn(quickConnectSecret: secret) }
                    }
                }
            } catch is CancellationError {
            } catch let error as JellyfinError {
                // Quick Connect 没开 / 超时：提示一句，账号密码仍然可用。
                // 别覆盖正在进行的密码登录 / 已成功的状态（用户在输密码时 QC 后台超时也算正常）。
                if let self, self.loginSession === session,
                   !self.isAuthenticating, self.phase == .onboarding {
                    self.onboardingError = error.errorDescription
                }
            } catch {
                if let self, self.loginSession === session,
                   !self.isAuthenticating, self.phase == .onboarding {
                    self.onboardingError = "\(error)"
                }
            }
        }
    }

    /// 账号密码登录（Quick Connect 之外的兜底）。
    func signIn(username: String, password: String) async {
        guard let session = loginSession else { return }
        await completeLogin { try await session.signIn(username: username, password: password) }
    }

    private func completeLogin(_ authenticate: () async throws -> LoginResult) async {
        guard let session = loginSession, !isAuthenticating else { return }
        isAuthenticating = true
        onboardingError = nil
        defer {
            if self.loginSession == nil || self.loginSession === session {
                self.isAuthenticating = false
            }
        }
        do {
            let result = try await authenticate()
            guard loginSession === session, phase == .onboarding else { return }
            let server = try session.finish(result, store: self.store)
            quickConnectTask?.cancel()
            quickConnectTask = nil
            quickConnectCode = nil
            loginSession = nil
            // phase 已切到 ready，首屏数据靠 initialDataTask 异步驱动 home.isLoading
            // 的 loading 态——不阻塞登录 Task，让 Quick Connect 的轮询流尽快结束。
            activate(server: server)
        } catch let error as JellyfinError {
            if loginSession === session { onboardingError = error.errorDescription }
        } catch {
            if loginSession === session { onboardingError = "\(error)" }
        }
    }

    func resetOnboarding() {
        loginAttemptGeneration &+= 1
        quickConnectTask?.cancel()
        quickConnectTask = nil
        isAuthenticating = false
        quickConnectCode = nil
        loginSession = nil
        onboardingError = nil
    }

    func signOut() {
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        _ = finishReporting()
        playback?.stopPlayback()
        initialDataTask?.cancel()
        initialDataTask = nil
        quickConnectTask?.cancel()
        quickConnectTask = nil
        loginAttemptGeneration &+= 1
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        sessionGeneration &+= 1
        if let server {
            store.signOut(id: server.profile.id)
        }
        loginSession = nil
        quickConnectCode = nil
        isProbingServer = false
        isAuthenticating = false
        onboardingError = nil
        server = nil
        libraries = []
        home = HomeData()
        path = []
        presentedPlayer = nil
        selectedSection = .home
        phase = .onboarding
    }

    // MARK: - 数据加载

    private func activate(server: JellyfinServer) {
        initialDataTask?.cancel()
        sessionGeneration &+= 1
        self.server = server
        phase = .ready
        let generation = sessionGeneration
        initialDataTask = Task { [weak self] in
            await self?.loadInitialData(server: server, generation: generation)
        }
    }

    private func sessionIsCurrent(_ generation: Int, server: JellyfinServer) -> Bool {
        sessionGeneration == generation && self.server?.profile.id == server.profile.id
    }

    private func loadInitialData(server: JellyfinServer, generation: Int) async {
        await reloadBrowserData(server: server, generation: generation)
    }

    /// 重载首页和侧栏依赖的媒体库。断网后的重试必须同时恢复两部分数据。
    func reloadBrowserData() async {
        guard let server else { return }
        await reloadBrowserData(server: server, generation: sessionGeneration)
    }

    private func reloadBrowserData(server: JellyfinServer, generation: Int) async {
        async let libs: Void = loadLibraries(server: server, generation: generation)
        async let home: Void = loadHome(server: server, generation: generation)
        _ = await (libs, home)
    }

    private func loadLibraries(server: JellyfinServer, generation: Int) async {
        do {
            let loaded = try await server.userViews()
            guard sessionIsCurrent(generation, server: server) else { return }
            libraries = loaded
        } catch {
            // 首页错误里会带重试；媒体库会随首页重试和下拉刷新再次加载。
        }
    }

    func loadHome() async {
        guard let server else { return }
        await loadHome(server: server, generation: sessionGeneration)
    }

    private func loadHome(server: JellyfinServer, generation: Int) async {
        guard sessionIsCurrent(generation, server: server) else { return }
        homeLoadGeneration &+= 1
        let loadGeneration = homeLoadGeneration
        home.isLoading = true
        home.error = nil
        defer {
            if sessionIsCurrent(generation, server: server),
               homeLoadGeneration == loadGeneration {
                home.isLoading = false
            }
        }
        do {
            let carouselEnabled = isHeroCarouselEnabled
            let carouselSource = heroSource
            async let resume = server.resumeItems()
            async let nextUp = server.nextUp()
            async let latest = server.latestItems()
            async let favorites = Self.favoriteHeroItems(
                server: server,
                enabled: carouselEnabled,
                source: carouselSource
            )
            let (resumeItems, nextUpItems, latestItems) = try await (resume, nextUp, latest)
            let favoriteItems = await favorites
            guard sessionIsCurrent(generation, server: server),
                  homeLoadGeneration == loadGeneration
            else { return }
            home.resume = resumeItems
            home.nextUp = nextUpItems
            home.latest = latestItems
            if carouselEnabled {
                // 轮播：按设置取来源，只留有背景图的；收藏为空/全无背景图时回落最近添加。
                let (heroes, label) = Self.heroes(
                    for: carouselSource,
                    latest: latestItems,
                    favorites: favoriteItems
                )
                home.heroes = heroes
                home.heroLabel = label
            } else {
                home.heroes = []
            }
        } catch let error as JellyfinError {
            guard sessionIsCurrent(generation, server: server),
                  homeLoadGeneration == loadGeneration
            else { return }
            home.error = error.errorDescription
        } catch {
            guard sessionIsCurrent(generation, server: server),
                  homeLoadGeneration == loadGeneration
            else { return }
            home.error = "\(error)"
        }
    }

    /// 仅在轮播开启且来源为收藏时请求收藏；失败时仍回落最近添加。
    private static func favoriteHeroItems(
        server: JellyfinServer,
        enabled: Bool,
        source: HeroSource
    ) async -> [MediaItem] {
        guard enabled, source == .favorites else { return [] }
        return (try? await server.favoriteItems()) ?? []
    }

    /// 轮播素材选取：按来源整池取前 5 张有背景图的；
    /// 收藏模式收藏为空（或全都没有背景图）时整池回落最近添加。
    private static func heroes(
        for source: HeroSource,
        latest: [MediaItem],
        favorites: [MediaItem]
    ) -> (items: [MediaItem], label: String) {
        if source == .favorites {
            let favoritesWithBackdrop = favorites.filter { $0.backdropImageTag != nil }
            if !favoritesWithBackdrop.isEmpty {
                return (favoritesWithBackdrop.prefix(5).map { $0 }, HeroSource.favorites.label)
            }
        }
        return (latest.filter { $0.backdropImageTag != nil }.prefix(5).map { $0 }, HeroSource.latest.label)
    }

    // MARK: - 播放串联（UI 只调这里，不自己拼 URL）

    /// 由详情页 / 首页卡片发起的播放。`resumeSeconds` 来自服务端 UserData。
    /// 播放器以覆盖层盖住整个 App（不占侧栏、不压导航栈）。
    /// 同时启动进度上报（Start → 10s 心跳 → Stopped）和「下一集」解析。
    /// 先走 PlaybackInfo 拿 MediaSource；失败时回退到旧的直连 URL，保证老服务器也能播。
    func play(_ item: MediaItem, resumeSeconds: Double?) {
        cancelPlaybackOpen()
        retryPlaybackItem = item
        isPlaybackOpening = true
        let generation = playbackOpenGeneration
        playbackOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.playbackOpenGeneration == generation {
                    self.playbackOpenTask = nil
                    self.isPlaybackOpening = false
                }
            }
            await self.openPlayback(item: item, resumeSeconds: resumeSeconds)
        }
    }

    private func cancelPlaybackOpen() {
        playbackOpenGeneration &+= 1
        playbackOpenTask?.cancel()
        playbackOpenTask = nil
        isPlaybackOpening = false
    }

    @MainActor
    private func openPlayback(item: MediaItem, resumeSeconds: Double?) async {
        guard let server else { return }
        finishReporting()   // 上一条的 Stopped（换片场景）

        // 首页轮播和收藏可以直接包含 Series，但 Jellyfin 的 PlaybackInfo/stream
        // 只接受可播放的叶子条目。沿用详情页的语义：优先「接下来看」，否则取
        // 首个未看完的常规剧集；避免把 Series ID 直接送进 /Videos/{id}/stream。
        let playableItem: MediaItem
        do {
            guard let resolved = try await resolvePlayableItem(for: item, server: server) else {
                home.error = "该剧没有可播放的剧集"
                return
            }
            guard !Task.isCancelled else { return }
            playableItem = resolved
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            home.error = "剧集加载失败：\(error)"
            return
        }

        let effectiveResume = playableItem.id == item.id
            ? resumeSeconds
            : playableItem.playState?.positionSeconds
        let title = playableItem.episodeLabel.map {
            "\(playableItem.seriesName ?? playableItem.name) \($0)"
        } ?? playableItem.name
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
            if let uri = try? server.streamURL(itemID: playableItem.id) {
                presentPlayback(title: title, uri: uri, authHeader: server.authorizationHeader,
                                resumeSeconds: effectiveResume, item: playableItem,
                                sessionContext: PlaybackSessionContext(
                                    itemID: playableItem.id,
                                    durationSeconds: playableItem.runtimeSeconds
                                ))
            } else {
                home.error = "播放信息获取失败：\(error)"
            }
        }
    }

    /// 把浏览层条目归一化为可直接播放的叶子条目。
    /// 电影 / 集数 / 音频等已经是叶子，剧集则优先复用首页 nextUp，避免额外请求。
    private func resolvePlayableItem(for item: MediaItem, server: JellyfinServer) async throws -> MediaItem? {
        guard item.kind == .series else { return item }

        if let next = home.nextUp.first(where: { $0.seriesID == item.id }) {
            return next
        }

        let episodes = try await server.episodes(seriesID: item.id, seasonID: nil)
        let regularEpisodes = episodes.filter { $0.seasonNumber != 0 }
        return regularEpisodes.first(where: { !($0.playState?.played ?? false) })
            ?? regularEpisodes.first
    }

    private func presentPlayback(
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
        presentedPlayer = request
        retryPlaybackItem = item
        nowPlayingItem = item
        startReporting(item: item, resumeSeconds: resumeSeconds, request: request)
    }

    /// HUD「Continue Watching」：手动跳到连播解析出的下一集（走完整播放串联）。
    func playNextEpisode() {
        guard let next = nextEpisode else { return }
        // 立即消费，避免 PlaybackInfo 请求返回前连续点击触发多次换片。
        nextEpisode = nil
        play(next, resumeSeconds: 0)
    }

    /// 本地文件（onOpenURL / 设置页 / 自检）：不走 Jellyfin，直接上覆盖层。
    /// 本地播放不依赖服务器 —— 登录页挡着就直接越过。
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
        playback?.prepareForPresentation(request)
        presentedPlayer = request
    }

    /// 直连链接（设置页入口）：请求由 `PlaybackController.request(uri:token:)` 构造好。
    func presentRequest(_ request: PlaybackRequest) {
        if phase == .onboarding { phase = .ready }
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        finishReporting()
        playback?.prepareForPresentation(request)
        presentedPlayer = request
    }

    func dismissPlayer() {
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        let stopped = finishReporting()   // 退出播放器 → Stopped，服务器记下续播位置
        presentedPlayer = nil
        // 等 Stopped 上报落库后刷新首页，让「继续观看」立刻反映刚退出的进度。
        Task {
            await stopped?.value
            await loadHome()
        }
    }

    /// Hook this to `scenePhase == .background`. It immediately snapshots the
    /// current position instead of waiting for the next ten-second heartbeat.
    @discardableResult
    func playbackDidEnterBackground() -> Task<Void, Never>? {
        guard let context = reportingContext,
              let requestID = reportingRequestID,
              let server,
              let playback
        else { return nil }
        let state = playback.state
        if state.state == .stopped || state.state == .error
            || playback.failedRequestID == requestID {
            return finishReporting()
        }

        let generation = sessionGeneration
        let position = Double(state.position.microseconds) / 1_000_000
        return enqueueProgressReport(
            server: server,
            context: context,
            requestID: requestID,
            generation: generation,
            positionSeconds: position,
            isPaused: state.state == .paused,
            precedingStart: reportingStartTask
        )
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
        guard !isPlaybackOpening else { return }
        guard let item = nowPlayingItem ?? retryPlaybackItem else {
            playback?.retryLast()
            return
        }
        let currentPosition = playback.map { Double($0.state.position.microseconds) / 1_000_000 }
        let fallbackPosition = presentedPlayer?.resumeSeconds
        let resumeSeconds = currentPosition.flatMap { $0 >= 30 ? $0 : nil } ?? fallbackPosition
        play(item, resumeSeconds: resumeSeconds)
    }

    // MARK: - 进度上报 + 下一集连播（M2）

    private var reportingTask: Task<Void, Never>?
    /// 当前正在解析播放地址的请求。旧请求不能在新请求之后返回并覆盖播放器。
    private var playbackOpenTask: Task<Void, Never>?
    private var playbackOpenGeneration: UInt64 = 0
    private(set) var isPlaybackOpening = false
    /// 保留 Jellyfin 条目，重试请求期间 finishReporting 清掉 nowPlayingItem 后仍可安全重试。
    private var retryPlaybackItem: MediaItem?
    private var reportingItemID: String?
    private var reportingRequestID: PlaybackRequest.ID?
    private var reportingContext: PlaybackSessionContext?
    private var reportingStartTask: Task<Void, Never>?
    private var pendingLifecycleReport: Task<Void, Never>?
    /// The latest explicit Stopped report. A new Start must await it.
    private var pendingStoppedReport: Task<Void, Never>?
    private var pendingStoppedRequestID: PlaybackRequest.ID?
    private var lastCompletedStoppedRequestID: PlaybackRequest.ID?
    /// Prevents an older completed stop from clearing a newer queued stop.
    private var stoppedReportGeneration: UInt64 = 0
    /// 覆盖层正在播放的条目（HUD 标题 / 继续观看用）；退出 / 换片时随上报一起清。
    private(set) var nowPlayingItem: MediaItem?
    /// 连播解析出的「下一集」；HUD「Continue Watching」复用它，nil = 没有下一集。
    private(set) var nextEpisode: MediaItem?
    private var nextEpisodeTask: Task<Void, Never>?
    private var externalSubtitleTask: Task<Void, Never>?

    private func startReporting(
        item: MediaItem,
        resumeSeconds: Double?,
        request: PlaybackRequest
    ) {
        reportingTask?.cancel()
        nextEpisode = nil
        guard let server, let context = request.sessionContext else { return }
        let itemID = item.id
        let generation = sessionGeneration
        reportingItemID = itemID
        reportingRequestID = request.id
        reportingContext = context
        resolveNextEpisode(after: item, generation: generation)
        loadExternalSubtitles(for: item, generation: generation, request: request)

        let precedingStop = pendingStoppedReport
        let startTask = Task {
            await precedingStop?.value
            await server.reportPlaybackStart(
                context: context,
                positionSeconds: resumeSeconds ?? 0
            )
        }
        reportingStartTask = startTask
        reportingTask = Task { [weak self] in
            await startTask.value
            guard !Task.isCancelled else { return }
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000))
                guard let self, !Task.isCancelled else { return }
                guard self.sessionGeneration == generation,
                      self.reportingItemID == itemID,
                      self.reportingRequestID == request.id else { return }
                ticks += 1
                guard let state = self.playback?.state else { return }

                let position = Double(state.position.microseconds) / 1_000_000
                let duration = Double(state.duration.microseconds) / 1_000_000

                // 播完 / 出错：补一条 Stopped；播完且有下一集 → 连播
                let sourceOpenFailed = self.playback?.failedRequestID == request.id
                if state.state == .stopped || state.state == .error || sourceOpenFailed {
                    let stopTask = self.enqueueStoppedReport(
                        server: server,
                        context: context,
                        requestID: request.id,
                        positionSeconds: position,
                        precedingStart: startTask,
                        precedingLifecycle: self.pendingLifecycleReport
                    )
                    await stopTask.value
                    guard self.sessionGeneration == generation,
                          self.reportingItemID == itemID,
                          self.reportingRequestID == request.id else { return }
                    // 已上报 Stopped，清掉 id，避免下面 play(next)→finishReporting() 再补一条重复的。
                    self.reportingItemID = nil
                    self.reportingRequestID = nil
                    self.reportingContext = nil
                    self.reportingStartTask = nil
                    if state.state == .stopped, duration > 0,
                       position >= duration - 2, let next = self.nextEpisode {
                        self.play(next, resumeSeconds: 0)
                    }
                    return
                }

                // 心跳：每 10 秒一条（暂停也报，带 isPaused）
                if ticks % 10 == 0 {
                    let progressTask = self.enqueueProgressReport(
                        server: server,
                        context: context,
                        requestID: request.id,
                        generation: generation,
                        positionSeconds: position,
                        isPaused: state.state == .paused,
                        precedingStart: startTask
                    )
                    await progressTask.value
                }
            }
        }
    }

    /// All Progress requests share one chain. A subsequent Stopped request waits
    /// for the latest link, so a slow heartbeat can never land after Stopped.
    private func enqueueProgressReport(
        server: JellyfinServer,
        context: PlaybackSessionContext,
        requestID: PlaybackRequest.ID,
        generation: Int,
        positionSeconds: Double,
        isPaused: Bool,
        precedingStart: Task<Void, Never>?
    ) -> Task<Void, Never> {
        let precedingLifecycle = pendingLifecycleReport
        let task = Task { [weak self] in
            await precedingStart?.value
            await precedingLifecycle?.value
            guard let self, !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.reportingRequestID == requestID,
                  self.reportingContext == context
            else { return }
            await server.reportPlaybackProgress(
                context: context,
                positionSeconds: positionSeconds,
                isPaused: isPaused
            )
        }
        pendingLifecycleReport = task
        return task
    }

    /// 换片 / 退出播放器：补 Stopped 后停表。返回 Stopped 上报任务（供调用方等待落库）。
    @discardableResult
    private func finishReporting() -> Task<Void, Never>? {
        reportingTask?.cancel()
        reportingTask = nil
        let precedingStart = reportingStartTask
        reportingStartTask = nil
        let precedingLifecycle = pendingLifecycleReport
        pendingLifecycleReport = nil
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        nextEpisode = nil
        nowPlayingItem = nil
        defer {
            reportingItemID = nil
            reportingRequestID = nil
            reportingContext = nil
        }
        guard let context = reportingContext, let server else { return nil }
        let position = playback.map { Double($0.state.position.microseconds) / 1_000_000 } ?? 0
        playerLog.info("上报 Stopped item=\(context.itemID) position=\(position)")
        return enqueueStoppedReport(
            server: server,
            context: context,
            requestID: reportingRequestID,
            positionSeconds: position,
            precedingStart: precedingStart,
            precedingLifecycle: precedingLifecycle
        )
    }

    /// Natural EOF and an explicit close can race for the same request. Every
    /// Stopped report enters this queue so it is both deduplicated and ordered
    /// before the next playback Start.
    private func enqueueStoppedReport(
        server: JellyfinServer,
        context: PlaybackSessionContext,
        requestID: PlaybackRequest.ID?,
        positionSeconds: Double,
        precedingStart: Task<Void, Never>? = nil,
        precedingLifecycle: Task<Void, Never>? = nil
    ) -> Task<Void, Never> {
        if let requestID, lastCompletedStoppedRequestID == requestID {
            return Task {}
        }
        if let requestID,
           pendingStoppedRequestID == requestID,
           let pendingStoppedReport {
            return pendingStoppedReport
        }

        let precedingStop = pendingStoppedReport
        stoppedReportGeneration &+= 1
        let stopGeneration = stoppedReportGeneration
        let task = Task { [weak self] in
            await precedingStop?.value
            await precedingStart?.value
            await precedingLifecycle?.value
            await server.reportPlaybackStopped(context: context, positionSeconds: positionSeconds)
            guard let self, self.stoppedReportGeneration == stopGeneration else { return }
            self.lastCompletedStoppedRequestID = requestID
            self.pendingStoppedReport = nil
            self.pendingStoppedRequestID = nil
        }
        pendingStoppedReport = task
        pendingStoppedRequestID = requestID
        return task
    }

    private func resolveNextEpisode(after item: MediaItem, generation: Int) {
        guard item.kind == .episode, let seriesID = item.seriesID, let server else { return }
        nextEpisodeTask?.cancel()
        nextEpisodeTask = Task { [weak self] in
            guard let episodes = try? await server.episodes(seriesID: seriesID, seasonID: nil),
                  let self
            else { return }
            guard !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.reportingItemID == item.id else { return }
            // 第 0 季是特典/花絮，不当「下一集」自动连播；当前集本身是特典时
            // firstIndex 落空，同样不连播——看完特典就该停，让用户自己选。
            let regular = episodes.filter { $0.seasonNumber != 0 }
            guard let index = regular.firstIndex(where: { $0.id == item.id }),
                  regular.indices.contains(index + 1)
            else { return }
            self.nextEpisode = regular[index + 1]
        }
    }

    /// Jellyfin 侧车字幕（`.zh.srt` 这类不在容器里的）：列出 → 逐条下载 → 喂给内核。
    /// 装载完如果一条字幕都没选，自动挑中文优先的一条。
    private func loadExternalSubtitles(
        for item: MediaItem,
        generation: Int,
        request: PlaybackRequest
    ) {
        guard let server else { return }
        let itemID = item.id
        externalSubtitleTask?.cancel()
        externalSubtitleTask = Task { [weak self] in
            guard let subtitles = try? await server.externalSubtitles(itemID: itemID),
                  !subtitles.isEmpty, let self
            else { return }
            // 解析期间用户已换片 → 丢弃，避免字幕串台
            guard !Task.isCancelled,
                  self.sessionGeneration == generation,
                  self.reportingItemID == itemID,
                  self.reportingRequestID == request.id,
                  let playback = self.playback,
                  let source = await playback.waitUntilSourceReady(for: request.id)
            else { return }
            for subtitle in subtitles {
                guard !Task.isCancelled else { return }
                guard let file = try? await server.downloadSubtitle(subtitle) else { continue }
                guard !Task.isCancelled,
                      self.sessionGeneration == generation,
                      self.reportingItemID == itemID,
                      self.reportingRequestID == request.id else { return }
                guard playback.addExternalSubtitle(fileURL: file, for: source) else { return }
            }
            _ = playback.autoSelectSubtitleIfNone(for: source)
        }
    }

    /// Onboarding 上的「先不登录」：进主框架（本地播放可用），服务器稍后在设置里连。
    func skipLogin() {
        phase = .ready
    }

    /// 未连接状态下首页的「去连接」：回登录流程。
    func reconnectFlow() {
        path = []
        selectedSection = .home
        resetOnboarding()
        phase = .onboarding
    }

    // MARK: - 派生

    var currentUserLabel: String {
        guard let server else { return "" }
        let profile = server.profile
        return profile.userName ?? profile.userID
    }

    var serverLabel: String {
        guard let profile = server?.profile else { return "" }
        return "\(profile.serverName) · Jellyfin \(profile.serverVersion ?? "")"
    }
}
