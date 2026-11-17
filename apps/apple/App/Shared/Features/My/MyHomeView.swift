import AppDesignKit
import BangumiKit
import CoreModel
import JellyfinKit
import MoviePilotKit
import SwiftUI

/// Personal overview. Remote collection and acquisition snapshots never become playback events.
struct MyHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true
    @State private var model: MyDashboardModel
    @State private var selectedWeekday = (Calendar.current.component(.weekday, from: Date()) + 5) % 7 + 1
    @State private var showDownloads = false
    @State private var showHistory = false
    private let isPreview: Bool

    // The optional model is a one-time seed for the offline, Debug-only layout preview.
    init(model: MyDashboardModel? = nil, isPreview: Bool = false) {
        #if OCPLAYER_SELFTEST
        let preview = isPreview || MyDashboardPreviewStage.isRequested
        _model = State(initialValue: model ?? (preview ? MyDashboardPreviewStage.makeModel() : MyDashboardModel()))
        self.isPreview = preview
        #else
        _model = State(initialValue: model ?? MyDashboardModel())
        self.isPreview = isPreview
        #endif
    }

    private var bangumiScope: String? {
        if isPreview { return "preview" }
        guard bangumiEnabled, bangumi.isAuthenticated, bangumi.isDatabaseReady else { return nil }
        return "bangumi:\(bangumi.profile?.id ?? 0):\(bangumi.profile?.username ?? "")"
    }
    private var calendarScope: String? {
        if isPreview { return "preview" }
        guard let bangumiScope, let historyScope, let overview else { return nil }
        let subjects = overview.broadcastWatching.map(\.id).sorted().map(String.init).joined(separator: ",")
        return "\(bangumiScope):\(historyScope):broadcast:\(subjects)"
    }
    private var moviepilotScope: String? {
        if isPreview { return "preview" }
        guard moviepilotEnabled, moviepilot.isAuthenticated else { return nil }
        return "moviepilot:\(moviepilot.store.configurationRevision):\(moviepilot.boundServerID ?? "")"
    }
    private var overview: MyBangumiOverview? { model.bangumi.snapshot(for: bangumiScope) }
    private var historyScope: String? {
        if isPreview { return "preview" }
        guard let server = app.server else { return nil }
        return "\(ServerViewingHistory.sourceID(for: server.profile)):\(app.sessionGeneration)"
    }
    private var history: ServerViewingHistory? { model.history.snapshot(for: historyScope) }
    private var localHistoryScope: String {
        "\(historyScope ?? "no-server"):\(app.sessionGeneration):local"
    }
    private var localHistory: [AppPlaybackRecord] { model.localHistory.snapshot(for: localHistoryScope) ?? [] }
    private var subscriptions: [MPSubscribe]? { model.subscriptions.snapshot(for: moviepilotScope) }
    private var downloads: [MPDownloadTask]? { model.downloads.snapshot(for: moviepilotScope) }
    private var collectionTiles: [MyViewingCollectionTile] {
        guard bangumiEnabled || isPreview else { return [] }
        func covers(_ subjects: [BangumiSubjectDTO]) -> [URL] {
            var seen = Set<URL>()
            return subjects.compactMap { bangumiCover($0.images) }.filter { seen.insert($0).inserted }
        }
        return [
            MyViewingCollectionTile(id: "wish", title: "待看", count: overview.map { $0.counts[.wish, default: 0] },
                                    covers: covers(overview?.wish ?? [])) {
                app.openBangumiCollectionList(.anime, collectionType: .wish)
            },
            MyViewingCollectionTile(id: "doing", title: "在看", count: overview.map { $0.counts[.doing, default: 0] },
                                    covers: covers(overview?.watching.map(\.subject) ?? []), action: app.openBangumiProgress)
        ]
    }
    private var calendarItems: [MyBroadcastOccurrence] {
        MyBroadcastTimeline.occurrences(model.calendar.snapshot(for: calendarScope) ?? [],
                                       weekday: selectedWeekday, now: Date())
    }
    private var isOverviewVisible: Bool {
        app.selectedSection == .my && !showDownloads && !showHistory
            && (app.isCompact ? app.navPath(for: .my).isEmpty : app.path.isEmpty)
    }
    private var downloadRefreshKey: String {
        "\(moviepilotScope ?? "none"):\(isOverviewVisible):\(scenePhase == .active)"
    }
    private var historyRefreshKey: String {
        "\(historyScope ?? "none"):\(isOverviewVisible):\(scenePhase == .active)"
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 0) {
                VStack(alignment: .leading, spacing: 26) {
                    profileHeader
                    if bangumiEnabled || isPreview { calendarSection }
                    viewingSection
                    bangumiStatus
                    overviewSection
                    if !app.home.resume.isEmpty { resumeSection }
                    if moviepilotEnabled || isPreview {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), alignment: .top)], alignment: .leading, spacing: 22) {
                            subscriptionsSection
                            downloadsSection
                        }
                    }
                }
                .padding(.horizontal, contentLeading)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(ViewingNavigation.pageTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if bangumiEnabled {
                        Button("Bangumi 章节管理", systemImage: "list.bullet.rectangle", action: app.openBangumiProgress)
                        Button("Bangumi 个人主页", systemImage: "person.crop.circle", action: app.openBangumiProfile)
                    }
                    if moviepilotEnabled {
                        Button("MoviePilot 资源管理", systemImage: "externaldrive") { app.openMoviePilot() }
                    }
                    Button("数据来源设置", systemImage: "gearshape") { app.switchSection(.settings) }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("观影页面操作")
                Button {
                    Task { await refreshAll() }
                } label: {
                    if model.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("刷新观影数据")
                .help("刷新观影数据")
                .disabled(model.isLoading || isPreview)
            }
        }
        .refreshable { await refreshAll() }
        .task(id: bangumiScope) { await loadBangumi(synchronize: true) }
        .task(id: calendarScope) { await loadCalendar() }
        .task(id: moviepilotScope) { await loadMoviePilot() }
        .task(id: historyScope) { await loadHistory() }
        .task(id: localHistoryScope) { await loadLocalHistory() }
        .task(id: historyRefreshKey) { await pollHistory() }
        .task(id: downloadRefreshKey) { await pollDownloads() }
        .onReceive(NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)) { _ in
            Task { await loadBangumi(synchronize: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bangumiLinkDidChange)) { _ in
            Task { await loadCalendar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppPlaybackHistoryStore.changed)) { _ in
            Task { await loadLocalHistory() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAll() } }
        }
        .onChange(of: isOverviewVisible) { _, visible in
            if visible { Task { await refreshAll() } }
        }
        .navigationDestination(isPresented: $showDownloads) {
            MoviePilotDownloadsView()
                .appShellBackChrome(title: "下载管理", presented: $showDownloads)
        }
        .navigationDestination(isPresented: $showHistory) {
            MyViewingHistoryList(history: history, localRecords: localHistory) { app.openDetail($0) }
                .appShellBackChrome(title: "观看记录", presented: $showHistory)
        }
        .coveredByPresented($showDownloads)
        .coveredByPresented($showHistory)
        #if OCPLAYER_SELFTEST
        .background {
            if isPreview {
                LinearGradient(colors: [Color(red: 0.24, green: 0.20, blue: 0.32), Color(red: 0.13, green: 0.20, blue: 0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
        }
        #endif
    }

    private var profileHeader: some View {
        let request = app.viewingAvatarRequest(bangumiEnabled: bangumiEnabled)
        let avatar = app.viewingProfileAvatar
        return HStack(spacing: 14) {
            ViewingProfileAvatarImage(image: isPreview ? nil : avatar.image,
                                      sourceName: request?.sourceName ?? "账号")
            VStack(alignment: .leading, spacing: 4) {
                Text(isPreview ? ViewingNavigation.pageTitle : (bangumiEnabled ? bangumi.profile?.name : nil) ?? ViewingNavigation.pageTitle)
                    .font(.title2.weight(.semibold))
                Text(isPreview ? "布局预览 · 示例数据" : app.server == nil ? "片单 · 追更 · 下载" : "\(app.serverLabel) · 片单与追更")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // Preserve layout while preparing; the complete header's first visible frame
        // already contains the selected, decoded avatar (no logo/default-face swap).
        .opacity(isPreview || avatar.isReady(for: request) ? 1 : 0)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!isPreview && !avatar.isReady(for: request))
    }

    @ViewBuilder
    private var viewingSection: some View {
        if historyScope != nil || !localHistory.isEmpty {
            MyViewingSection(
                history: history, localRecords: localHistory, collectionTiles: collectionTiles,
                isLoading: model.history.isLoading || model.localHistory.isLoading,
                error: model.localHistory.error ?? (model.history.scope == historyScope ? model.history.error : nil),
                sourceName: isPreview ? "Jellyfin · 示例数据" : app.server?.profile.kind.displayName ?? "本机播放",
                retry: { Task { await loadHistory() } },
                showAll: { app.pushPresented { showHistory = true } },
                openItem: { app.openDetail($0) }
            )
            .id(historyScope)
        } else {
            MyViewingCollectionTiles(tiles: collectionTiles).frame(maxWidth: 480, alignment: .leading)
            connectionCard("连接 Jellyfin 或 Emby，同步其他播放器产生的已看记录", button: "连接媒体库") {
                app.reconnectFlow()
            }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("番剧放送", detail: "完整日历", action: app.openBangumiCalendar)
            Text("在看 · 媒体库已有 · 按更新时间排序")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Button { selectedWeekday = day } label: {
                        Text(["一", "二", "三", "四", "五", "六", "日"][day - 1])
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(selectedWeekday == day ? Color.primary.opacity(0.14) : .clear,
                                        in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("周\(["一", "二", "三", "四", "五", "六", "日"][day - 1])")
                    .accessibilityAddTraits(selectedWeekday == day ? .isSelected : [])
                }
            }
            if let error = model.calendar.error, model.calendar.scope == calendarScope {
                sourceMessage(error, isError: true)
            }
            if !calendarItems.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(calendarItems) { occurrence in
                            Button { app.openBangumiSubject(id: occurrence.id) } label: {
                                MyPosterTile(title: occurrence.entry.subject.nameCN.isEmpty
                                             ? occurrence.entry.subject.name : occurrence.entry.subject.nameCN,
                                             image: bangumiCover(occurrence.entry.subject.images),
                                             subtitle: occurrence.subtitle(calendar: .current))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                sourceMessage(calendarEmptyMessage)
            }
            HStack(spacing: 5) {
                Text("预计放送时间 · 本地时区 ·")
                Link("bangumi-data", destination: URL(string: "https://github.com/bangumi-data/bangumi-data")!)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var calendarEmptyMessage: String {
        if isPreview { return "这一天没有符合条件的更新番剧" }
        if !bangumi.isAuthenticated { return "登录 Bangumi，显示在看且媒体库已有的更新番剧" }
        if app.server == nil { return "连接媒体库，筛选你已有的更新番剧" }
        if model.calendar.isLoading || model.bangumi.isLoading || !bangumi.isDatabaseReady {
            return "正在核对在看番剧和媒体库…"
        }
        return "这一天没有在看且媒体库已有的更新番剧"
    }

    private var overviewSection: some View {
        HStack(spacing: 16) {
            if bangumiEnabled || isPreview {
                Button { app.openBangumiCollectionList(.anime, collectionType: .collect) } label: {
                    MyCountCard(title: "看过动画", count: overview.map { $0.counts[.collect, default: 0] }, icon: "checkmark.circle", detail: "Bangumi")
                }.buttonStyle(.plain)
            }
            if moviepilotEnabled || isPreview {
                Button { app.openMoviePilot() } label: {
                    MyCountCard(title: "资源订阅", count: subscriptions?.count, icon: "antenna.radiowaves.left.and.right", detail: "MoviePilot")
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var bangumiStatus: some View {
        if bangumiEnabled, !isPreview {
            if bangumiScope == nil {
                HStack(spacing: 10) {
                    Text(bangumi.databaseError ?? "连接 Bangumi，同步你的片单与逐集进度")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("连接 Bangumi", action: app.openBangumiProgress).buttonStyle(.borderless)
                }.font(.footnote)
            } else if let error = model.bangumi.error, model.bangumi.scope == bangumiScope {
                sourceMessage(error, isError: true)
            }
        }
    }

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("继续观看", detail: "媒体库") { app.switchSection(.home) }
            VStack(spacing: 14) {
                ForEach(Array(app.home.resume.prefix(4))) { item in
                    Button { app.openDetail(item) } label: {
                        HStack(spacing: 12) {
                            MyViewingPoster(item: item)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.seriesName ?? item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                CardProgressTrack(fraction: item.playState?.percentage ?? 0)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .liquidGlassCard()
        }
    }

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("订阅追更", detail: "MoviePilot") { app.openMoviePilot() }
            if moviepilotScope == nil, !isPreview {
                connectionCard("连接 MoviePilot，查看资源订阅与缺集情况", button: "连接 MoviePilot") {
                    app.openMoviePilot()
                }
            } else {
                if let error = model.subscriptions.error, model.subscriptions.scope == moviepilotScope {
                    sourceMessage(error, isError: true)
                }
                if let items = subscriptions, !items.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("\(items.count) 部订阅", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            Text(items.contains { $0.lackEpisode != nil }
                                 ? "已知缺 \(MyResourceLink.missingEpisodes(in: items)) 集" : "集数待确认")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        ForEach(Array(items.prefix(4))) { item in
                            Button { app.openMoviePilotSearch(item.name ?? "") } label: {
                                MySubscriptionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                    .liquidGlassCard()
                } else {
                    sourceMessage(model.subscriptions.isLoading ? "正在加载订阅…" : "暂无资源订阅")
                }
            }
        }
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("下载任务", detail: "MoviePilot") {
                app.pushPresented { showDownloads = true }
            }
            if let error = model.downloads.error, model.downloads.scope == moviepilotScope {
                sourceMessage(error, isError: true)
            }
            if let tasks = downloads, !tasks.isEmpty {
                VStack(spacing: 18) {
                    ForEach(Array(tasks.prefix(3))) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(task.mediaTitle ?? task.title ?? task.name ?? "下载任务")
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(task.progressFraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            CardProgressTrack(fraction: task.progressFraction)
                            Text([task.state, task.dlspeed, task.leftTime].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(18)
                .liquidGlassCard()
            } else if moviepilotScope != nil {
                sourceMessage(model.downloads.isLoading ? "正在加载下载任务…" : "当前没有下载任务")
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func sourceMessage(_ text: String, isError: Bool = false) -> some View {
        HStack(spacing: 10) {
            if isError { Image(systemName: "exclamationmark.circle") }
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isError {
                Button("重试") { Task { await refreshAll() } }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 10)
    }

    private func connectionCard(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Button(button, action: action).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .liquidGlassCard()
    }

    private func loadBangumi(synchronize: Bool) async {
        guard !isPreview else { return }
        let scope = bangumiScope
        await model.bangumi.load(scope: scope, currentScope: { bangumiScope }) {
            try await MyBangumiOverview.read(from: bangumi.context)
        }
        guard synchronize, scope != nil, !Task.isCancelled else { return }
        bangumi.revalidateSessionIfNeeded()
        await model.bangumi.load(scope: scope, currentScope: { bangumiScope }) {
            _ = try await bangumi.refreshCollections()
            return try await MyBangumiOverview.read(from: bangumi.context)
        }
    }

    private func loadCalendar() async {
        guard !isPreview else { return }
        let scope = calendarScope
        guard let server = app.server, let watching = overview?.broadcastWatching else {
            model.calendar.reset()
            return
        }
        await model.calendar.load(scope: calendarScope, currentScope: { calendarScope }) {
            guard !watching.isEmpty else { return [] }
            async let days = BangumiCalendarService.getCalendar()
            async let media = server.items(parentID: nil, kinds: [.series, .season], recursive: true, limit: 200)
            async let timing = try? MyBroadcastDataStore.shared.load()
            let (calendar, library, records) = try await (days, media, timing)
            try Task.checkCancellation()
            guard calendarScope == scope else { throw CancellationError() }
            let links = Dictionary(library.compactMap { item in
                BangumiMatcher.linkedSubjectID(forJellyfinItemID: item.id).map { (item.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
            return MyBroadcastTimeline.build(watching: watching, calendar: calendar, records: records ?? [],
                                             library: library, links: links, now: Date())
        }
    }

    private func loadMoviePilot() async {
        guard !isPreview else { return }
        async let subscriptions: Void = model.subscriptions.load(scope: moviepilotScope, currentScope: { moviepilotScope }) {
            try await MoviePilotAPIClient.shared.subscribes()
        }
        async let downloads: Void = model.downloads.load(scope: moviepilotScope, currentScope: { moviepilotScope }) {
            try await MoviePilotAPIClient.shared.downloadingTasks()
        }
        _ = await (subscriptions, downloads)
    }

    private func refreshAll() async {
        guard !isPreview else { return }
        async let bgm: Void = loadBangumi(synchronize: true)
        async let calendar: Void = loadCalendar()
        async let mp: Void = loadMoviePilot()
        async let viewing: Void = loadHistory()
        _ = await (bgm, calendar, mp, viewing)
    }

    private func loadHistory() async {
        guard !isPreview else { return }
        await loadLocalHistory()
        let scope = historyScope
        guard let server = app.server else { model.history.reset(); return }
        let sourceID = ServerViewingHistory.sourceID(for: server.profile)
        if model.history.snapshot(for: scope) == nil {
            await model.history.load(scope: scope, currentScope: { historyScope }) {
                try await ServerViewingHistoryStore.shared.read(sourceID: sourceID)
            }
        }
        await model.history.load(scope: scope, currentScope: { historyScope }) {
            try await ServerViewingHistoryStore.shared.synchronize(server: server)
        }
    }

    private func loadLocalHistory() async {
        guard !isPreview else { return }
        let scope = localHistoryScope
        let sourceID = app.server.map { ServerViewingHistory.sourceID(for: $0.profile) }
        await model.localHistory.load(scope: scope, currentScope: { localHistoryScope }) {
            var records = try await AppPlaybackHistoryStore.shared.read(sourceID: AppPlaybackHistoryStore.localSourceID)
            if let sourceID { records += try await AppPlaybackHistoryStore.shared.read(sourceID: sourceID) }
            return records
        }
    }

    private func pollHistory() async {
        guard !isPreview, isOverviewVisible, scenePhase == .active, historyScope != nil else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            await loadHistory()
        }
    }

    /// Refresh task progress only while the overview is visible and the app is active.
    private func pollDownloads() async {
        guard !isPreview, isOverviewVisible, scenePhase == .active, let scope = moviepilotScope else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await model.downloads.load(scope: scope, currentScope: { moviepilotScope }) {
                try await MoviePilotAPIClient.shared.downloadingTasks()
            }
        }
    }
}

private func bangumiCover(_ images: BangumiSubjectImages?) -> URL? {
    guard let image = images?.large, !image.isEmpty else { return nil }
    return URL(string: BangumiURL.imageURLString(from: image))
}

private struct MyCountCard: View {
    let title: String
    let count: Int?
    let icon: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(count.map(String.init) ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .liquidGlassCard(isInteractive: true)
        .accessibilityElement(children: .combine)
    }
}

private struct MyPosterTile: View {
    let title: String
    let image: URL?
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaArtwork(url: image, shape: .poster, width: 88, cornerRadius: 10, nominalRatio: 2.0 / 3.0)
            Text(title).font(.caption.weight(.medium)).lineLimit(2)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 88, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MySubscriptionRow: View {
    let item: MPSubscribe
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MediaArtwork(url: item.posterURL, shape: .poster, width: 48, cornerRadius: 8, nominalRatio: 2.0 / 3.0)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.name ?? "未命名订阅").font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([item.seasonText, item.stateText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let progress = item.progressText {
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
