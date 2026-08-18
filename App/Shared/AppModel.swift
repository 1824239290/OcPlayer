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

    // MARK: - 首页轮播来源（设置里可选）

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

    private static let heroSourceKey = "dev.jumusu.ocplayer.heroSource"

    var heroSource: HeroSource {
        guard let raw = UserDefaults.standard.string(forKey: Self.heroSourceKey),
              let source = HeroSource(rawValue: raw)
        else { return .latest }
        return source
    }

    func setHeroSource(_ source: HeroSource) {
        guard source != heroSource else { return }
        UserDefaults.standard.set(source.rawValue, forKey: Self.heroSourceKey)
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

    // MARK: - 初始化

    init(store: ServerStore = ServerStore()) {
        self.store = store
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
        playbackOpenTask?.cancel()
        playbackOpenTask = nil
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
        home.isLoading = true
        home.error = nil
        defer {
            if sessionIsCurrent(generation, server: server) {
                home.isLoading = false
            }
        }
        do {
            async let resume = server.resumeItems()
            async let nextUp = server.nextUp()
            async let latest = server.latestItems()
            async let favorites = server.favoriteItems()
            let (resumeItems, nextUpItems, latestItems) = try await (resume, nextUp, latest)
            // 收藏请求失败不当整页错误处理：按空收藏回落「最近添加」。
            let favoriteItems = (try? await favorites) ?? []
            guard sessionIsCurrent(generation, server: server) else { return }
            home.resume = resumeItems
            home.nextUp = nextUpItems
            home.latest = latestItems
            // 轮播：按设置取来源，只留有背景图的；收藏为空/全无背景图时回落最近添加。
            let (heroes, label) = Self.heroes(
                for: heroSource,
                latest: latestItems,
                favorites: favoriteItems
            )
            home.heroes = heroes
            home.heroLabel = label
        } catch let error as JellyfinError {
            guard sessionIsCurrent(generation, server: server) else { return }
            home.error = error.errorDescription
        } catch {
            guard sessionIsCurrent(generation, server: server) else { return }
            home.error = "\(error)"
        }
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
        playbackOpenTask?.cancel()
        playbackOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.openPlayback(item: item, resumeSeconds: resumeSeconds)
        }
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
            let uri = try server.streamURL(itemID: playableItem.id, mediaSourceID: source?.id)
            guard !Task.isCancelled else { return }
            presentPlayback(title: title, uri: uri, authHeader: server.authorizationHeader,
                            resumeSeconds: effectiveResume, item: playableItem)
        } catch {
            // PlaybackInfo 不可用（老版本 / 端点被关）时退回原来的直连 URL。
            if Task.isCancelled { return }
            if let uri = try? server.streamURL(itemID: playableItem.id) {
                presentPlayback(title: title, uri: uri, authHeader: server.authorizationHeader,
                                resumeSeconds: effectiveResume, item: playableItem)
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
        item: MediaItem
    ) {
        presentedPlayer = PlaybackRequest(
            title: title,
            uri: uri,
            authHeader: authHeader,
            resumeSeconds: resumeSeconds
        )
        nowPlayingItem = item
        startReporting(item: item, resumeSeconds: resumeSeconds)
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
        playbackOpenTask?.cancel()
        playbackOpenTask = nil
        finishReporting()
        presentedPlayer = PlaybackRequest(
            title: url.lastPathComponent,
            uri: url.path,
            securityScopedURL: url
        )
    }

    /// 直连链接（设置页入口）：请求由 `PlaybackController.request(uri:token:)` 构造好。
    func presentRequest(_ request: PlaybackRequest) {
        if phase == .onboarding { phase = .ready }
        playbackOpenTask?.cancel()
        playbackOpenTask = nil
        finishReporting()
        presentedPlayer = request
    }

    func dismissPlayer() {
        playbackOpenTask?.cancel()
        playbackOpenTask = nil
        let stopped = finishReporting()   // 退出播放器 → Stopped，服务器记下续播位置
        presentedPlayer = nil
        // 等 Stopped 上报落库后刷新首页，让「继续观看」立刻反映刚退出的进度。
        Task {
            await stopped?.value
            await loadHome()
        }
    }

    // MARK: - 进度上报 + 下一集连播（M2）

    private var reportingTask: Task<Void, Never>?
    /// 当前正在解析播放地址的请求。旧请求不能在新请求之后返回并覆盖播放器。
    private var playbackOpenTask: Task<Void, Never>?
    private var reportingItemID: String?
    /// 覆盖层正在播放的条目（HUD 标题 / 继续观看用）；退出 / 换片时随上报一起清。
    private(set) var nowPlayingItem: MediaItem?
    /// 连播解析出的「下一集」；HUD「Continue Watching」复用它，nil = 没有下一集。
    private(set) var nextEpisode: MediaItem?
    private var nextEpisodeTask: Task<Void, Never>?
    private var externalSubtitleTask: Task<Void, Never>?

    private func startReporting(item: MediaItem, resumeSeconds: Double?) {
        reportingTask?.cancel()
        nextEpisode = nil
        guard let server else { return }
        let itemID = item.id
        let generation = sessionGeneration
        reportingItemID = itemID
        resolveNextEpisode(after: item, generation: generation)
        loadExternalSubtitles(for: item, generation: generation)
        reportingTask = Task { [weak self] in
            await server.reportPlaybackStart(itemID: itemID, positionSeconds: resumeSeconds ?? 0)
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000))
                guard let self, !Task.isCancelled else { return }
                guard self.sessionGeneration == generation,
                      self.reportingItemID == itemID else { return }
                ticks += 1
                guard let state = self.playback?.state else { return }

                let position = Double(state.position.microseconds) / 1_000_000
                let duration = Double(state.duration.microseconds) / 1_000_000

                // 播完 / 出错：补一条 Stopped；播完且有下一集 → 连播
                if state.state == .stopped || state.state == .error {
                    await server.reportPlaybackStopped(itemID: itemID, positionSeconds: position)
                    guard self.sessionGeneration == generation,
                          self.reportingItemID == itemID else { return }
                    // 已上报 Stopped，清掉 id，避免下面 play(next)→finishReporting() 再补一条重复的。
                    self.reportingItemID = nil
                    if state.state == .stopped, duration > 0,
                       position >= duration - 2, let next = self.nextEpisode {
                        self.play(next, resumeSeconds: 0)
                    }
                    return
                }

                // 心跳：每 10 秒一条（暂停也报，带 isPaused）
                if ticks % 10 == 0 {
                    await server.reportPlaybackProgress(
                        itemID: itemID, positionSeconds: position,
                        isPaused: state.state == .paused
                    )
                }
            }
        }
    }

    /// 换片 / 退出播放器：补 Stopped 后停表。返回 Stopped 上报任务（供调用方等待落库）。
    @discardableResult
    private func finishReporting() -> Task<Void, Never>? {
        reportingTask?.cancel()
        reportingTask = nil
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        nextEpisode = nil
        nowPlayingItem = nil
        defer { reportingItemID = nil }
        guard let itemID = reportingItemID, let server else { return nil }
        let position = playback.map { Double($0.state.position.microseconds) / 1_000_000 } ?? 0
        playerLog.info("上报 Stopped item=\(itemID) position=\(position)")
        return Task { await server.reportPlaybackStopped(itemID: itemID, positionSeconds: position) }
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
    private func loadExternalSubtitles(for item: MediaItem, generation: Int) {
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
                  self.reportingItemID == itemID else { return }
            for subtitle in subtitles {
                guard !Task.isCancelled else { return }
                guard let file = try? await server.downloadSubtitle(subtitle) else { continue }
                guard !Task.isCancelled,
                      self.sessionGeneration == generation,
                      self.reportingItemID == itemID else { return }
                self.playback?.addExternalSubtitle(fileURL: file)
            }
            self.playback?.autoSelectSubtitleIfNone()
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
