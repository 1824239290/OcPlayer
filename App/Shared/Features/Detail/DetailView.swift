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
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

    /// 紧凑宽度（iPhone）横幅矮一点，留出更多正文空间。
    private var bannerHeight: CGFloat {
        horizontalSizeClass == .compact ? 260 : Metrics.bannerHeight
    }

    /// 紧凑宽度的播放钮窄一点，和海报/标题一起塞进窄屏不溢出。
    private var playButtonWidth: CGFloat {
        horizontalSizeClass == .compact ? 200 : 228
    }

    /// 详情页屏幕边缘留白：紧凑宽度下为 20pt，保持全页对齐；iPad/Mac 沿用 contentLeading。
    private var detailHorizontalInset: CGFloat {
        horizontalSizeClass == .compact ? 20 : contentLeading
    }

    var body: some View {
        Group {
            if isLoading && detail == nil {
                skeleton
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if horizontalSizeClass == .compact {
                            compactHeaderView
                        } else {
                            banner
                            metadata
                        }
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
                        BangumiChapterSection(
                            item: shown,
                            selectedSeason: seasons.first(where: { $0.id == selectedSeasonID })
                        )
                        MoviePilotResourceSection(item: shown)
                        if !shown.cast.isEmpty { castRail }
                        if !similar.isEmpty { similarRail }
                    }
                    .padding(.bottom, 48)
                }
                #if os(iOS)
                .ignoresSafeArea(edges: .top)
                #endif
            }
        }
        .navigationTitle(horizontalSizeClass == .compact ? "" : shown.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sensoryFeedback(.impact, trigger: isPlayableMarkedPlayed)
        .sensoryFeedback(.selection, trigger: selectedEpisodeID)
        #endif
        .background(Color.pageBackground.ignoresSafeArea())
        .task(id: item.id) { await load() }
        .onChange(of: app.detailRefreshGeneration) { _, _ in
            Task { await reloadAfterPlayback() }
        }
    }

    /// 详情页骨架：**和真实内容同结构**——banner（含左下海报 + 标题/元数据/播放钮）
    /// → metadata 区 →（仅剧集）季选择行 + 选集占位。数据加载完原位替换。
    private var skeleton: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact {
                skeletonCompactHero
                skeletonCompactInfo
            } else {
                skeletonBanner
                skeletonMetadata
            }
            if shown.kind == .series {
                skeletonSeasonBar
                SkeletonEpisodeStrip()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .skeletonShimmer()
    }

    private var skeletonCompactHero: some View {
        ZStack(alignment: .bottom) {
            SkeletonBlock(cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SkeletonBlock(cornerRadius: 6)
                .frame(width: 220, height: 36)
                .padding(.bottom, 16)
        }
        .frame(height: 290)
        .clipped()
    }

    private var skeletonCompactInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SkeletonBlock(cornerRadius: 12).frame(width: 54, height: 24)
                SkeletonBlock(cornerRadius: 4).frame(width: 44, height: 22)
                SkeletonBlock(cornerRadius: 4).frame(width: 140, height: 16)
            }
            HStack(spacing: 12) {
                SkeletonBlock(cornerRadius: 24)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                SkeletonBlock(cornerRadius: 24)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(cornerRadius: 4).frame(maxWidth: .infinity).frame(height: 14)
                SkeletonBlock(cornerRadius: 4).frame(width: 260, height: 14)
            }
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 16)
    }

    /// 横幅：和 `banner` 同高，左下是海报位 + 标题/元数据/按钮条。
    private var skeletonBanner: some View {
        ZStack(alignment: .bottomLeading) {
            SkeletonBlock(cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .bottom, spacing: 24) {
                SkeletonBlock()
                    .frame(width: 120, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 220, height: 26)
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 140, height: 14)
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 90, height: 14)
                    SkeletonBlock(cornerRadius: Metrics.bannerActionHeight / 2)
                        .frame(width: playButtonWidth, height: Metrics.bannerActionHeight)
                }
            }
            .padding(.horizontal, detailHorizontalInset)
            .padding(.bottom, 28)
        }
        .frame(height: bannerHeight)
        .clipped()
    }

    /// 简介区：和真实 `metadata` 同 padding（top 20）。
    private var skeletonMetadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(cornerRadius: 4).frame(width: 420, height: 14)
            SkeletonBlock(cornerRadius: 4).frame(width: 340, height: 14)
            SkeletonBlock(cornerRadius: 4).frame(width: 380, height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 20)
    }

    /// 「剧集 + 季选择器」行：和真实 `seasonBar` 同 padding（top 26 + bottom 12）。
    private var skeletonSeasonBar: some View {
        HStack {
            SkeletonBlock(cornerRadius: 4).frame(width: 60, height: 20)
            Spacer()
            SkeletonBlock(cornerRadius: 6).frame(width: 110, height: 26)
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    // MARK: - 移动端（紧凑端）沉浸式头部与内容区

    private var compactHeaderView: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactHeroBanner
            compactContentStack
        }
    }

    private var compactHeroBanner: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let target = shown.imageTarget(app.server, kind: .backdrop, width: 1600)
                if let url = target.url {
                    RemoteImage(url: url, authHeader: target.authHeader, maxPixelSize: 1000)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Rectangle().fill(Color.primary.opacity(0.06))
                }
            }

            // 底部平滑渐隐到页面底色
            LinearGradient(
                colors: [.clear, Color.pageBackground.opacity(0.35), Color.pageBackground],
                startPoint: .top,
                endPoint: .bottom
            )

            // 居中/醒目的标题 Logo
            compactBannerTitle
                .padding(.horizontal, detailHorizontalInset)
                .padding(.bottom, 8)
        }
        .frame(height: 290)
        .clipped()
    }

    private var compactContentStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            compactMetaRow
            compactActionSection
            if let overview = shown.overview, !overview.isEmpty {
                ExpandableOverview(text: overview)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 14)
    }

    private var compactMetaRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let rating = shown.communityRating {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(String(format: "%.1f", rating))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(BangumiStatusColor.rating)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(BangumiStatusColor.rating.opacity(0.14), in: Capsule())
                }

                if let official = shown.officialRating {
                    Text(official)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                        )
                }

                if let year = shown.year {
                    Text(String(year))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if shown.kind == .series, let count = shown.childCount {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(count) 季")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if let runtime = shown.runtimeSeconds {
                    Text("·").foregroundStyle(.tertiary)
                    Text(RuntimeText.format(runtime))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !shown.genres.isEmpty {
                Text(shown.genres.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var compactActionSection: some View {
        HStack(spacing: 12) {
            compactPlayButton
            if canTogglePlayed {
                compactMarkPlayedButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var compactPlayButton: some View {
        Button(action: playCurrent) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor)

                if let progress = resumeProgress {
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .scaleEffect(x: progress, y: 1, anchor: .leading)
                }

                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(compactPlayButtonTitle)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: 48)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canPlayCurrent)
        .opacity(canPlayCurrent ? 1 : 0.55)
        .accessibilityLabel(compactPlayButtonTitle)
        .accessibilityValue(resumePlayState.map { "已播放 \(resumeClock($0.positionSeconds))" } ?? "")
    }

    private var compactPlayButtonTitle: String {
        if let playState = resumePlayState {
            if let label = playableItem?.episodeLabel {
                return "继续播放 \(label) · \(resumeClock(playState.positionSeconds))"
            }
            return "继续播放 · \(resumeClock(playState.positionSeconds))"
        }
        if shown.kind == .series {
            if let label = playableItem?.episodeLabel {
                return "播放 \(label)"
            }
            return "播放第一集"
        }
        return "立即播放"
    }

    private var compactMarkPlayedButton: some View {
        let played = isPlayableMarkedPlayed
        return Button {
            Task { await togglePlayed() }
        } label: {
            ZStack {
                Circle()
                    .fill(played ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06)))
                if isUpdatingPlayed {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: played ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(played ? Color.accentColor : Color.primary.opacity(0.65))
                        .symbolEffect(.bounce, value: played)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(played ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isUpdatingPlayed || playableItem == nil)
        .opacity(isUpdatingPlayed ? 0.85 : 1)
        .help(played ? "标为未看" : "已看过")
        .accessibilityLabel(played ? "标为未看" : "已看过")
        .accessibilityValue(played ? "当前为已看完" : "当前为未看完")
    }

    // MARK: - 桌面端顶部横幅（macOS / iPad 宽屏）

    private var banner: some View {
        ZStack {
            // 背景层：有图铺图、没图铺灰块，占满横幅。
            let target = shown.imageTarget(app.server, kind: .backdrop, width: 1600)
            Group {
                if let url = target.url {
                    RemoteImage(url: url, authHeader: target.authHeader, maxPixelSize: 1000)
                } else {
                    Rectangle().fill(.quinary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部渐变：把背景图底部压暗，保证白字可读。
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.3), .clear],
                           startPoint: .bottom, endPoint: .top)
        }
        .frame(height: bannerHeight)
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 24) {
                bannerPoster(width: 120, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    bannerTitle
                    metaRow
                    playbackActions
                }
            }
            .padding(.horizontal, detailHorizontalInset)
            .padding(.bottom, 28)
        }
        .clipped()
    }

    @ViewBuilder
    private func bannerPoster(width: CGFloat, height: CGFloat) -> some View {
        if shown.primaryImageTag != nil {
            let poster = shown.imageTarget(app.server, kind: .primary, width: 300)
            RemoteImage(url: poster.url, authHeader: poster.authHeader, maxPixelSize: 300)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
    }

    private var bannerTitle: some View {
        ItemTitleLogoView(item: shown, server: app.server, maxHeight: 80, maxWidth: 420, fontSize: 28)
    }

    private var compactBannerTitle: some View {
        // 紧凑宽度：艺术字 Logo 或居中文本标题
        ItemTitleLogoView(item: shown, server: app.server, maxHeight: 68, maxWidth: 320, fontSize: 24, centered: true)
            .frame(maxWidth: .infinity, alignment: .center)
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
                    .foregroundStyle(BangumiStatusColor.rating)
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
        .frame(height: Metrics.bannerActionHeight, alignment: .center)
        // 紧凑宽度（iPhone）下居中显示；常规宽度保持左对齐。
        .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil, alignment: .center)
    }

    private var playButton: some View {
        Button(action: playCurrent) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(resumeProgress == nil ? 0.78 : 0.34))
                    if let progress = resumeProgress {
                    // 宽度是定死的 `playButtonWidth`，直接乘比例就行，不用 GeometryReader——
                    // 它测出来的就是我们已经知道的那个常量，而 `resumeProgress` 一变
                    // （选中集切换、标记已看）就要多跑一轮布局，横幅上尤其不划算。
                        Rectangle()
                            .fill(.white.opacity(0.82))
                            .frame(width: playButtonWidth * progress)
                    }

                    Text(playButtonLabel)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.black.opacity(0.8))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: playButtonWidth, height: Metrics.bannerActionHeight)
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
            .frame(width: Metrics.bannerActionHeight, height: Metrics.bannerActionHeight)
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
                ExpandableOverview(text: overview)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 20)
    }

    // MARK: - 剧集：季 + 横向选集

    private var seasonBar: some View {
        HStack(spacing: 14) {
            Text("剧集").font(.title3.weight(.bold))
            Spacer()
            if seasons.count > 1 {
                Menu {
                    ForEach(seasons) { season in
                        Button {
                            selectedSeasonID = season.id
                        } label: {
                            if season.id == selectedSeasonID {
                                Label(season.name, systemImage: "checkmark")
                            } else {
                                Text(season.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selectedSeasonName)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .task(id: selectedSeasonID) { await loadEpisodes() }
    }

    private var selectedSeasonName: String {
        seasons.first(where: { $0.id == selectedSeasonID })?.name ?? "选择季"
    }

    private var episodeList: some View {
        Group {
            if isLoadingEpisodes {
                skeletonEpisodes
            } else if let episodeLoadError {
                ContentUnavailableView {
                    Label("集列表加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(episodeLoadError)
                } actions: {
                    Button(UIStrings.retry) { Task { await loadEpisodes() } }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, detailHorizontalInset)
                .transition(.opacity)
            } else if episodes.isEmpty {
                ContentUnavailableView("本季暂无剧集", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, detailHorizontalInset)
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

    /// 选集加载骨架：一排和 `EpisodeSelectCard` 同尺寸的占位卡，切季时不闪不跳。
    /// 和首屏骨架共用 `SkeletonEpisodeStrip`（原来是复制粘贴的两份）。
    private var skeletonEpisodes: some View {
        SkeletonEpisodeStrip()
            .skeletonShimmer()
            .transition(.opacity)
    }

    /// 横向选集 + 两侧悬浮箭头（鼠标靠近才显示；VoiceOver 下常显）。
    private var episodePickerRail: some View {
        HoverArrowHScroll(
            items: episodes,
            scrollStep: 4,
            contentLeading: contentLeading,
            edgeReserve: 28,
            verticalPadding: 10,
            // 箭头对准剧照中部（卡片上部），不是整卡含标题的几何中心。
            arrowYOffset: -18,
            scrollToID: selectedEpisodeID
        ) { episode in
            EpisodeSelectCard(
                episode: episode,
                server: app.server,
                isSelected: episode.id == selectedEpisodeID,
                onSelect: {
                    selectedEpisodeID = episode.id
                    episodeScrollFocusID = episode.id
                    if let seasonID = selectedSeasonID {
                        selectedEpisodeBySeason[seasonID] = episode.id
                    }
                },
                onPlay: {
                    selectedEpisodeID = episode.id
                    episodeScrollFocusID = episode.id
                    if let seasonID = selectedSeasonID {
                        selectedEpisodeBySeason[seasonID] = episode.id
                    }
                    app.play(episode, resumeSeconds: episode.playState?.positionSeconds)
                }
            )
        }
    }

    // MARK: - 演员 / 类似

    private var castRail: some View {
        let actors = Array(shown.cast.filter { $0.kind == "Actor" }.prefix(20))
        let avatarSize: CGFloat = horizontalSizeClass == .compact ? 80 : 108
        return Rail("演员", kind: .flexible, items: actors) { person in
            VStack(spacing: 8) {
                let target = personImageTarget(person)
                RemoteImage(url: target.url, authHeader: target.authHeader, maxPixelSize: 240)
                    .aspectRatio(1, contentMode: .fill)
                    // 宽高都要定死：RemoteImage 内部占位 Rectangle 会竖向贪婪撑开，
                    // 只给宽度时头像被裁进一条很高的空白里，名字/角色被挤出可视区。
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                Text(person.name).font(.footnote).lineLimit(1).frame(width: avatarSize)
                if let role = person.role, !role.isEmpty {
                    Text(role).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).frame(width: avatarSize)
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

    /// 播放退出/结束回传落库后静默刷新详情与选集（不重置骨架屏、不打断页面浏览）。
    private func reloadAfterPlayback() async {
        guard let server = app.server else { return }
        if let loaded = try? await server.item(item.id) {
            detail = loaded
        }
        if shown.kind == .series {
            // 清理旧缓存，拉取当前季最新的播放进度
            episodesBySeason.removeAll()
            if let seasonID = selectedSeasonID {
                if let loaded = try? await server.episodes(seriesID: shown.id, seasonID: seasonID) {
                    episodesBySeason[seasonID] = loaded
                    episodes = loaded
                    if let currentID = selectedEpisodeID, loaded.contains(where: { $0.id == currentID }) {
                        // 保持选中集，其 playState 已经更新为最新的
                    } else {
                        let preferred = preferredEpisodeID(in: loaded, seriesID: shown.id)
                        selectedEpisodeID = preferred
                        episodeScrollFocusID = preferred
                    }
                }
            }
        }
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
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 14)
    }
}

// MARK: - 可折叠简介

/// 紧凑宽度（iPhone）下超过 3 行的简介折叠，底部附蓝色「更多」展开 / 「收起」收起。
/// 常规宽度（iPad / Mac）直接显示全文，无折叠。
private struct ExpandableOverview: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let text: String

    @State private var isExpanded = false

    @ViewBuilder
    var body: some View {
        if sizeClass == .compact {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(isExpanded ? "收起" : "展开全文")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
