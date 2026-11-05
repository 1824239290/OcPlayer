import AppDesignKit
import MoviePilotKit
import SwiftUI

/// 站点资源搜索页（复刻 MP 网页端「资源搜索」逻辑）：
/// 剧集只用来预填标题和回传 media_in——真正的搜索是**按标题**全站走
/// `/search/title`；聚合结果自己挑，站点收窄一律走结果筛选条（本地过滤）。
/// 下载完成后由 MoviePilot 服务端自动整理入库，这里不做任何入库追踪。
struct MoviePilotResourceView: View {
    /// 媒体上下文：标题预填 + 下载时 media_in 回传。
    let media: MPMediaInfo

    @State private var keyword: String

    @State private var torrents: [MPTorrent] = []
    /// 筛选+排序后的完整展示序列。**记忆化**：只在结果/筛选/排序变化的赋值点
    /// 重算（recomputeDisplayed），不随每次 body 求值重排——关键词输入、进度
    /// 文案、下载按钮状态这些高频求值不再触发全量过滤+排序。
    @State private var displayed: [MPTorrent] = []
    /// 懒加载窗口：一次只物化前 `revealWindow.shownCount(total:)` 条进 ForEach，
    /// 触底续载一窗。全量结果仍在内存（筛选候选聚合与下载原样回传需要），但视图
    /// diff、卡片状态与滚动簿记只随窗口走，几千条结果不再把页面顶爆。
    ///
    /// - Important: 窗口只管**条数**。要让「条数」真的等于「物化行数」，卡片流还
    ///   必须是 `LazyVStack` 的**直接子视图**（见 `MoviePilotTorrentList` 的类型
    ///   注释：被 `VStack` 包一层，`LazyVStack` 会把整块当一个子视图一次求值，
    ///   窗口等于没设）。
    @State private var revealWindow = TorrentRevealWindow()
    @State private var isSearching = false
    @State private var progressText: String?
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    // 筛选与排序（对齐 MP 网页端：本地过滤，候选值从结果聚合；排序偏好记忆）。
    @State private var filters = TorrentFilters()
    /// 各分组筛选候选值（从结果聚合）。随批次落账记忆化，不随 body 求值重算。
    @State private var filterOptions = TorrentFilterEngine.Options()
    @AppStorage("moviepilot.torrentSortField") private var sortFieldRaw = TorrentSortField.defaultOrder.rawValue
    @AppStorage("moviepilot.torrentSortAscending") private var sortAscending = false

    @State private var notice: String?
    @State private var isNoticeError = false
    @State private var addingDownloadID: String?
    /// 添加下载成功后直接推入下载管理页。
    @State private var navigateToDownloads = false

    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(media: MPMediaInfo) {
        self.media = media
        _keyword = State(initialValue: media.title ?? "")
    }

    var body: some View {
        Group {
            ScrollView {
                // ## 这个 `LazyVStack` 里**只许放直子视图**
                //
                // 2026-11-01：列表被一整块 `VStack(spacing: 12)` 包着（「资源」标题 +
                // 状态卡 + 卡片流 + footer 全在里头），于是 `LazyVStack` 眼里只有
                // **一个**子视图 —— 它一次就把那块算完：首帧把 60 条全建出来（探针
                // 实测 60/60），footer 的 `onAppear` 又在**同一帧**把窗口顶到 120，
                // 进页面立刻是 120 张液态玻璃卡；而这一整块是 eager 的、footer 从不
                // 离开视图树，`onAppear` 只发一次，所以之后再滚到底也**不会**续载。
                // 用户看到的就是「一堆玻璃一次性铺出来、滚动卡顿，滚到底也不动」。
                //
                // 现在页头、标题、状态、卡片流各自是直子视图；卡片流收在
                // `MoviePilotTorrentList` 里，那个类型的 body **顶层平铺**（ForEach +
                // `if`），没有包任何布局容器。间距逐项对账（改造前 → 改造后）：
                //
                // | 位置 | 改造前 | 改造后 |
                // | --- | --- | --- |
                // | 页头内部三块之间 | 18（`LazyVStack` spacing） | 18（`pageHeader` 内部 spacing） |
                // | 页头最后一块 →「资源」 | 18 + 4 | 12 + 10（标题的 `.padding(.top, 10)`） |
                // | 「资源」→ 状态卡 / 第一张卡 | 12（内层 `VStack` spacing） | 12（本层 spacing） |
                // | 卡与卡之间 | 12 | 12 |
                // | 最后一张卡 → footer | 12 | 12 |
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 1. 页头：媒体悬浮卡 + 搜索框 + 筛选排序 + 提示条
                    pageHeader

                    // 2. 「资源」标题与计数
                    torrentsHeader
                        .padding(.top, 10)

                    // 3. 状态卡（搜索中 / 出错 / 空态，三者择一）
                    torrentsStatus

                    // 4. 卡片流 + 触底续载（直子视图，懒加载真正生效的地方）
                    MoviePilotTorrentList(
                        displayed: displayed,
                        window: revealWindow,
                        addingDownloadID: addingDownloadID,
                        onDownload: { addDownload($0) },
                        onReveal: { revealMore() }
                    )
                }
                .padding(.horizontal, contentLeading)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(media.title ?? "资源搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .refreshable { await search().value }
            #if OCPLAYER_SELFTEST
            // 自检通道：不接服务器也能把「几千条结果 + 液态玻璃卡」这一屏摆出来
            // （`OCPLAYER_MOVIEPILOT_TORRENTS=<条数>`，见 `installTorrentFixtureIfRequested`）。
            .task { installTorrentFixtureIfRequested() }
            #endif
            .navigationDestination(isPresented: $navigateToDownloads) {
                MoviePilotDownloadsView()
                    // 与 MoviePilot 首页那个入口同款顶栏（此前只有系统返回键，
                    // 常规布局下与其它页不一致）。
                    .appShellBackChrome(title: "下载管理", presented: $navigateToDownloads)
            }
            // 呈现式页面不在 path 上，CoveredPageHider 看不见这层覆盖：下载管理
            // 落地期间本页（含声明，供整窗层继续渲染）整页隐去（见 coveredByPresented）。
            .coveredByPresented($navigateToDownloads)
        }
        // 氛围背景：与详情页同一套，走统一入口 `pageAmbience`（平台分叉收在那个
        // 修饰符里）。本页自带主体图（海报）→ `ownsArt`，macOS 上声明整窗层覆盖
        // 首页轮播、iOS 上自己垫。
        //
        // 历史约束已收进 `PageAmbience`：**不许加 `.drawingGroup()`**——它把子树
        // 栅格化进离屏纹理、纹理边界取扩展前的 frame，会把链尾的 `.ignoresSafeArea()`
        // 截断，图就出不了内容区、到不了 iPad 侧栏玻璃底下。
        .pageAmbience(
            AmbienceTarget(
                url: media.posterURL, authHeader: nil, scrim: .detail, ownsArt: true))
    }

    // MARK: - 头部英雄卡片

    private var heroGlassCard: some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: media.posterURL, authHeader: nil, maxPixelSize: 360)
                .frame(width: 84, height: 126)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 7) {
                Text(media.title ?? "未知条目")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    if let type = media.type, !type.isEmpty {
                        PillChip(type)
                    }
                    if let year = media.titleYear ?? media.year, !year.isEmpty {
                        PillChip(year, font: .caption2.monospacedDigit())
                    }
                    if let rating = media.voteAverage, rating > 0 {
                        RatingPill(score: rating, style: .capsule)
                    }
                }

                if let overview = media.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .lineSpacing(2)
                } else if !media.subtitle.isEmpty {
                    Text(media.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                // 下载时 media 会原样回传成 `media_in`，MoviePilot 靠它里面的
                // `tmdb_id` 刮削；没有编号的条目（多半是 Douban / Bangumi 源）
                // 下载后刮削会缺字段——进页面就说清，别等入库了才发现。
                //
                // 顺带把**它实际带的编号**写出来（`sourceSummary`）：只说「没有
                // TMDB 编号」时用户无从判断该不该换，看到「豆瓣编号 35593344」
                // 才知道这条是豆瓣源、换 TMDB 那条即可。
                if media.tmdbId == nil {
                    // 自绘而不是 `Label`：`Label` 的图标在**垂直居中**于整个标签，
                    // 这段文案折成 2–3 行时三角会浮在文字块正中，像错位。
                    // `firstTextBaseline` 让它对齐首行。
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("没有 TMDB 编号，下载完成后 MoviePilot 的自动刮削可能缺字段。")
                            Text("\(media.sourceSummary)，建议换一条 TMDB 来源的条目。")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(16)
        // 2026-10-22：与下载页同一套液态玻璃（原 `.ultraThinMaterial` 扁平磨砂）。
        .liquidGlassCard()
    }

    // MARK: - 搜索控件

    private var searchAndControlBar: some View {
        HStack(spacing: 10) {
            CapsuleSearchField("搜索关键词", text: $keyword, focus: $searchFieldFocused) {
                search()
            }

            // 搜索按钮
            Button {
                search()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("搜索")
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.22), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
        }
    }

    // MARK: - 筛选与排序

    private var sortField: TorrentSortField {
        TorrentSortField(rawValue: sortFieldRaw) ?? .defaultOrder
    }

    /// 重算筛选+排序后的展示序列。只在输入变化的赋值点调用：
    /// 搜索批次落账、筛选弹窗关闭侧的 binding、排序菜单/升降序切换、新搜索清空。
    private func recomputeDisplayed() {
        displayed = TorrentFilterEngine.sorted(
            TorrentFilterEngine.filtered(torrents, filters: filters),
            field: sortField,
            ascending: sortAscending
        )
        // 结果变少（筛选 / 排序 / 新批次替换）时窗口收敛回数据上界；不回落到一页
        // 以下——窗口是「用户滚到多深」的记忆，放开筛选不该把他弹回顶部。
        revealWindow.clamp(total: displayed.count)
    }

    // MARK: - 页头（hero / 搜索 / 筛选 / 提示）

    /// 页头三块 + 提示条。四件固定内容，不是列表，所以照旧收在一个 `VStack` 里
    /// ——它作为 `LazyVStack` 的**一个**直子视图出现，只影响自己这一块（惰性没有
    /// 意义：它们本来就在首屏）。间距沿用改造前的 18。
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 媒体悬浮卡片（Hero Glass Banner）
            heroGlassCard

            // 搜索框与控制条（Search & Controls）
            searchAndControlBar

            // 筛选与排序行（Filters & Sort）
            if !torrents.isEmpty || filters.isActive {
                MoviePilotTorrentFilterBar(
                    filters: Binding(
                        get: { filters },
                        set: { filters = $0; recomputeDisplayed() }
                    ),
                    options: filterOptions,
                    sortField: Binding(
                        get: { sortField },
                        set: { sortFieldRaw = $0.rawValue; recomputeDisplayed() }
                    ),
                    sortAscending: Binding(
                        get: { sortAscending },
                        set: { sortAscending = $0; recomputeDisplayed() }
                    )
                )
            }

            // 状态提示条（下载结果 / 失败）
            if let notice {
                MoviePilotNoticeBanner(text: notice, isError: isNoticeError, glassCard: true)
            }
        }
    }

    // MARK: - 资源列表与空态

    /// 「资源」标题 + 数量徽章。
    ///
    /// 上方的 `.padding(.top, 10)` 是间距补偿：改造前这段挂在卡片流所在的
    /// `VStack(spacing: 12)` 顶上、还自带 `.padding(.top, 4)`，与页头之间是 18 + 4；
    /// 现在它在 `LazyVStack(spacing: 12)` 里，12 + 10 才是同一个 22。
    private var torrentsHeader: some View {
        HStack(spacing: 8) {
            Text("资源")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if filters.isActive, displayed.count != torrents.count {
                Text("\(displayed.count) / \(torrents.count)")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.quaternary, in: Capsule())
            } else if !torrents.isEmpty {
                Text("\(torrents.count)")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.quaternary, in: Capsule())
            }

            Spacer()
        }
    }

    /// 状态卡：搜索中 / 出错 / 空态，三者择一（都不成立时不占位）。
    @ViewBuilder
    private var torrentsStatus: some View {
        if isSearching {
            HStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 3) {
                    Text(progressText ?? "正在搜索各站点资源…")
                        .foregroundStyle(.primary)
                        .font(.callout.weight(.medium))
                    if !torrents.isEmpty {
                        Text("已收到 \(torrents.count) 条，边搜边出——可以直接挑选下载")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard()
        } else if let searchError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(searchError)
                    .foregroundStyle(.red)
                    .font(.callout)
                Spacer()
                Button(UIStrings.retry) { search() }
                    .buttonStyle(.bordered)
            }
            .padding(14)
            .liquidGlassCard()
        } else if displayed.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: hasSearched ? "line.3.horizontal.decrease.circle" : "arrow.down.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(hasSearched
                     ? (filters.isActive
                        ? "筛掉了全部 \(torrents.count) 条结果，放宽条件试试。"
                        : "没有搜到资源。换个关键词（比如加 S02 / 第2季）、或调整站点再试。")
                     : "点击「搜索」开始；关键词已按剧名预填，可自行修改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .liquidGlassCard()
        }
    }

    /// 触底续载一窗：窗口只增不减、有界（夹在 `total` 以内）。
    private func revealMore() {
        revealWindow.reveal(total: displayed.count)
    }

    // MARK: - 动作

    /// 返回搜索任务：`.refreshable` 需要 await 它，下拉刷新的转圈才跟随流式
    /// 结束（原先同步调用即刻返回，转圈瞬间消失而搜索还在跑）。
    @discardableResult
    private func search() -> Task<Void, Never> {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Task {} }
        // 允许重入：搜索在途时再点不静默丢弃，旧任务直接取消（SSE 循环随任务取消收尾）。
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        hasSearched = true
        searchError = nil
        notice = nil
        torrents = []
        progressText = nil
        // 新搜索换一批数据源，旧筛选多半失效，整组重置。
        filters = TorrentFilters()
        // 展示序列、筛选候选与懒加载窗口一并打回首页大小。
        displayed = []
        filterOptions = TorrentFilterEngine.Options()
        revealWindow.reset()
        searchTask = Task {
            let (updates, continuation) = AsyncStream.makeStream(
                of: SearchStreamEvent.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            // 生产者：SSE 拉流跑在 client actor 上，回调只往流里投递，不碰 UI。
            let producer = Task {
                defer { continuation.finish() }
                do {
                    try await MoviePilotAPIClient.shared.searchTorrentsByTitleStream(
                        keyword: trimmed
                    ) { current, progress in
                        continuation.yield(.batch(current, progress))
                    }
                } catch {
                    if generation == searchGeneration, !Task.isCancelled {
                        continuation.yield(.failure(MoviePilotError.userMessage(of: error)))
                    }
                }
            }
            // 消费端：本任务继承视图主 actor，批次按投递顺序应用——
            // 旧实现经无序 Task{@MainActor} 跳转回主线程，连搜时旧批次可能反超新批次。
            // 缓冲只留最新一批：每个事件都带全量累计结果，中间批次不值得排队。
            for await update in updates {
                guard generation == searchGeneration else { break }
                switch update {
                case .batch(let current, let progress):
                    // 纯进度事件与帧间心跳也走这条回调（`MoviePilotAPIClient` 的 `default:`
                    // 分支照样 `onUpdate`），而它们的载荷与上一批**逐字段相同**。此时重算
                    // 是纯浪费：`recomputeDisplayed()` 是 filter + sorted，
                    // `TorrentFilterEngine.options` 还要 7 个 Set 各自 `sorted()`，
                    // 再加 4 次 `@Observable` 写入把整页重算一遍。
                    // 一场「按标题全站搜索」有 60–120 个事件，绝大多数属于这一类。
                    // 用值比较而不是条数：`replace` 事件可能条数相同而内容不同。
                    if current != torrents {
                        torrents = current
                        recomputeDisplayed()
                        filterOptions = TorrentFilterEngine.options(current)
                    }
                    progressText = progress.text
                case .failure(let message):
                    searchError = message
                }
            }
            // 消费端退出（被新一代取代/取消）时，把还在跑的旧 SSE 流一并停掉。
            producer.cancel()
            // 展示序列已随每批 recomputeDisplayed 落账，终态不需要再排一次。
            if generation == searchGeneration {
                isSearching = false
                progressText = nil
            }
        }
        return searchTask ?? Task {}
    }

    #if OCPLAYER_SELFTEST
    /// 自检夹具：`OCPLAYER_MOVIEPILOT_TORRENTS=<条数>` 时灌入合成结果，绕过整条搜索链路。
    ///
    /// 与 `MoviePilotCardPreviewStage` 同一套 `simctl launch` 用法（`SIMCTL_CHILD_` 前缀
    /// 转发环境变量）。存在的理由是这条缺陷**只在「很多条真结果 + 真液态玻璃」下显形**：
    /// 探针能量出「物化了多少行」，但量不出「一屏玻璃卡滚起来卡不卡」，那必须在真机上看。
    ///
    /// ```
    /// SIMCTL_CHILD_OCPLAYER_START_SECTION=moviepilot \
    /// SIMCTL_CHILD_OCPLAYER_MOVIEPILOT_TORRENTS=1000 \
    ///   xcrun simctl launch <udid> dev.jumusu.OcPlayer
    /// ```
    private func installTorrentFixtureIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["OCPLAYER_MOVIEPILOT_TORRENTS"],
              let count = Int(raw), count > 0 else { return }
        let fixtures = (0..<count).map(Self.syntheticTorrent(index:))
        torrents = fixtures
        hasSearched = true
        isSearching = false
        progressText = nil
        searchError = nil
        filterOptions = TorrentFilterEngine.options(fixtures)
        revealWindow.reset()
        recomputeDisplayed()
        AppDiagnostics.logInfo("自检：资源搜索页灌入 \(count) 条合成结果（OCPLAYER_MOVIEPILOT_TORRENTS）")
    }

    /// 复刻真实 SSE 元素的字段形态（`torrent_info` + `meta_info`），不是随便捏几条标题：
    /// 卡片会读 title / description / site_name / size / seeders / labels / date_elapsed，
    /// 标签行的宽度与换行只有在这些字段都齐的时候才和线上一致。
    private static func syntheticTorrent(index: Int) -> MPTorrent {
        let sites = ["馒头", "憨憨", "彩虹岛", "Audiences", "PTer"]
        let teams = ["LoliHouse", "ANi", "SweetSub", "NC-Raws", "Kirara"]
        let pix = ["1080p", "2160p"]
        let encode = ["x265", "H264", "AV1"]
        let episode = index % 24 + 1
        let season = index / 24 + 1
        let site = sites[index % sites.count]
        let team = teams[index % teams.count]
        return MPTorrent(
            raw: [
                "title": .string("药屋少女的呢喃 S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) [\(pix[index % 2])][\(encode[index % 3])][\(team)]"),
                "description": .string("第 \(episode) 话 · \(team) 压制 · Web 源"),
                "enclosure": .string("https://example.invalid/torrent/\(index).torrent"),
                "page_url": .string("https://example.invalid/detail/\(index)"),
                "site_name": .string(site),
                "size": .number(Double(1_200_000_000 + index * 7_300_000)),
                "seeders": .number(Double(index % 97)),
                "peers": .number(Double(index % 13)),
                "date_elapsed": .string("\(index % 30 + 1) 天前"),
                "downloadvolumefactor": .number(index % 4 == 0 ? 0 : 1),
                "labels": .array([index % 5 == 0 ? .string("中字") : .string("简繁")]),
            ],
            meta: [
                "season_episode": .string("S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"),
                "resource_team": .string(team),
                "video_encode": .string(encode[index % 3]),
                "resource_pix": .string(pix[index % 2]),
                "edition": .string(index % 3 == 0 ? "BluRay" : "WEB-DL"),
            ]
        )
    }
    #endif

    private func addDownload(_ torrent: MPTorrent) {
        addingDownloadID = torrent.id
        notice = nil
        Task {
            do {
                try await MoviePilotAPIClient.shared.addDownload(media: media, torrent: torrent)
                notice = "已添加下载；完成后 MoviePilot 会自动整理入库到 Jellyfin"
                isNoticeError = false
                app.pushPresented { navigateToDownloads = true }
            } catch {
                notice = MoviePilotError.userMessage(of: error)
                isNoticeError = true
            }
            addingDownloadID = nil
        }
    }
}

/// 资源搜索的流式事件：批次/失败统一经 AsyncStream 有序送主 actor。
private enum SearchStreamEvent: Sendable {
    case batch([MPTorrent], MPSearchProgress)
    case failure(String)
}

// MARK: - 卡片流（这个 body 顶层平铺，是懒加载生效的唯一写法）

/// 种子资源卡片流 + 触底哨兵。
///
/// ## 🔴 body 顶层**不许**包 `VStack`
///
/// `LazyVStack` 是按**直接子视图**决定物化哪些的：一个视图的 body 顶层平铺多个
/// 视图，它们各自算一个子视图；但 body 顶层若是一个**布局容器**（`VStack` /
/// `LazyVStack` / `Group` 之外的堆叠），那个容器会被当成**一个**子视图整体求值，
/// 里面所有行一次性建出来，`revealWindow` 的条数直接失去意义。
///
/// 2026-11-01 本机探针（800pt 高窗口、60pt 行、`LazyVStack` 内容）实测：
///
/// | 结构 | 首帧物化行数 | footer 触发 |
/// | --- | --- | --- |
/// | `VStack` 包住 ForEach（改造前的现状） | **120** | 1 次（首帧，此后不再触发） |
/// | body 顶层平铺（现在这样） | **7** | 0（滚到才触发） |
///
/// 也就是说：把这里改回 `VStack { ForEach … }`，退化的不是「省一点」，而是
/// 首帧又铺满一屏玻璃卡、并且续载彻底失效。`AppTests/MoviePilotTorrentListLazinessTests`
/// 用真实宿主窗口把这个判据钉住了（含反向验证）。
///
/// ## footer 的 `.id(window.limit)`
///
/// 窗口每涨一窗，footer 换一次身份。**实测口径（2026-11-01）**：在当前结构下把它
/// 去掉，`MoviePilotTorrentListLazinessTests` 仍然全绿 —— 因为 `LazyVStack` 本来就会
/// 把滚出视口的 footer 摘下来、滚回来时重新 `onAppear`。改造前那版「只触发一次」
/// **不是**身份的问题，是上面那条：`VStack` 包住的整块是 eager 的，footer 从头到尾
/// 都在树上，`onAppear` 自然只发一次。
///
/// 保留它的理由是把语义钉在「露了多少条」上，而不是「系统这次有没有把 footer 摘下来」：
/// 官方文档明确说滚出屏的 subview 不会被立刻移除，会保留若干个更新周期。窗口一变就换
/// 身份，续载时机就与这条内部策略无关。
///
/// - Note: 一窗 60 行 ≈ 5000pt，远大于任何视口，所以续载后 footer 一定被顶出视口，
///   不会出现「涨一窗→footer 仍在视口→又涨一窗」的连锁。
struct MoviePilotTorrentList: View {
    let displayed: [MPTorrent]
    let window: TorrentRevealWindow
    let addingDownloadID: String?
    let onDownload: (MPTorrent) -> Void
    let onReveal: () -> Void

    /// 行「进入视图树」的回调。**只给测试用**：`LazyVStack` 的物化是内部行为，
    /// 外部唯一能观察到的信号就是行自身的 `onAppear`。
    /// - Important: 生产调用点必须传 `nil`（多了它只是多一次空闭包调用，但语义上
    ///   生产没有理由关心这个）。
    var onRowAppear: ((String) -> Void)? = nil

    var body: some View {
        ForEach(displayed.prefix(window.shownCount(total: displayed.count))) { torrent in
            MoviePilotTorrentGlassCard(
                torrent: torrent,
                isAdding: addingDownloadID == torrent.id,
                onDownload: { onDownload(torrent) }
            )
            .onAppear { onRowAppear?(torrent.id) }
        }

        if window.hasMore(total: displayed.count) {
            revealFooter(total: displayed.count)
                .id(window.limit)
        }
    }

    /// 触底哨兵：滚进视野就续载一窗，文案同时交代剩余量。
    private func revealFooter(total: Int) -> some View {
        Text("已展示 \(window.shownCount(total: total)) / \(total) 条，继续下滑加载更多")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .onAppear { onReveal() }
    }
}

// MARK: - 种子资源液态玻璃卡片

private struct MoviePilotTorrentGlassCard: View {
    let torrent: MPTorrent
    let isAdding: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(torrent.title ?? "未命名资源")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let description = torrent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 微型发光胶囊标签行
                HStack(spacing: 6) {
                    if let site = torrent.siteName {
                        // 同 MoviePilotDownloadsView：站点身份标签走中性档，不占色相。
                        PillChip(site, role: .neutral, font: .caption2.weight(.semibold), bordered: true)
                    }
                    if torrent.isFree {
                        PillChip("免费", role: .custom(.green), font: .caption2.weight(.semibold), bordered: true)
                    }
                    ForEach(torrent.labels.prefix(2), id: \.self) { label in
                        PillChip(label, role: .custom(.orange), font: .caption2.weight(.semibold), bordered: true)
                    }

                    PillChip(torrent.sizeText, font: .caption2.monospacedDigit())

                    if let seeders = torrent.seeders {
                        PillChip(
                            "\(seeders)",
                            systemImage: "arrow.up",
                            role: seeders >= 5 ? .custom(.green) : .neutral,
                            font: .caption2.weight(.bold).monospacedDigit()
                        )
                    }

                    if let date = torrent.dateElapsed ?? torrent.pubdate {
                        Text(date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 12)

            // 下载按钮
            Button {
                onDownload()
            } label: {
                HStack(spacing: 5) {
                    if isAdding {
                        ProgressView().controlSize(.small)
                        Text("添加中…")
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("下载")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isAdding)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 2026-10-22：与下载页同一套液态玻璃（原 `primary .04` 纯色底）。
        .liquidGlassCard()
    }

    }
