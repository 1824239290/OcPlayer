import AppDesignKit
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// 列表页带来的初版数据（立即可渲染），网络刷新后覆盖。
    let item: MediaItem

    /// 数据面（详情/季/集/类似的加载、缓存与选中态）在 `DetailViewModel`。
    /// 视图只留布局与交互编排。VM 在 `.task` 里 `attach(app)`——SwiftUI 的
    /// init 拿不到 @Environment，先建 VM 后挂依赖。
    @State private var model: DetailViewModel

    @State private var isUpdatingPlayed = false
    @State private var playedActionError: String?

    /// 选集排序偏好跨启动保留：长剧倒序从最新一集看起，不用从头翻。
    @AppStorage(SettingsKeys.episodeSortAscending) private var episodesAscending = true

    init(item: MediaItem) {
        self.item = item
        _model = State(initialValue: DetailViewModel(item: item))
    }

    /// 氛围布局是否生效：条目有 backdrop 图。没图时没有氛围层，
    /// 浮动白字头部会落在纯色底上看不清——这种情况永远走老横幅布局。
    private var isAmbientActive: Bool {
        model.shown.backdropImageTag != nil && app.server != nil
    }

    /// 页面是否自己垫氛围层。整窗层够得着屏幕时（macOS）常规布局靠它，页面
    /// 保持透明才能和侧栏连成一张图；够不着时（iOS，见
    /// `WindowAmbience.reachesScreen`）常规布局也得自垫。紧凑布局没有整窗层，
    /// 一律自垫。
    private var drawsOwnAmbience: Bool {
        !WindowAmbience.reachesScreen || horizontalSizeClass == .compact
    }

    /// 紧凑宽度（iPhone）横幅矮一点，留出更多正文空间。
    private var bannerHeight: CGFloat {
        horizontalSizeClass == .compact ? 260 : Metrics.bannerHeight
    }

    /// 紧凑端（iPhone）沉浸式横幅高度。
    private var compactBannerHeight: CGFloat { 290 }

    /// 氛围头部与屏幕顶部的间距。内容整体越过顶部安全区（ScrollView
    /// `ignoresSafeArea(.top)`），iPadOS 26 的导航栏玻璃按钮（侧栏开关 +
    /// 返回）悬深到 ~76pt、滚动边缘渐进模糊尾部到 ~82pt，64pt 会把海报
    /// 顶部压进两者——收起侧栏后海报左缘(52pt)正对按钮列尤其明显。
    /// iOS 抬到 104pt 让海报整张落在模糊带之下；macOS 工具栏浅，维持原深度。
    private var ambientHeaderTopInset: CGFloat {
        #if os(iOS)
        104
        #else
        64
        #endif
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
            if model.isLoading && model.detail == nil {
                skeleton
                    .transition(.section)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if horizontalSizeClass == .compact {
                            if isAmbientActive {
                                ambientCompactHeader
                            } else {
                                compactHeaderView
                            }
                        } else if isAmbientActive {
                            // 氛围布局：无横幅图层，头部内容直接浮在整页背景上。
                            ambientHeader
                            metadata
                        } else {
                            banner
                            metadata
                        }
                        if let loadError = model.loadError {
                            ErrorNotice(loadError)
                                .padding(.horizontal, detailHorizontalInset)
                                .padding(.top, 14)
                        }
                        if let playedActionError {
                            ErrorNotice(playedActionError)
                                .padding(.horizontal, detailHorizontalInset)
                                .padding(.top, 14)
                        }
                        if model.shown.kind == .series {
                            seasonBar
                            episodeList
                        }
                        BangumiChapterSection(
                            item: model.shown,
                            selectedSeason: model.seasons.first(where: { $0.id == model.selectedSeasonID })
                        )
                        MoviePilotResourceSection(item: model.shown)
                        if !model.shown.cast.isEmpty { castRail }
                        // 当前选中集（电影为自身）的文件级媒体信息。
                        DetailMediaInfoSection(
                            item: playableItem,
                            horizontalInset: detailHorizontalInset
                        )
                        if !model.similar.isEmpty { similarRail }
                    }
                    .padding(.bottom, 48)
                }
                .contentMargins(.top, 0, for: .scrollContent)
                .ignoresSafeArea(edges: .top)
                .transition(.section)
            }
        }
        // 骨架 → 内容原位交叉淡入，不再硬切。
        .motion(Motion.standard, value: model.isLoading)
        .navigationTitle(horizontalSizeClass == .compact ? "" : model.shown.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sensoryFeedback(.impact, trigger: isPlayableMarkedPlayed)
        .sensoryFeedback(.selection, trigger: model.selectedEpisodeID)
        #elseif os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        // 氛围背景：整窗层够得着屏幕时（macOS 常规布局）由 AppShell 垫声明图，
        // 页面必须保持透明才能和侧栏连成一张图；够不着时（iOS）或紧凑布局没有
        // 整窗层，页面自己垫氛围 + 兜底纯色。
        .background {
            if drawsOwnAmbience, isAmbientActive {
                BackdropAmbienceView(
                    target: model.shown.imageTarget(app.server, kind: .backdrop, width: 800),
                    scrim: .detail
                )
            }
        }
        .background {
            if drawsOwnAmbience || !isAmbientActive {
                Color.pageBackground.ignoresSafeArea()
            }
        }
        .windowAmbience(
            WindowAmbience.reachesScreen && isAmbientActive
                ? WindowAmbience(
                    url: model.shown.imageTarget(app.server, kind: .backdrop, width: 800).url,
                    authHeader: model.shown.imageTarget(app.server, kind: .backdrop, width: 800).authHeader
                )
                : nil
        )
        .task(id: item.id) {
            model.attach(app)
            await model.load()
        }
        .onChange(of: app.detailRefreshGeneration) { _, _ in
            // 挂住任务：离页 / 换条目时取消，fire-and-forget 不再跑到旧页面上。
            model.reloadAfterPlaybackTask?.cancel()
            model.reloadAfterPlaybackTask = Task { await model.reloadAfterPlayback() }
        }
        .onDisappear {
            model.reloadAfterPlaybackTask?.cancel()
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
            if model.shown.kind == .series {
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
            LinearGradient(
                colors: [Color.pageBackground.opacity(0.7), Color.pageBackground.opacity(0.2), .clear],
                startPoint: .top,
                endPoint: .center
            )
            LinearGradient(
                colors: [.clear, Color.pageBackground.opacity(0.35), Color.pageBackground],
                startPoint: .top,
                endPoint: .bottom
            )
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
            LinearGradient(
                colors: [Color.pageBackground.opacity(0.8), Color.pageBackground.opacity(0.3), .clear],
                startPoint: .top,
                endPoint: .center
            )
            LinearGradient(
                colors: [.clear, Color.pageBackground.opacity(0.35), Color.pageBackground],
                startPoint: .top,
                endPoint: .bottom
            )
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
            let target = model.shown.imageTarget(app.server, kind: .backdrop, width: 1600)
            if let url = target.url {
                RemoteImage(url: url, authHeader: target.authHeader, maxPixelSize: 1000)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: compactBannerHeight)
                    .clipped()
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }

            // 顶部/底部两组 pageBackground 渐隐合并成一条多 stop 渐变
            //（旧实现是两条全尺寸渐变叠着合成，合成权重见各 stop）。
            LinearGradient(
                stops: [
                    .init(color: Color.pageBackground.opacity(0.7), location: 0),
                    .init(color: Color.pageBackground.opacity(0.34), location: 0.25),
                    .init(color: Color.pageBackground.opacity(0.35), location: 0.5),
                    .init(color: Color.pageBackground.opacity(0.675), location: 0.75),
                    .init(color: Color.pageBackground, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 居中/醒目的标题 Logo
            compactBannerTitle
                .padding(.horizontal, detailHorizontalInset)
                .padding(.bottom, 8)
        }
        .frame(height: compactBannerHeight)
        .clipped()
    }

    private var compactContentStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            compactMetaRow
            compactActionSection
            if let overview = model.shown.overview, !overview.isEmpty {
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
                if let rating = model.shown.communityRating {
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

                if let official = model.shown.officialRating {
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

                if let year = model.shown.year {
                    Text(String(year))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if model.shown.kind == .series, let count = model.shown.childCount {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(count) 季")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if let runtime = model.shown.runtimeSeconds {
                    Text("·").foregroundStyle(.tertiary)
                    Text(RuntimeText.format(runtime))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !model.shown.genres.isEmpty {
                Text(model.shown.genres.joined(separator: " · "))
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
        if model.shown.kind == .series {
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
            // 背景层：fill 的溢出尺寸会参与 ZStack 布局、把渐变层的坐标系一起
            // 撑高，底部渐隐就画到了裁剪窗口之外（视觉上「渐变没了」）。先把
            // 图片层钳回定高、原位裁掉溢出，渐变才对齐可见区域。
            let target = model.shown.imageTarget(app.server, kind: .backdrop, width: 1600)
            if let url = target.url {
                RemoteImage(url: url, authHeader: target.authHeader, maxPixelSize: 1000)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: bannerHeight)
                    .clipped()
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }

            // 底部渐变：夜间黑纱保白字；日间换白雾垫自适应深字（与氛围布局
            // 同套「文字随外观」逻辑），两种模式都有足够的文字对比度。
            LinearGradient(
                colors: [
                    (colorScheme == .light ? Color.white : Color.black).opacity(0.65),
                    (colorScheme == .light ? Color.white : Color.black).opacity(0.2),
                    .clear,
                ],
                startPoint: .bottom,
                endPoint: .center
            )

            // 顶部/底部两组 pageBackground 渐隐合并成一条多 stop 渐变
            //（旧实现是两条全尺寸渐变叠着合成，各 stop 的透明度按
            // 「底混上」的合成权重算好，视觉不变，少一层全尺寸合成）。
            // 仅在老横幅布局（氛围背景关）使用，底部必须渐隐到实色。
            LinearGradient(
                stops: [
                    .init(color: Color.pageBackground.opacity(0.85), location: 0),
                    .init(color: Color.pageBackground.opacity(0.42), location: 0.25),
                    .init(color: Color.pageBackground.opacity(0.35), location: 0.5),
                    .init(color: Color.pageBackground.opacity(0.675), location: 0.75),
                    .init(color: Color.pageBackground, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
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
                // 日间白雾上的白胶囊按钮缺少分界，给文字列一层柔和投影
                //（海报自带投影，不并入，避免双重阴影）。
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
            .padding(.horizontal, detailHorizontalInset)
            .padding(.bottom, 28)
        }
        .clipped()
    }

    @ViewBuilder
    // MARK: - 氛围布局头部（条目有 backdrop 时替代横幅）

    /// 桌面端：海报 + 标题 + 元数据 + 播放钮直接浮在整页氛围背景上，
    /// 内容与老横幅的 overlay 完全同套组件（同为外观自适应色），
    /// 只是不再有图片层和渐变，也没有压暗带。
    private var ambientHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            bannerPoster(width: 120, height: 180)
            VStack(alignment: .leading, spacing: 8) {
                bannerTitle
                metaRow
                playbackActions
            }
            // 白色胶囊按钮压在日间浅雾上缺少分界，给一层柔和投影兜底。
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        // 老横幅靠全宽图片层把 ZStack 撑满；这里没有图层级，自己撑满全宽。
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, ambientHeaderTopInset)
        .padding(.bottom, 28)
    }

    /// 紧凑端：居中标题 + 元数据/播放区直接排在氛围背景上。
    ///
    /// 标题占**和 `compactHeroBanner` 同一个竖直位置**——同一个 `compactBannerHeight`
    /// 英雄带、同样底对齐 + 8pt 内边距，只是这里没有图片层。所以「有图 / 无图」
    /// 两条头部的标题落在同一竖直位置，正文区起点两边也都是 `compactBannerHeight`。
    /// 顶边贴屏那版（`padding(.top, 52)`）会让艺术字 Logo 压进状态栏、离灵动岛只剩
    /// 几个点，底对齐后 Logo 顶边恒定落在 198pt 以下，离状态栏自然有余量。
    private var ambientCompactHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactBannerTitle
                .padding(.horizontal, detailHorizontalInset)
                .padding(.bottom, 8)
                .frame(height: compactBannerHeight, alignment: .bottom)
            compactContentStack
        }
    }

    @ViewBuilder
    private func bannerPoster(width: CGFloat, height: CGFloat) -> some View {
        if model.shown.primaryImageTag != nil {
            let poster = model.shown.imageTarget(app.server, kind: .primary, width: 300)
            RemoteImage(url: poster.url, authHeader: poster.authHeader, maxPixelSize: 300)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
    }

    private var bannerTitle: some View {
        ItemTitleLogoView(item: model.shown, server: app.server, maxHeight: 80, maxWidth: 420, fontSize: 28, adaptiveText: true)
    }

    private var compactBannerTitle: some View {
        // 紧凑宽度：艺术字 Logo 或居中文本标题
        ItemTitleLogoView(item: model.shown, server: app.server, maxHeight: 84, maxWidth: 340, fontSize: 26, centered: true, adaptiveText: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 元数据行：颜色跟随外观——横幅底部渐变与氛围布局都按模式垫
    /// 黑纱（夜间配白字）或白雾（日间配深字），文字与之同套自适应。
    private var metaRow: some View {
        let base = colorScheme == .light ? Color.black : Color.white
        return HStack(spacing: 9) {
            ForEach(Array(metaParts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·").foregroundStyle(base.opacity(0.4))
                }
                Text(part).foregroundStyle(base.opacity(0.78))
            }
            if let rating = model.shown.communityRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(BangumiStatusColor.rating)
            }
            if let official = model.shown.officialRating {
                Text(official)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(base.opacity(colorScheme == .light ? 0.08 : 0.2), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(base.opacity(0.9))
            }
        }
        .font(.subheadline)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = model.shown.year { parts.append(String(year)) }
        if !model.shown.genres.isEmpty { parts.append(model.shown.genres.prefix(3).joined(separator: " / ")) }
        if let runtime = model.shown.runtimeSeconds { parts.append(RuntimeText.format(runtime)) }
        if model.shown.kind == .series, let count = model.shown.childCount {
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
        switch model.shown.kind {
        case .series:
            return selectedEpisode
        default:
            return model.shown
        }
    }

    private var selectedEpisode: MediaItem? {
        guard let selectedID = model.selectedEpisodeID else { return nil }
        return model.episodes.first { $0.id == selectedID }
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
            if let overview = model.shown.overview, !overview.isEmpty {
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
            if model.episodes.count > 1 {
                Button {
                    episodesAscending.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(episodesAscending ? "正序" : "倒序")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if model.seasons.count > 1 {
                Menu {
                    ForEach(model.seasons) { season in
                        Button {
                            model.selectSeason(season.id)
                        } label: {
                            if season.id == model.selectedSeasonID {
                                Label(season.name, systemImage: "checkmark")
                            } else {
                                Text(season.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.selectedSeasonName)
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
        .task(id: model.selectedSeasonID) { await model.loadEpisodes() }
    }

    private var episodeList: some View {
        Group {
            if model.isLoadingEpisodes {
                skeletonEpisodes
            } else if let episodeError = model.episodeLoadError {
                EmptyState(failure: episodeError, title: "集列表加载失败", systemImage: "wifi.exclamationmark") {
                    Task { await model.loadEpisodes() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, detailHorizontalInset)
                .transition(.section)
            } else if model.episodes.isEmpty {
                EmptyState(empty: "本季暂无剧集", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, detailHorizontalInset)
                    .transition(.section)
            } else {
                episodePickerRail
                    .transition(.section)
            }
        }
        // 切季时旧选集淡出 → loading 淡入 → 新选集淡入，不再三处硬切。
        // 两个 value 都绑：loading 翻转和集列表整体替换（count 变化）各自开一次事务。
        .animation(episodeListMotion, value: model.isLoadingEpisodes)
        .animation(episodeListMotion, value: model.episodes.count)
    }

    /// 选集区域的状态切换过渡；减弱动态效果时直接切换。
    private var episodeListMotion: Animation? {
        reduceMotion ? nil : Motion.standard
    }

    /// 选集加载骨架：一排和 `EpisodeSelectCard` 同尺寸的占位卡，切季时不闪不跳。
    /// 和首屏骨架共用 `SkeletonEpisodeStrip`（原来是复制粘贴的两份）。
    private var skeletonEpisodes: some View {
        SkeletonEpisodeStrip()
            .skeletonShimmer()
            .transition(.section)
    }

    /// 选集展示顺序：排序只影响横向条，不动 `model.episodes` 与选中态。
    private var displayedEpisodes: [MediaItem] {
        episodesAscending ? model.episodes : Array(model.episodes.reversed())
    }

    /// 横向选集 + 两侧悬浮箭头（鼠标靠近才显示；VoiceOver 下常显）。
    private var episodePickerRail: some View {
        HoverArrowHScroll(
            items: displayedEpisodes,
            scrollStep: 4,
            contentLeading: contentLeading,
            edgeReserve: 28,
            verticalPadding: 10,
            // 箭头对准剧照中部（卡片上部），不是整卡含标题的几何中心。
            arrowYOffset: -18,
            scrollToID: model.selectedEpisodeID
        ) { episode in
            EpisodeSelectCard(
                episode: episode,
                server: app.server,
                isSelected: episode.id == model.selectedEpisodeID,
                onSelect: { model.selectEpisode(episode) },
                onPlay: {
                    model.selectEpisode(episode)
                    app.play(episode, resumeSeconds: episode.playState?.positionSeconds)
                }
            )
        }
    }

    // MARK: - 演员 / 类似

    private var castRail: some View {
        let actors = Array(model.shown.cast.filter { $0.kind == "Actor" }.prefix(20))
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
        Rail("类似推荐", kind: .poster, items: model.similar) { item in
            PosterCard(item: item, server: app.server) {
                app.openDetail(item)
            }
        }
    }

    private func personImageTarget(_ person: MediaItem.Person) -> (url: URL?, authHeader: String?) {
        guard let server = app.server,
              let url = try? server.imageURL(itemID: person.id, type: .primary, maxWidth: 240, tag: nil)
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
            model.applyPlayState(state, toItemID: target.id)
        } catch let error as JellyfinError {
            playedActionError = error.errorDescription
        } catch {
            playedActionError = "\(error)"
        }
    }

    // MARK: - 数据已搬入 DetailViewModel（加载/缓存/选中态/智能默认季集）
}

// MARK: - 可折叠简介

/// 超过 3 行的简介折叠，底部附「展开全文」/「收起」按钮；紧凑（iPhone）与常规
/// （iPad / Mac）宽度行为一致，仅字号随宽度。按钮按实测截断与否显隐：
/// 全文没超 3 行不出按钮，窗口拉宽到不再截断时也会自动消失。
private struct ExpandableOverview: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String

    @State private var isExpanded = false
    /// 全文自然高度（背景隐藏副本量出）与限行后的实高；初始 0 = 还没量出，先不出按钮。
    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0

    private var showsToggleButton: Bool {
        isExpanded || (fullHeight > 0 && foldedHeight > 0 && fullHeight - foldedHeight > 1)
    }

    private var overviewFont: Font {
        sizeClass == .compact ? .subheadline : .body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(overviewFont)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foldedHeight = $0 }
                .background {
                    // 同字号的无限行副本：量出全文该有的高度，和限行实高比才知道截没截断。
                    Text(text)
                        .font(overviewFont)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if showsToggleButton {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.standard) { isExpanded.toggle() }
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
        }
    }
}
