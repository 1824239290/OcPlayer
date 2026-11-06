import AppDesignKit
import CoreModel
import JellyfinKit
import MetadataKit
import SwiftUI

#if os(iOS)
import UIKit
#endif

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
/// 剧集额外有季选择器（就在选集区的标题位）和按 30 集分段的横向选集
/// （点选中，顶部主按钮开播）。
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

    // 这里曾有一个 `isResourcePresented`：详情页的 MoviePilot 区块自己呈现「资源搜索」页时，
    // 要靠它把整页隐去（呈现式页面不在 path 上，CoveredPageHider 看不见这层覆盖）。
    // 现在那个区块只把片名交给 `pendingMoviePilotQuery`、切到 MoviePilot 分区，详情页
    // 不再呈现任何页面，开关随之删除（见 `MoviePilotResourceSection` 的类型注释）。

    /// 选集排序偏好跨启动保留：长剧倒序从最新一集看起，不用从头翻。
    @AppStorage(SettingsKeys.episodeSortAscending) private var episodesAscending = true

    /// 选集分区的浏览状态（展示哪些分区、当前哪一段、渲染哪些格）。
    ///
    /// 纯值计算收在 `EpisodeChunkNavigation`（`MetadataKit`，可脱离 SwiftUI 单测），
    /// 视图只留这一个 `@State` 字段与接线。只活在本次停留里：换季 / 换条目重建视图
    /// 即清空，不落盘——分区是浏览位置，不是偏好（与 `episodesAscending` 不同类）。
    @State private var chunkNav = EpisodeChunkNavigation()

    /// 本页的「整页翻页」状态机（见 `DetailPageFlip`）。
    ///
    /// **所有平台都声明**：它是纯状态机（`DetailPagePager` 已跨平台），
    /// 只有「滚轮监视器」那一段是 macOS 专属、收在 `DetailPageFlip` 内的 `#if` 里。
    /// 会不会被用由 `detailLayoutStyle` 决定，不由这里的存在与否决定——
    /// 声明成平台条件会让版式判定散回编译期，正是这次要消掉的东西。
    @State private var pager = DetailPagePager()

    /// iPhone 使用竖向封面和模糊遮罩。
    private var isPhoneDevice: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// iPad 的版式继续随尺寸类切换。
    private var isPadDevice: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// 本页版式。**唯一的判定点**，所有版式分支都必须读它（见 `DetailLayoutStyle`）。
    private var detailLayoutStyle: DetailLayoutStyle {
        DetailLayoutStyle.resolve(isPad: isPadDevice, hSizeClass: horizontalSizeClass)
    }

    init(item: MediaItem) {
        self.item = item
        _model = State(initialValue: DetailViewModel(item: item))
    }

    #if !os(macOS)
    /// 紧凑宽度（iPhone）横幅矮一点，留出更多正文空间。
    private var bannerHeight: CGFloat {
        horizontalSizeClass == .compact ? 260 : Metrics.bannerHeight
    }

    /// 紧凑端（iPhone）沉浸式横幅高度。
    private var compactBannerHeight: CGFloat { 290 }

    /// 紧凑宽度的播放钮窄一点，和海报/标题一起塞进窄屏不溢出。
    private var playButtonWidth: CGFloat {
        horizontalSizeClass == .compact ? 200 : 228
    }
    #endif

    /// 详情页屏幕边缘留白：紧凑宽度下为 20pt，保持全页对齐；iPad/Mac 沿用 contentLeading。
    private var detailHorizontalInset: CGFloat {
        horizontalSizeClass == .compact ? 20 : contentLeading
    }

    /// 当前选中的季条目（未选 / 无季时为 nil）。
    ///
    /// 头部站点图标与页内 Bangumi 区块都要用它：Bangumi 关联可能挂在季上，
    /// 两处各算一次就会漂（一个是「已选季」，一个是「第 1 季」）。
    /// 直接取 VM 的（同一个判断两处都要用，放在 VM 里可测）。
    private var selectedSeason: MediaItem? { model.selectedSeason }

    // MARK: - 整页翻页布局

    /// 翻页版式下「本页是否在栈顶且可翻页」。
    ///
    /// 由 flip 版式消费：macOS 的滚轮监视器安装/摘除读它（那段在
    /// `DetailPageFlip` 外层的 `#if os(macOS)` 里）；阶段 ① 起 iPad 的滚动联动也会读。
    ///
    /// 以前这里还留着一个条件（有剧照才翻页、无剧照回退旧横幅），结果是同一页在
    /// 两种版式之间来回切，进页时还会先闪一下旧横幅。旧横幅在 macOS 上已经整个删掉，
    /// 无剧照的条目由 `DetailPageArt` 自己出占位底色 —— 版式只有一套，没有回退分支。
    private var isFlippingActive: Bool {
        guard !app.isCompact else { return false }
        guard case .detail(let pushed, _)? = app.path.last else { return false }
        return pushed.id == item.id
    }

    // MARK: - 翻页版式

    /// 固定背景位于正文和第一页前景下方；翻页只改变模糊遮罩。
    private var flippedPages: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                detailScroll
                    .opacity(pager.bodyVisible ? 1 : 0)
                    .allowsHitTesting(pager.page == .body && !pager.isTransitioning)
                    .accessibilityHidden(pager.page != .body || pager.isTransitioning)

                artPage(size: size)
                    .opacity(pager.artForegroundVisible ? 1 : 0)
                    #if os(iOS)
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                        pager.handleSwipe(translation: value.translation, startedAtTop: true)
                    })
                    .accessibilityAction(named: Text("查看详细信息")) { pager.flipToBody() }
                    #endif
                    // 放在手势外层：隐藏的封面连同手势一起退出命中测试。
                    .allowsHitTesting(pager.page == .art && !pager.isTransitioning)
                    .accessibilityHidden(pager.page != .art || pager.isTransitioning)
            }
            .frame(width: size.width, height: size.height)
            .background {
                // 仅背景延伸到标签栏后；正文和选集仍由系统安全区避让底栏。
                GeometryReader { backgroundGeo in
                    DetailBackdropView(
                        artwork: model.backdropArtwork,
                        viewport: backgroundGeo.size,
                        expanded: pager.blurExpanded,
                        vertical: isPhoneDevice
                    )
                }
                #if os(iOS)
                .ignoresSafeArea(.container, edges: .bottom)
                #endif
                .allowsHitTesting(false)
            }
            .background {
                #if os(macOS)
                // 把所在窗口报给状态机：滚轮监视器只裁决这个窗口的事件。
                // iOS 的翻页走触控手势，不需要这层窗口回报。
                DetailPageWindowAnchor { pager.attach(window: $0) }
                #endif
            }
        }
        // 固定视口延伸到导航栏后，正文顶部另行预留内容间距。
        .ignoresSafeArea(edges: .top)
        #if OCPLAYER_SELFTEST
        .task {
            guard ProcessInfo.processInfo.environment["OCPLAYER_DETAIL_FLIP_PAGE"] == "2" else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            pager.flipToBody()
        }
        #endif
    }

    private func artPage(size: CGSize) -> some View {
        DetailPageArtScreen(
            viewport: size,
            model: model,
            server: app.server,
            leadingInset: detailHorizontalInset,
            compact: isPhoneDevice,
            playLabel: playButtonLabel,
            playProgress: resumeProgress,
            played: isPlayableMarkedPlayed,
            canPlay: canPlayCurrent,
            canTogglePlayed: canTogglePlayed,
            isUpdatingPlayed: isUpdatingPlayed,
            onPlay: playCurrent,
            onTogglePlayed: { Task { await togglePlayed() } },
            onSelectEpisode: { model.selectEpisode($0) },
            onPlayEpisode: { episode in
                model.selectEpisode(episode)
                app.play(episode, resumeSeconds: episode.playState?.positionSeconds)
            }
        )
        .frame(width: size.width, height: size.height)
        // 空白区也要接住点击：否则点在标题下方会穿到被盖住的正文滚动区上
        .contentShape(Rectangle())
    }

    #if DEBUG
    /// 已提交像素对应的来源，不能用待加载 URL 冒充上屏图片。
    private var probedBackdropURL: URL? {
        model.backdropArtwork.content?.target.url ?? model.backdropArtwork.entry?.target.url
    }
    #endif

    var body: some View {
        Group {
            if detailLayoutStyle == .flip {
                flippedPages
            } else {
                detailScroll
                    .background {
                        GeometryReader { geo in
                            DetailBackdropView(artwork: model.backdropArtwork, viewport: geo.size)
                        }
                        .ignoresSafeArea()
                    }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .ignoresSafeArea(edges: .top)
        .navigationTitle(horizontalSizeClass == .compact ? "" : model.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .detailNavigationDismissalBlocked(
            detailLayoutStyle == .flip && pager.blocksNavigationDismissal
        )
        .toolbarBackground(.hidden, for: .navigationBar)
        // iPhone 独占详情页；标签栏随导航转场同步进出，避免返回完成后再闪现。
        .navigationTabBarHidden(isPhoneDevice)
        .sensoryFeedback(.impact, trigger: isPlayableMarkedPlayed)
        .sensoryFeedback(.selection, trigger: model.selectedEpisodeID)
        #elseif os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        // 详情自己持有完整背景；声明 nil 清除整窗覆盖，避免两套图层同时换图。
        .pageAmbience(nil)
        #if DEBUG
        // DEBUG 诊断：记录提交到背景视图的图片来源（冻结过渡图 → 条目图）。
        // URL 指向已解码快照；不代表 GPU 首帧时间，也不记录淡入的中间帧。
        .onChange(of: probedBackdropURL, initial: true) { _, newURL in
            AppDiagnostics.logWarning("探针·详情页头图", fields: [
                "url": .string(newURL?.absoluteString ?? "nil"),
                "resolved": .boolean(model.isBackdropSourceResolved),
                "hasOverlay": .boolean(model.tmdbOverlay != nil),
            ])
        }
        #endif
        .task(id: item.id) {
            model.attach(app)
            await model.load()
        }
        .onChange(of: reduceMotion, initial: true) { _, newValue in
            pager.reduceMotion = newValue
        }
        .onChange(of: detailLayoutStyle) { _, _ in
            pager.reset()
        }
        #if os(macOS)
        // 翻页状态机：滚轮监视器只在本页是栈顶且翻页布局生效时安装
        // （macOS 26 上被盖页不发 onDisappear，靠 `app.path` 的深度判定）。
        .onChange(of: isFlippingActive, initial: true) { _, active in
            pager.reduceMotion = reduceMotion
            pager.updateMonitor(active: active)
        }
        .onDisappear { pager.updateMonitor(active: false) }
        #endif
        .onChange(of: app.detailRefreshGeneration) { _, _ in
            // 挂住任务：离页 / 换条目时取消，fire-and-forget 不再跑到旧页面上。
            model.reloadAfterPlaybackTask?.cancel()
            model.reloadAfterPlaybackTask = Task { await model.reloadAfterPlayback() }
        }
        .onDisappear {
            model.backdropArtwork.cancel()
            model.reloadAfterPlaybackTask?.cancel()
            // 真离页撤掉待补拉（被盖页 macOS 26 不发 onDisappear，被盖场景
            // 补拉照跑——正是要救的场景）。
            model.episodeReloadTask?.cancel()
        }
    }

    // MARK: - 详情页正文（= 翻页布局里的第二页）

    /// 正文内容，翻页版式的第二页拥有独立的原生 ScrollView。
    private var detailBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            // macOS 上 `detailScroll` 只是翻页页的第二屏，头部在另一页上。
            // **这一段必须留编译期**：下面 banner / 紧凑头部那几段实现在
            // `#if !os(macOS)` 里，macOS 引用不到它们。
            // 版式判定在 macOS 上恒为 `.flip`（见 `DetailLayoutStyle.resolve`），
            // 所以这里不需要运行时分支，编译期裁剪等价且能编过。
            metadata
                .padding(.top, 44)
            #else
            if detailLayoutStyle == .flip {
                // 翻页版式的第二页直接显示正文，顶部避让返回按钮。
                metadata
                    .padding(.top, isPhoneDevice ? 100 : 44)
            } else if horizontalSizeClass == .compact {
                // 头部版式不依赖图片是否到位；无图也保持同样的安全布局。
                ambientCompactHeader
            } else {
                ambientHeader
                metadata
            }
            #endif
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
            } else if model.shown.kind == .movie {
                movieEpisodeSection
            }
            if model.shown.kind == .boxSet {
                collectionSection
            }
            // 合集不渲染 Bangumi 章节区：那一栏列的是「按集数组织的作品」的章节，
            // 而合集是「多部电影的容器」，两者根本不是一回事。实测合集页上它匹配到
            // 的是同名**剧集**（EVA 合集 → 新世纪福音战士 TV 的 01…26 集），
            // 26 个「未看」格子里没有一个能点进合集里的那两部电影——纯粹是噪声。
            if model.shown.kind != .boxSet {
                BangumiChapterSection(
                    item: model.shown,
                    selectedSeason: selectedSeason,
                    // 章节列表同时是选集轨道占位的**兜底来源**：没配 TMDB（或 TMDB 编号
                    // 对不上）时用它补出库里没有的集。让区块递上来而不是 VM 自己再读一次库，
                    // 是因为区块今天已经在读全量章节，且自带启用开关 / 登录态 / 建库就绪三道闸门。
                    onCandidatesLoaded: { model.acceptBangumiCandidates($0) }
                )
            }
            MoviePilotResourceSection(item: model.shown)
            if !model.displayCast.isEmpty { castRail }
            // 当前选中集（电影为自身）的文件级媒体信息。
            // 合集传 nil：它是容器，服务端对它的 `MediaSources` 恒为空
            // （实测 `/Items?ids=<合集id>&fields=MediaSources` → 空），
            // 区块本来就会整块不渲染，没必要为它白打一次请求。
            DetailMediaInfoSection(
                item: model.shown.kind == .boxSet ? nil : playableItem,
                horizontalInset: detailHorizontalInset
            )
            if !model.similar.isEmpty { similarRail }
        }
        .padding(.bottom, 48)
        // 简介 / 演员 / 相似推荐都是**数据到了才插入**的区块（占位剧集详情落地
        // 才有简介与 cast，similar 异步更晚）。插入会把下方内容整体下压——动画
        // 作用域必须挂在**页面级** VStack 上才盖得住兄弟区块的下推（挂在区块
        // 自己上只会淡入自己，下面照样硬跳）。作用域按数据源各挂一个：值翻转
        // 的那一拍，插入区块淡入、下方下推，整页一次平滑重排。
        .motion(Motion.standard, value: model.displayOverview == nil)
        .motion(Motion.standard, value: model.displayCast.isEmpty)
        .motion(Motion.standard, value: model.similar.isEmpty)
        // iOS 入场由卡片缩放承担，macOS 保留路由淡入。
        // 骨架块和 RemoteImage 的原位淡入负责内容加载，避免整页透明度脉冲。
    }

    /// banner 的完整页面，或翻页版式的独立正文页。
    private var detailScroll: some View {
        ScrollView {
            detailBody
        }
        #if os(macOS)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            pager.bodyOffsetY = newValue
        }
        #else
        // 原生滚动独占正文拖动；只观察顶部与下拉阈值，不另挂 DragGesture。
        .onScrollGeometryChange(for: DetailPagePager.BodyScrollRegion.self) { geometry in
            DetailPagePager.bodyScrollRegion(
                offsetY: geometry.contentOffset.y + geometry.contentInsets.top
            )
        } action: { _, region in
            pager.updateBodyScroll(region: region)
        }
        .onScrollPhaseChange { oldPhase, phase, context in
            guard detailLayoutStyle == .flip else { return }
            pager.handleBodyScrollPhase(from: oldPhase, to: phase,
                offsetY: context.geometry.contentOffset.y + context.geometry.contentInsets.top)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        // 外层视口延伸到导航栏后；正文在安全区域内开始，背景仍铺满。
        .safeAreaPadding(.top, detailLayoutStyle == .flip ? 0 : nil)
        .accessibilityAction(named: Text("返回封面")) {
            if detailLayoutStyle == .flip { pager.flipToArt() }
        }
        #endif
    }

    // MARK: - iOS 氛围布局：紧凑头部与操作区
    // 头部高度与图片加载无关；背景统一由 DetailBackdropView 提供。
#if !os(macOS)

    private var compactContentStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            compactMetaRow
            compactActionSection
            // 与桌面端同一行提示（紧凑端没有 `metadata` 那一块，正文直接排在这里）。
            if let notice = model.staleNotice {
                StaleContentBanner(notice: notice)
            }
            if let overview = model.displayOverview, !overview.isEmpty {
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
                if let rating = model.displayRating {
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

            // 类型行：类型文本 + 右侧外部站点图标（Bangumi / TMDB）。
            // 放在这一行而不是上面那行，是因为上面那行已经排了评分 / 分级 / 年份 /
            // 季数 / 时长，紧凑宽度下再塞两个图标就要挤压换行了。
            HStack(spacing: 10) {
                if !model.displayGenres.isEmpty {
                    Text(model.displayGenres.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // Spacer 只在有类型文本时才需要（把图标推到行尾）。类型为空时
                    // 不留它：本行可能整行都空（无类型 + 无可跳转站点），一个落单的
                    // Spacer 是否占高度取决于父级给的提案，是能不赌就不赌的那种。
                    Spacer(minLength: 8)
                }
                DetailExternalLinksView(item: model.shown, selectedSeason: selectedSeason)
            }
        }
        // 同桌面 metaRow：详情未落地前隐匿（评分/分级/季数随 `shown` 切换补齐，
        // 半成品行先现身会在翻转动画里滑动），落地后带完整内容一次性淡入。
        .opacity(model.detail == nil ? 0 : 1)
        .motion(Motion.standard, value: model.detail != nil)
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
                // 中性强调色下的实底主行动：填充 `.primary`，文字必须**反色**
                // （`AppAccent.onSolid`）。不点名反色字会整颗糊成白底白字——tint 是
                // `.primary` 时系统不会自动给实底按钮换字色（详见 `AppAccent`）。
                Capsule()
                    .fill(AppAccent.solid)

                if let progress = resumeProgress {
                    // 已播进度条压在实底上：用**反色**的半透明带——深色模式下是压暗、
                    // 浅色模式下是提亮，两种外观都看得见（原来的 `Color.white` 压在
                    // 白色实底上完全不可见）。
                    Rectangle()
                        .fill(AppAccent.onSolid.opacity(0.25))
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
                .foregroundStyle(AppAccent.onSolid)
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

    // MARK: - iOS 氛围紧凑头部 / 标题

    private var ambientCompactHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactBannerTitle
                .padding(.horizontal, detailHorizontalInset)
                .padding(.bottom, 8)
                .frame(height: compactBannerHeight, alignment: .bottom)
            compactContentStack
        }
    }

    private var compactBannerTitle: some View {
        // 紧凑宽度：艺术字 Logo 或居中文本标题
        ItemTitleLogoView(item: model.shown, server: app.server, maxHeight: 84, maxWidth: 340, fontSize: 26, centered: true, adaptiveText: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }
    // MARK: - iOS 宽窗口头部 / 播放钮 / 元数据行
    //
    // 与上面几段是同一套：iPad / iPhone 的详情页头部，macOS 不编译。


    /// 宽窗口：海报、标题和操作浮在整页氛围背景上。
    private var ambientHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            bannerPoster(width: 120, height: 180).detailCoverSettlement()
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
        .padding(.bottom, 28)
        // 固定头部高度，加载/无图不改变正文起点，也为导航栏留出空间。
        .frame(height: bannerHeight, alignment: .bottom)
    }

    @ViewBuilder
    private func bannerPoster(width: CGFloat, height: CGFloat) -> some View {
        // 条件用 `posterTarget` 的结果而不是 `primaryImageTag != nil`：
        // 服务端没图但 TMDB 有海报时也该显示（TMDB 只补缺，正是这个场景）。
        let poster = model.posterTarget(width: 300)
        if poster.url != nil {
            RemoteImage(url: poster.url, authHeader: poster.authHeader, maxPixelSize: 300)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        } else {
            // 无图时仍保留海报槽位，标题和操作不会随数据落地横移。
            Color.clear.frame(width: width, height: height)
        }
    }

    private var bannerTitle: some View {
        ItemTitleLogoView(item: model.shown, server: app.server, maxHeight: 80, maxWidth: 420, fontSize: 28, adaptiveText: true)
    }

    /// 元数据行：颜色跟随外观——横幅底部渐变与氛围布局都按模式垫
    /// 黑纱（夜间配白字）或白雾（日间配深字），文字与之同套自适应。
    private var metaRow: some View {
        let base = colorScheme == .light ? Color.black : Color.white
        return HStack(spacing: 9) {
            // `P2-18`：**身份用内容，不用下标**。
            //
            // ## 这是「正确性 / 身份稳定性」，**不是**性能修复
            //
            // 审查明确指出（并核实了）：这条**没有任何可测量的性能收益** ——
            // 4 个 `Text` 的 `HStack` 无论用哪种 id 都无感；注释早先写的
            // 「与 `Motion.standard` 翻转动画叠加会抖」也**没有录屏或计数证据**，
            // 而且那段翻转发生时 `metaParts` 本就不变。
            //
            // 保留它的理由是**身份语义本身**：`metaParts` 是动态拼的
            // （年份 / 类型 / 时长 / 季数），**任一字段缺失会让后面元素整体前移**。
            // 用下标当身份时，前移等于「第 N 个元素换成了别的内容」—— SwiftUI
            // 会把它当作不同元素重建。这不是 bug（结果照样对），而是**让视图身份
            // 与数据身份脱节**的坏习惯：任何按位置做的状态/动画/测量都会跟着漂。
            //
            // 分隔符仍用 `index > 0`（位置信息确实需要），但**身份**用内容 ——
            // 两者解耦是关键。
            //
            // ## 唯一性前提（必须成立，否则 `ForEach` 收到重复 id = 未定义行为）
            //
            // 这四类内容的**文本形态互斥**：
            //   年份  "2024"（纯数字）
            //   类型  "科幻 / 剧情"（含 " / " 分隔）
            //   时长  "1 小时 23 分" / "45 分钟"（含「小时」或「分钟」）
            //   季数  "2 季"（含「季」）
            // 所以 `id: \.element`（纯内容）唯一且稳定。
            // `MetaPartsShapeTests` 用穷举把这条前提钉住了（年份 1900–2100 ×
            // 时长 1–300 分钟 × 季数 1–20 逐对求交集）。
            //
            // ⚠️ 若将来往 `metaParts` 里加**同形态**的字段（例如再来一个纯数字），
            // 这条就破了 —— 那时必须把身份改成结构化形式
            // （`struct ID: Hashable { text; occurrence }`），**不要靠字符串拼 "#序号"**
            // （第一版就是那么做的，审查实测 `["A","A","A#1"]` 会产生重复 id）。
            ForEach(Array(metaParts.enumerated()), id: \.element) { index, part in
                if index > 0 {
                    Text("·").foregroundStyle(base.opacity(0.4))
                }
                Text(part).foregroundStyle(base.opacity(0.78))
            }
            if let rating = model.displayRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(BangumiStatusColor.rating)
            }
            if let official = model.shown.officialRating {
                Text(official)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(base.opacity(colorScheme == .light ? 0.08 : 0.2), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(base.opacity(0.9))
            }
            // 外部站点图标（Bangumi / TMDB）：两个都是品牌彩色图，不受这一行的
            // 自适应前景色影响（`base` 只管上方那几个文字元素的明暗）。
            DetailExternalLinksView(
                item: model.shown,
                selectedSeason: selectedSeason
            )
        }
        .font(.subheadline)
        // 详情未落地前整行隐匿（占住行高）：`shown` 从列表条目切到详情条目时
        // 「N 季 / 评分 / 分级」才补齐，这些元素都排在行中段——半成品行先现身的话，
        // 补齐瞬间正好赶上横幅↔氛围翻转的动画作用域，它们会集体向右滑（录屏
        // 逐帧实证的徽章滑动）。行内前三位（年份/类型/时长）两态同值同位，
        // 切换对它们零影响；外链徽章后到，插在行尾不动别人。
        .opacity(model.detail == nil ? 0 : 1)
        .motion(Motion.standard, value: model.detail != nil)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = model.shown.year { parts.append(String(year)) }
        if !model.displayGenres.isEmpty { parts.append(model.displayGenres.prefix(3).joined(separator: " / ")) }
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
#endif

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

    /// 第二页正文开头的简介。
    ///
    /// 剧集页优先给**当前选中那一集**的简介：翻到正文本来就是想看「这一集讲什么」，
    /// 再读一遍整部剧的总简介没有信息量。该集没有简介（或只有空白）时回退到剧集
    /// 自己的简介，一行都不空着。电影等其他类型直接用条目简介。
    private var bodyOverview: String? {
        if model.shown.kind == .series, let episode = selectedEpisode,
           let text = model.displayEpisodeOverview(episode)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        guard let text = model.displayOverview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 内容来自缓存（这次刷新失败）时先摆一行轻提示，再是正文。
            // 放在简介上方：用户先知道「这是旧数据」，再去读内容。
            if let notice = model.staleNotice {
                StaleContentBanner(notice: notice)
            }
            if let overview = bodyOverview {
                ExpandableOverview(text: overview)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 20)
    }

    private var movieEpisodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选集")
                .font(.title3.weight(.bold))
            EpisodeSelectCard(
                episode: model.shown,
                server: app.server,
                displayTitle: "正片 · \(model.displayName)",
                displayOverview: model.shown.overview,
                thumbTarget: model.hasBackdrop
                    ? model.backdropTarget(width: 400)
                    : model.shown.homeStillImageTarget(app.server, width: 400),
                isSelected: true,
                // 电影自身已是当前播放条目，无需切换选择。
                onSelect: {},
                onPlay: playCurrent
            )
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 20)
    }

    // MARK: - 剧集：季 + 按 30 集分段的横向选集

    /// 选集区标题行：**标题位就是选季控件**（用户口径：把原先「剧集」那两个字的位置
    /// 换成右侧那个季选框），右侧只留正序/倒序。原右侧的季菜单随之删除——同一件事
    /// 不该有两个入口。
    private var seasonBar: some View {
        HStack(spacing: 14) {
            seasonSelector
            Spacer()
            if model.episodeSlots.count > 1 {
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
        }
        .padding(.horizontal, detailHorizontalInset)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .task(id: model.selectedSeasonID) {
            // 集列表与季的 TMDB 数据缓存粒度不同（见 VM 注释），并行取。
            async let episodes: Void = model.loadEpisodes()
            async let seasonTMDb: Void = model.loadSeasonOverlay()
            _ = await (episodes, seasonTMDb)
        }
    }

    /// 标题位的季入口：多季时是季选择菜单，单季时退回季名纯文本
    /// （不给只有一个选项的下拉），季数据未到时用「选集」兜底。
    @ViewBuilder
    private var seasonSelector: some View {
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
            .help("切换季")
            .accessibilityLabel("切换季，当前 \(model.selectedSeasonName)")
        } else {
            Text(model.seasons.isEmpty ? "选集" : model.selectedSeasonName)
                .font(.title3.weight(.bold))
        }
    }

    private var episodeList: some View {
        Group {
            if model.isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .transition(.section)
            } else if let episodeError = model.episodeLoadError {
                EmptyState(failure: episodeError, title: "集列表加载失败", systemImage: "wifi.exclamationmark") {
                    Task { await model.loadEpisodes() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, detailHorizontalInset)
                .transition(.section)
            } else if model.episodeSlots.isEmpty {
                EmptyState(empty: "本季暂无剧集", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, detailHorizontalInset)
                    .transition(.section)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // 一季超过 30 集才出分区条：普通季（≤30 集）的观感与改动前完全一致。
                    if model.episodeChunks.count > 1 {
                        EpisodeChunkBar(
                            chunks: displayedChunks,
                            activeIndex: activeChunkIndex,
                            sortAscending: episodesAscending,
                            leadingInset: contentLeading
                        ) { chunk in
                            chunkNav.browsedIndex = chunk.index
                        }
                        // 换季重建分区条：否则上一条的横向偏移会留下，当前分区可能在屏外。
                        .id(model.selectedSeasonID ?? "-")
                    }
                    episodePickerRail
                        // 换分区 / 换季重建轨道：SwiftUI 不会因为 items 变短自动把横向
                        // 偏移归零，不重建就会停在上一分区的偏移上（点 31-60 却先看到 60）。
                        .id(railIdentity)
                        .transition(.section)
                }
                // 整块（分区条 + 轨道）在「loading → 内容」这类翻转里淡入；分区之间的
                // 淡入淡出由上面那条轨道自己的 `.transition` 负责（子视图在父视图插入时
                // 用父的过渡，不会叠成两段动画）。
                .transition(.section)
            }
        }
        // 切季时旧选集淡出 → loading 淡入 → 新选集淡入，不再三处硬切。
        // **动画值刻意是本地集数而不是 slot 数**：占位是 TMDB 季数据晚到约一秒才插进来的，
        // 用 slot 数当值会让整条轨道在占位到位时重播一次过渡（可见地闪一下）；用本地集数
        // 则占位是「无动画插入」，观感更稳。空态 → 有占位那次翻转单独用一个值盖住。
        .motion(Motion.standard, value: model.isLoadingEpisodes)
        .motion(Motion.standard, value: model.episodes.count)
        .motion(Motion.standard, value: model.episodeSlots.isEmpty)
        // 分区切换也走同一作用域：旧段淡出、新段淡入、胶囊高亮跟着动。
        .motion(Motion.standard, value: activeChunkIndex)
        // 选中集变了就回到「跟随选中集」：手点分区只是浏览，选中态一变仍以选中集为准。
        // 段内点卡时两者指向同一分区，等于无变化。
        .onChange(of: model.selectedSeasonID) { _, _ in chunkNav.followSelection() }
        .onChange(of: model.selectedEpisodeID) { _, _ in chunkNav.followSelection() }
    }

    /// 分区条的展示顺序：与轨道同一个方向（倒序 = 段序与段内顺序一起反，
    /// 等价于改动前「整条轨道反转」的观感，标签仍是同一批集号区间）。
    private var displayedChunks: [EpisodeChunk] {
        chunkNav.displayedChunks(model.episodeChunks, ascending: episodesAscending)
    }

    /// 当前分区（`EpisodeChunk.index`）：用户手点过就听用户的；否则跟随选中集；
    /// 都没有（还没选中）时落在**第一个展示出来的**分区（倒序即最后一段）。
    private var activeChunkIndex: Int {
        chunkNav.activeIndex(
            in: model.episodeChunks,
            selectedEpisodeID: model.selectedEpisodeID,
            ascending: episodesAscending)
    }

    /// 轨道身份：换季 / 换分区 / 翻排序时重建，横向滚动位置回到段首。
    ///
    /// 排序也算身份：正序↔倒序是把同一段**镜像**一遍，偏移量不变就会停在镜像后的
    /// 中段（点 31-60 却先看到 45）——重置回段首或选中集才是可预期的。
    private var railIdentity: String {
        "\(model.selectedSeasonID ?? "-")-\(activeChunkIndex)-\(episodesAscending)"
    }

    /// 当前分区要渲染的格子（≤30 张）。排序只影响展示顺序，不动 `model.episodes`、
    /// `episodeSlots`、`episodeChunks` 与选中态。
    private var railSlots: [EpisodeSlot] {
        chunkNav.railSlots(in: model.episodeChunks, activeIndex: activeChunkIndex,
                           ascending: episodesAscending)
    }

    /// 横向选集 + 两侧悬浮箭头（鼠标靠近才显示；VoiceOver 下常显）。
    ///
    /// 每一格按类型分派：库里有 → 可选可播的分集卡；库里没有 → 不可点的占位卡。
    /// `scrollToID` 仍是选中集的 id（永远是本地条目），**照传不误**：分区过滤后
    /// `HoverArrowHScroll` 自己会判定「该 id 不在本段 items 里就忽略」，占位的 id
    /// 与它也不同形，不会误滚。
    private var episodePickerRail: some View {
        HoverArrowHScroll(
            items: railSlots,
            scrollStep: 4,
            contentLeading: contentLeading,
            edgeReserve: 28,
            verticalPadding: 10,
            // 箭头对准剧照中部（卡片上部），不是整卡含标题的几何中心。
            arrowYOffset: -18,
            scrollToID: model.selectedEpisodeID
        ) { slot in
            switch slot {
            case .local(let episode):
                EpisodeSelectCard(
                    episode: episode,
                    server: app.server,
                    // 标题走 VM：服务端那种「第 9 集」的占位名会被 TMDB 的真标题顶掉。
                    displayTitle: model.displayEpisodeTitle(episode),
                    displayOverview: model.displayEpisodeOverview(episode),
                    // 剧照同样按「能用 TMDB 就用」的策略解析（含 still_path）。
                    thumbTarget: model.episodeThumbTarget(for: episode, width: 400),
                    isSelected: episode.id == model.selectedEpisodeID,
                    onSelect: { model.selectEpisode(episode) },
                    onPlay: {
                        model.selectEpisode(episode)
                        app.play(episode, resumeSeconds: episode.playState?.positionSeconds)
                    }
                )
            case .placeholder(let placeholder):
                EpisodePlaceholderCard(
                    placeholder: placeholder,
                    // TMDB 剧照优先，没有时用剧集自己的横版图（同首页「继续观看」那条链）。
                    thumbTarget: model.placeholderThumbTarget(for: placeholder, width: 400)
                )
            }
        }
    }

    // MARK: - 合集：成员海报墙

    /// 合集内容：`/Items?parentId=<合集id>&recursive=false` 的成员。
    ///
    /// 用网格而不是横向轨道：合集就是「一叠片」，成员通常 2–20 条，一屏看全比横着滑
    /// 更好找；列宽算法与库页网格同一套（紧凑两列 / 常规自适应）。
    /// 区块放在季/集那一档的同一位置（简介之下、Bangumi 区块之前）。
    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("合集内容").font(.title3.weight(.bold))
                if let total = model.collectionMembersTotalCount, total > 0 {
                    Text("共 \(total) 部")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, detailHorizontalInset)
            .padding(.top, 26)
            .padding(.bottom, 12)

            memberGrid
        }
        .motion(Motion.standard, value: model.isLoadingMembers)
        .motion(Motion.standard, value: model.collectionMembers.count)
    }

    @ViewBuilder
    private var memberGrid: some View {
        if model.isLoadingMembers, model.collectionMembers.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else if let membersError = model.membersLoadError, model.collectionMembers.isEmpty {
            EmptyState(failure: membersError, title: "合集内容加载失败",
                       systemImage: "wifi.exclamationmark") {
                Task { await model.loadMembers(reset: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, detailHorizontalInset)
        } else if model.collectionMembers.isEmpty {
            // 空合集是合法状态（刚建好、还没往里加片）：说清楚，别显示成加载失败。
            EmptyState(empty: "这个合集里还没有内容", systemImage: "rectangle.stack")
                .frame(maxWidth: .infinity)
                .padding(.horizontal, detailHorizontalInset)
        } else {
            if let membersError = model.membersLoadError {
                // 已有内容 + 这次刷新失败：保留内容，只提示一行（与库页翻页失败同口径）。
                Text(membersError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, detailHorizontalInset)
                    .padding(.bottom, 10)
            }
            LazyVGrid(columns: memberColumns, alignment: .leading, spacing: memberGridSpacing) {
                ForEach(model.collectionMembers) { member in
                    DetailTransitionCard(list: "detail.members", position: String(member.id), action: { source in app.openDetail(member, source: source) }) { open in
                        PosterCard(item: member, server: app.server, width: memberCardWidth) {
                            open()
                        }
                    }
                }
            }
            .padding(.horizontal, detailHorizontalInset)

            if model.hasMoreMembers {
                // 与库页不同，这里不自动预取：合集成员通常一页装得下，
                // 自动翻页反而会在用户没看的时候把整份拉下来。
                Button(UIStrings.loadMore) {
                    Task { await model.loadMembers(reset: false) }
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoadingMembers)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            }
        }
    }

    /// 合集成员海报墙：与库页 / 搜索结果同一份 `PosterGrid` 策略（紧凑端 3 列、
    /// 卡宽跟随列宽、标题区两行居中）。
    private var memberColumns: [GridItem] {
        PosterGrid.columns(compact: horizontalSizeClass == .compact)
    }

    private var memberGridSpacing: CGFloat {
        PosterGrid.rowSpacing(compact: horizontalSizeClass == .compact)
    }

    private var memberCardWidth: CGFloat? {
        PosterGrid.cardWidth(compact: horizontalSizeClass == .compact)
    }

    // MARK: - 演员 / 类似

    private var castRail: some View {
        let actors = Array(model.displayCast.filter { $0.kind == "Actor" }.prefix(20))
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
            // 卡宽必须显式给紧凑档 120：`Rail` 的紧凑高度（`posterRailHeight(compact:)`）
            // 就是按 120 算的，漏传会落到默认 178 —— 292pt 的卡塞进 267pt 的框，
            // 标题行被裁掉（与首页「最近添加」同一口径，见 `HomeView.posterWidth`）。
            DetailTransitionCard(list: "detail.similar", position: String(item.id), action: { source in app.openDetail(item, source: source) }) { open in
                PosterCard(
                    item: item,
                    server: app.server,
                    width: isCompactWidth ? Metrics.compactPosterWidth : Metrics.posterWidth
                ) {
                    open()
                }
            }
        }
    }

    /// 紧凑宽度（iPhone / iPad 分屏窄窗）：与 `horizontalSizeClass` 同口径，
    /// 只是给上面几处版式取值用。
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }

    private func personImageTarget(_ person: MediaItem.Person) -> (url: URL?, authHeader: String?) {
        // 交给 VM：TMDB 补的演员要走 TMDB CDN（它的 id 在服务端不存在，直接问会 400）。
        model.castImageTarget(for: person, width: 240)
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
        guard !isUpdatingPlayed, let target = playableItem else { return }
        let session = app.sessionGeneration
        let markAsPlayed = !(target.playState?.played ?? false)
        isUpdatingPlayed = true
        playedActionError = nil
        defer { isUpdatingPlayed = false }
        do {
            // 已看标记的唯一写入口是仓储：网络成功后同一拍更新所有内存投影与 SQLite。
            let state = markAsPlayed
                ? try await app.metadata.markPlayed(itemID: target.id)
                : try await app.metadata.markUnplayed(itemID: target.id)
            guard session == app.sessionGeneration else { return }
            if let state {
                await model.applyPlayState(state, toItemID: target.id, persistToRepository: false)
            }
        } catch let error as JellyfinError {
            guard session == app.sessionGeneration, !JellyfinError.isCancellation(error) else { return }
            playedActionError = error.errorDescription
        } catch {
            guard session == app.sessionGeneration, !JellyfinError.isCancellation(error) else { return }
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
