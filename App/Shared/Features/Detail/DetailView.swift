import CoreModel
import JellyfinKit
import SwiftUI

extension Color {
    /// 页面底色（macOS 窗口底 / iOS 系统底），横幅渐隐要融进它。
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// 详情页：背景横幅 + 元数据 + 播放键 + 简介 + 演员 + 类似推荐；
/// 剧集额外有季选择器和横向选集（点选中，顶部主按钮开播）。
struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 列表页带来的初版数据（立即可渲染），网络刷新后覆盖。
    let item: MediaItem

    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var episodes: [MediaItem] = []
    /// 本次停留在这一页期间已经拉过的季 → 集列表。来回切季不再重新请求、
    /// 也不再闪一下 loading。`load()`（换条目）时整体清空。
    @State private var episodesBySeason: [String: [MediaItem]] = [:]
    /// 每季各自记住用户选中的那一集：切走再切回来选中项还在。
    @State private var selectedEpisodeBySeason: [String: MediaItem.ID] = [:]
    @State private var similar: [MediaItem] = []
    @State private var selectedSeasonID: String?
    @State private var selectedEpisodeID: MediaItem.ID?
    /// 横向选集箭头滚动的锚点（可与选中集不同：只滚列表不改选中）。
    @State private var episodeScrollFocusID: MediaItem.ID?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isLoadingEpisodes = false
    @State private var episodeLoadError: String?
    @State private var isUpdatingPlayed = false
    @State private var playedActionError: String?

    private var shown: MediaItem { detail ?? item }

    var body: some View {
        Group {
            if isLoading && detail == nil {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        banner
                        metadata
                        if let loadError {
                            loadErrorNotice(loadError)
                        }
                        if let playedActionError {
                            loadErrorNotice(playedActionError)
                        }
                        if shown.kind == .series {
                            seasonBar
                            episodeList
                        }
                        if !shown.cast.isEmpty { castRail }
                        if !similar.isEmpty { similarRail }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationTitle(shown.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(Color.pageBackground.ignoresSafeArea())
        .task(id: item.id) { await load() }
    }

    // MARK: - 顶部横幅

    private var banner: some View {
        ZStack {
            // 背景层：有图铺图、没图铺灰块，占满横幅。
            let target = shown.imageTarget(app.server, kind: .backdrop, width: 1600)
            Group {
                if let url = target.url {
                    RemoteImage(url: url, authHeader: target.authHeader)
                } else {
                    Rectangle().fill(.quinary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部渐变：把背景图底部压暗，保证白字可读。
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.3), .clear],
                           startPoint: .bottom, endPoint: .top)
        }
        .frame(height: 320)
        // Overlay against the already-sized banner. A bottom-aligned HStack inside
        // the ZStack can use its intrinsic height and fall below the banner, where
        // `.clipped()` cuts off the poster and controls.
        .overlay(alignment: .bottomLeading) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 24) {
                    bannerPoster(width: 120, height: 180)
                    VStack(alignment: .leading, spacing: 8) {
                        bannerTitle
                        metaRow
                        playbackActions
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom, spacing: 14) {
                        bannerPoster(width: 80, height: 120)
                        VStack(alignment: .leading, spacing: 8) {
                            bannerTitle
                            metaRow
                                .lineLimit(1)
                        }
                    }
                    playbackActions
                }
            }
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.bottom, 28)
        }
        .clipped()
    }

    @ViewBuilder
    private func bannerPoster(width: CGFloat, height: CGFloat) -> some View {
        if shown.primaryImageTag != nil {
            let poster = shown.imageTarget(app.server, kind: .primary, width: 300)
            RemoteImage(url: poster.url, authHeader: poster.authHeader)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
    }

    private var bannerTitle: some View {
        Text(shown.name)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }

    private var metaRow: some View {
        HStack(spacing: 9) {
            ForEach(metaParts, id: \.self) { part in
                if part != metaParts.first {
                    Text("·").foregroundStyle(.white.opacity(0.4))
                }
                Text(part).foregroundStyle(.white.opacity(0.85))
            }
            if let rating = shown.communityRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if let official = shown.officialRating {
                Text(official)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.subheadline)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = shown.year { parts.append(String(year)) }
        if !shown.genres.isEmpty { parts.append(shown.genres.prefix(3).joined(separator: " / ")) }
        if let runtime = shown.runtimeSeconds { parts.append(RuntimeText.format(runtime)) }
        if shown.kind == .series, let count = shown.childCount {
            parts.append("\(count) 季")
        }
        return parts
    }

    /// 主播放胶囊 + 同高仅图标的「已看过」钮，共用 bannerActionHeight。
    private var playbackActions: some View {
        HStack(alignment: .center, spacing: 10) {
            playButton
            if canTogglePlayed {
                markPlayedButton
            }
        }
        // 固定行高，避免图标/字体 metrics 把一侧撑高。
        .frame(height: Self.bannerActionHeight, alignment: .center)
    }

    private static let bannerActionHeight: CGFloat = 40

    private var playButton: some View {
        Button(action: playCurrent) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(resumeProgress == nil ? 0.78 : 0.34))
                if let progress = resumeProgress {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(.white.opacity(0.82))
                            .frame(width: proxy.size.width * progress)
                    }
                }

                Text(playButtonLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.black.opacity(0.8))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 228, height: Self.bannerActionHeight)
            // Only the outer capsule is rounded. The progress rectangle keeps
            // a full-height vertical boundary like the native resume control.
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .modifier(DetailPlayButtonStyle())
        .disabled(!canPlayCurrent)
        .opacity(canPlayCurrent ? 1 : 0.55)
        .accessibilityLabel(resumePlayState == nil ? playButtonLabel : "继续播放")
        .accessibilityValue(resumePlayState.map { "本集已播放 \(resumeClock($0.positionSeconds))" } ?? "")
    }

    /// 与播放钮同高的圆形次要操作：只放勾选图标，无文案。
    private var markPlayedButton: some View {
        let played = isPlayableMarkedPlayed
        return Button {
            Task { await togglePlayed() }
        } label: {
            ZStack {
                // 与主按钮同一套白底体系：未看半透明、已看实心，高度严格 40×40。
                Capsule()
                    .fill(.white.opacity(played ? 0.78 : 0.34))
                if isUpdatingPlayed {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black.opacity(0.75))
                } else {
                    Image(systemName: played ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.black.opacity(0.8))
                        .symbolEffect(.bounce, value: played)
                }
            }
            .frame(width: Self.bannerActionHeight, height: Self.bannerActionHeight)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(DetailPlayButtonStyle())
        .disabled(isUpdatingPlayed || playableItem == nil)
        .opacity(isUpdatingPlayed ? 0.85 : 1)
        .help(played ? "标为未看" : "已看过")
        .accessibilityLabel(played ? "标为未看" : "已看过")
        .accessibilityValue(played ? "当前为已看完" : "当前为未看完")
        .accessibilityHint(played ? "轻点后恢复为未看" : "轻点后标记为已看完")
    }

    private var playButtonLabel: String {
        if let playState = resumePlayState {
            return "继续 \(resumeClock(playState.positionSeconds))"
        }
        return "播放"
    }

    private func resumeClock(_ seconds: Double) -> String {
        let elapsed = max(Int(seconds), 0)
        return String(
            format: "%02d:%02d:%02d",
            elapsed / 3_600,
            (elapsed % 3_600) / 60,
            elapsed % 60
        )
    }

    /// 电影直接播自身；剧集只播当前横向选集中的选中集。
    private var playableItem: MediaItem? {
        switch shown.kind {
        case .series:
            return selectedEpisode
        default:
            return shown
        }
    }

    private var selectedEpisode: MediaItem? {
        guard let selectedEpisodeID else { return nil }
        return episodes.first { $0.id == selectedEpisodeID }
    }

    private var resumePlayState: MediaItem.PlayState? {
        guard let state = playableItem?.playState,
              !state.played,
              state.positionSeconds >= 30
        else { return nil }
        return state
    }

    private var resumeProgress: Double? {
        guard let state = resumePlayState else { return nil }
        if state.percentage > 0 {
            return min(max(state.percentage, 0), 1)
        }
        guard let runtime = playableItem?.runtimeSeconds, runtime > 0 else { return nil }
        return min(max(state.positionSeconds / runtime, 0), 1)
    }

    private var canPlayCurrent: Bool {
        playableItem != nil
    }

    private var canTogglePlayed: Bool {
        guard let item = playableItem else { return false }
        switch item.kind {
        case .movie, .episode:
            return true
        default:
            return false
        }
    }

    private var isPlayableMarkedPlayed: Bool {
        playableItem?.playState?.played == true
    }

    // MARK: - 简介与元信息

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let overview = shown.overview, !overview.isEmpty {
                Text(overview)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 20)
    }

    // MARK: - 剧集：季 + 横向选集

    private var seasonBar: some View {
        HStack(spacing: 14) {
            Text("剧集").font(.title3.weight(.bold))
            Spacer()
            if seasons.count > 1, let selection = Binding($selectedSeasonID) {
                Picker("季", selection: selection) {
                    ForEach(seasons) { season in
                        Text(season.name).tag(Optional(season.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .task(id: selectedSeasonID) { await loadEpisodes() }
    }

    private var episodeList: some View {
        Group {
            if isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
                .padding(.horizontal, Metrics.contentLeading)
                .transition(.opacity)
            } else if let episodeLoadError {
                ContentUnavailableView {
                    Label("集列表加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(episodeLoadError)
                } actions: {
                    Button("重试") { Task { await loadEpisodes() } }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, Metrics.contentLeading)
                .transition(.opacity)
            } else if episodes.isEmpty {
                ContentUnavailableView("本季暂无剧集", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, Metrics.contentLeading)
                    .transition(.opacity)
            } else {
                episodePickerRail
                    .transition(.opacity)
            }
        }
        // 切季时旧选集淡出 → loading 淡入 → 新选集淡入，不再三处硬切。
        // 两个 value 都绑：loading 翻转和集列表整体替换（count 变化）各自开一次事务。
        .animation(episodeListMotion, value: isLoadingEpisodes)
        .animation(episodeListMotion, value: episodes.count)
    }

    /// 选集区域的状态切换过渡；减弱动态效果时直接切换。
    private var episodeListMotion: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    /// 横向选集 + 两侧悬浮箭头（鼠标靠近才显示；VoiceOver 下常显）。
    private var episodePickerRail: some View {
        HoverArrowHScroll(
            items: episodes,
            scrollStep: 4,
            contentLeading: Metrics.contentLeading,
            edgeReserve: 28,
            verticalPadding: 10,
            // 箭头对准剧照中部（卡片上部），不是整卡含标题的几何中心。
            arrowYOffset: -18,
            scrollToID: selectedEpisodeID
        ) { episode in
            EpisodeSelectCard(
                episode: episode,
                server: app.server,
                isSelected: episode.id == selectedEpisodeID
            ) {
                selectedEpisodeID = episode.id
                episodeScrollFocusID = episode.id
                if let seasonID = selectedSeasonID {
                    selectedEpisodeBySeason[seasonID] = episode.id
                }
            }
        }
    }

    // MARK: - 演员 / 类似

    private var castRail: some View {
        let actors = Array(shown.cast.filter { $0.kind == "Actor" }.prefix(20))
        return Rail("演员", kind: .flexible, items: actors) { person in
            VStack(spacing: 8) {
                let target = personImageTarget(person)
                RemoteImage(url: target.url, authHeader: target.authHeader)
                    .aspectRatio(1, contentMode: .fill)
                    // 宽高都要定死：RemoteImage 内部占位 Rectangle 会竖向贪婪撑开，
                    // 只给宽度时头像被裁进一条很高的空白里，名字/角色被挤出可视区。
                    .frame(width: 108, height: 108)
                    .clipShape(Circle())
                Text(person.name).font(.footnote).lineLimit(1).frame(width: 108)
                if let role = person.role, !role.isEmpty {
                    Text(role).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).frame(width: 108)
                }
            }
        }
    }

    private var similarRail: some View {
        Rail("类似推荐", kind: .poster, items: similar) { item in
            PosterCard(item: item, server: app.server) {
                app.openDetail(item)
            }
        }
    }

    private func personImageTarget(_ person: MediaItem.Person) -> (url: URL?, authHeader: String?) {
        guard let server = app.server,
              let url = try? server.imageURL(itemID: person.id, type: .primary, maxWidth: 240)
        else { return (nil, nil) }
        return (url, server.authorizationHeader)
    }

    // MARK: - 动作

    /// 电影直接播；剧集只播横向选集中的当前选中集。
    private func playCurrent() {
        guard let playableItem else { return }
        let resume: Double?
        if let state = playableItem.playState,
           !state.played,
           state.positionSeconds >= 30 {
            resume = state.positionSeconds
        } else {
            resume = nil
        }
        app.play(playableItem, resumeSeconds: resume)
    }

    /// 切换当前可播条目（电影 / 选中集）的已看状态，并写回本地详情与选集列表。
    private func togglePlayed() async {
        guard !isUpdatingPlayed,
              let target = playableItem,
              let server = app.server
        else { return }
        let markAsPlayed = !(target.playState?.played ?? false)
        isUpdatingPlayed = true
        playedActionError = nil
        defer { isUpdatingPlayed = false }
        do {
            let state = markAsPlayed
                ? try await server.markPlayed(itemID: target.id)
                : try await server.markUnplayed(itemID: target.id)
            applyPlayState(state, toItemID: target.id)
        } catch let error as JellyfinError {
            playedActionError = error.errorDescription
        } catch {
            playedActionError = "\(error)"
        }
    }

    private func applyPlayState(_ state: MediaItem.PlayState, toItemID id: MediaItem.ID) {
        if var current = detail, current.id == id {
            current.playState = state
            detail = current
        }
        if let index = episodes.firstIndex(where: { $0.id == id }) {
            episodes[index].playState = state
        }
        // 缓存也要跟着改，否则切走再切回来「已看过」的勾又变回去了。
        for (seasonID, cached) in episodesBySeason {
            guard let index = cached.firstIndex(where: { $0.id == id }) else { continue }
            episodesBySeason[seasonID]?[index].playState = state
        }
    }

    private func load() async {
        guard let server = app.server else { return }
        isLoading = true
        loadError = nil
        detail = nil
        seasons = []
        episodes = []
        episodesBySeason = [:]
        selectedEpisodeBySeason = [:]
        selectedSeasonID = nil
        selectedEpisodeID = nil
        episodeScrollFocusID = nil
        episodeLoadError = nil

        // Similar recommendations are optional and may be unavailable on
        // servers with that endpoint disabled. Keep the required detail path
        // independent so a recommendation failure cannot blank the page.
        async let similarItems = server.similar(itemID: item.id)
        do {
            let loadedDetail = try await server.item(item.id)
            guard !Task.isCancelled else { return }
            detail = loadedDetail

            if loadedDetail.kind == .series {
                do {
                    let loadedSeasons = try await server.seasons(seriesID: item.id)
                    guard !Task.isCancelled else { return }
                    seasons = loadedSeasons
                    selectedSeasonID = preferredSeasonID(in: loadedSeasons, seriesID: loadedDetail.id)
                } catch let e as JellyfinError {
                    loadError = e.errorDescription
                } catch {
                    loadError = "\(error)"
                }
            }
        } catch let e as JellyfinError {
            loadError = e.errorDescription
        } catch {
            loadError = "\(error)"
        }
        isLoading = false
        similar = (try? await similarItems) ?? []
    }

    private func loadEpisodes() async {
        guard let server = app.server, shown.kind == .series, let seasonID = selectedSeasonID else {
            episodes = []
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        // 这一季已经拉过：同步换上，不清空、不转圈、不发请求。
        if let cached = episodesBySeason[seasonID] {
            episodes = cached
            let restored = selectedEpisodeBySeason[seasonID]
                .flatMap { id in cached.contains { $0.id == id } ? id : nil }
                ?? preferredEpisodeID(in: cached, seriesID: shown.id)
            selectedEpisodeID = restored
            episodeScrollFocusID = restored
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        episodes = []
        selectedEpisodeID = nil
        episodeScrollFocusID = nil
        isLoadingEpisodes = true
        episodeLoadError = nil
        defer {
            if selectedSeasonID == seasonID {
                isLoadingEpisodes = false
            }
        }
        do {
            let loaded = try await server.episodes(seriesID: shown.id, seasonID: seasonID)
            guard !Task.isCancelled, selectedSeasonID == seasonID else { return }
            episodesBySeason[seasonID] = loaded
            episodes = loaded
            let preferred = preferredEpisodeID(in: loaded, seriesID: shown.id)
            selectedEpisodeID = preferred
            episodeScrollFocusID = preferred
        } catch let e as JellyfinError {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = e.errorDescription
        } catch {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = "\(error)"
        }
    }

    // MARK: - 智能默认季 / 集

    /// 首页续播 / 下一集线索：用于默认季与默认选中集。
    private func preferredEpisodeHint(seriesID: MediaItem.ID) -> MediaItem? {
        if let resume = app.home.resume.first(where: {
            $0.seriesID == seriesID
                && !($0.playState?.played ?? false)
                && ($0.playState?.positionSeconds ?? 0) >= 30
        }) {
            return resume
        }
        return app.home.nextUp.first(where: { $0.seriesID == seriesID })
    }

    /// 默认季：有续播/下一集进度的季优先；否则第一部有未看完的常规季（跳过 SP/特典）；
    /// 再否则第一部常规季；最后才落到任意季（含仅有 SP 的片）。
    private func preferredSeasonID(in seasons: [MediaItem], seriesID: MediaItem.ID) -> String? {
        guard !seasons.isEmpty else { return nil }

        if let hint = preferredEpisodeHint(seriesID: seriesID) {
            if let sn = hint.seasonNumber,
               let byNumber = seasons.first(where: { $0.seasonNumber == sn }) {
                return byNumber.id
            }
        }

        let regular = seasons.filter { !isSpecialsSeason($0) }
        let pool = regular.isEmpty ? seasons : regular

        if let unwatched = pool.first(where: { ($0.playState?.unplayedCount ?? 0) > 0 }) {
            return unwatched.id
        }
        return pool.first?.id ?? seasons.first?.id
    }

    /// 特典/SP 季：季号 0，或名称像 Specials / 特别篇 / SP（避免默认一进详情就停在 SP）。
    private func isSpecialsSeason(_ season: MediaItem) -> Bool {
        if let number = season.seasonNumber, number == 0 { return true }
        let name = season.name.lowercased()
        if name.contains("special") { return true }
        if name.contains("特别") || name.contains("特典") || name.contains("番外") { return true }
        let compact = name.filter { !$0.isWhitespace }
        if compact == "sp" || compact.hasPrefix("sp") && compact.count <= 4 { return true }
        return false
    }

    /// 当前季列表内的默认选中集：续播 → nextUp → 第一集未看完 → 第一集。
    private func preferredEpisodeID(in episodes: [MediaItem], seriesID: MediaItem.ID) -> MediaItem.ID? {
        guard !episodes.isEmpty else { return nil }

        if let hint = preferredEpisodeHint(seriesID: seriesID),
           episodes.contains(where: { $0.id == hint.id }) {
            return hint.id
        }

        return episodes.first(where: { !($0.playState?.played ?? false) })?.id
            ?? episodes.first?.id
    }

    private func loadErrorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 14)
    }
}
