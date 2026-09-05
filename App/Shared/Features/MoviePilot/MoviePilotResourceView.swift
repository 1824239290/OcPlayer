import MoviePilotKit
import SwiftUI

/// 站点资源搜索页（复刻 MP 网页端「资源搜索」逻辑）：
/// 剧集只用来预填标题和回传 media_in——真正的搜索是**按标题**走
/// `/search/title`，可选站点；聚合结果自己挑。下载完成后由 MoviePilot
/// 服务端自动整理入库，这里不做任何入库追踪。
struct MoviePilotResourceView: View {
    /// 媒体上下文：标题预填 + 下载时 media_in 回传。
    let media: MPMediaInfo

    @State private var keyword: String
    @State private var sites: [MPSite] = []
    @State private var sitesError: String?
    @State private var selectedSiteIDs: Set<Int> = []
    @State private var showSitePicker = false

    @State private var torrents: [MPTorrent] = []
    /// 筛选+排序后的完整展示序列。**记忆化**：只在结果/筛选/排序变化的赋值点
    /// 重算（recomputeDisplayed），不随每次 body 求值重排——关键词输入、进度
    /// 文案、下载按钮状态这些高频求值不再触发全量过滤+排序。
    @State private var displayed: [MPTorrent] = []
    /// 懒加载窗口：一次只物化前 displayLimit 条进 ForEach，触底续载一批。
    /// 全量结果仍在内存（筛选候选聚合与下载原样回传需要），但视图 diff、
    /// 卡片状态与滚动簿记只随窗口走，几千条结果不再把页面顶爆。
    @State private var displayLimit = Self.displayPageSize
    @State private var isSearching = false
    @State private var progressText: String?
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?

    // 筛选与排序（对齐 MP 网页端：本地过滤，选项从结果聚合；排序偏好记忆）。
    @State private var filters = TorrentFilters()
    @State private var showTorrentFilter = false
    @AppStorage("moviepilot.torrentSortField") private var sortFieldRaw = TorrentSortField.defaultOrder.rawValue
    @AppStorage("moviepilot.torrentSortAscending") private var sortAscending = false

    @State private var notice: String?
    @State private var isNoticeError = false
    @State private var addingDownloadID: String?
    /// 添加下载成功后直接推入下载管理页。
    @State private var navigateToDownloads = false

    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 懒加载窗口步长：触底一次续载这么多条。
    private static let displayPageSize = 60

    init(media: MPMediaInfo) {
        self.media = media
        _keyword = State(initialValue: media.title ?? "")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                // 1. 媒体悬浮卡片（Hero Glass Banner）
                heroGlassCard

                // 2. 搜索框与控制条（Search & Controls）
                searchAndControlBar

                // 3. 筛选与排序行（Filters & Sort）
                if !torrents.isEmpty || filters.isActive {
                    filterAndSortBar
                }

                // 4. 状态提示条
                if let notice {
                    noticeBanner(notice, isError: isNoticeError)
                }

                // 5. 资源列表（Torrents List）
                torrentsSection(displayed: displayed)
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            BackdropAmbienceView(target: (url: media.posterURL, authHeader: nil), scrim: .detail)
                .drawingGroup()
                .allowsHitTesting(false)
        }
        .navigationTitle(media.title ?? "资源搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 常规布局侧栏垫同一张海报当氛围底（无海报时不声明，侧栏维持系统玻璃）。
        .windowAmbience(WindowAmbience(url: media.posterURL, authHeader: nil))
        .task { await loadSites() }
        .refreshable { await search().value }
        .sheet(isPresented: $showSitePicker) {
            MoviePilotSitePickerSheet(sites: sites, selection: $selectedSiteIDs)
        }
        .sheet(isPresented: $showTorrentFilter) {
            MoviePilotTorrentFilterSheet(
                options: TorrentFilterEngine.options(torrents),
                // 自定义 binding：弹窗里勾选/清除（含「清除全部筛选」）都从
                // set 侧过一道，落账 filters 的同时重算展示序列。
                filters: Binding(
                    get: { filters },
                    set: { filters = $0; recomputeDisplayed() }
                )
            )
        }
        .navigationDestination(isPresented: $navigateToDownloads) {
            MoviePilotDownloadsView()
        }
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
                        Text(type)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    if let year = media.titleYear ?? media.year, !year.isEmpty {
                        Text(year)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    if let rating = media.voteAverage, rating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.caption2.weight(.bold).monospacedDigit())
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.yellow.opacity(0.12), in: Capsule())
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
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - 搜索控件

    private var searchAndControlBar: some View {
        HStack(spacing: 10) {
            // 搜索输入框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                TextField("搜索关键词", text: $keyword)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit { search() }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

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
    }

    private var filterAndSortBar: some View {
        HStack(spacing: 8) {
            // 站点选择胶囊
            Button {
                showSitePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(siteFilterText)
                    if !sites.isEmpty {
                        Text("共 \(sites.count) 站")
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // 筛选按钮
            Button {
                showTorrentFilter = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(filters.isActive ? "筛选 · \(filters.activeCount)" : "筛选")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    filters.isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        filters.isActive ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.1),
                        lineWidth: 0.5
                    )
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // 排序菜单与升降序切换
            Menu {
                Picker("排序", selection: Binding(
                    get: { sortField },
                    set: { sortFieldRaw = $0.rawValue; recomputeDisplayed() }
                )) {
                    ForEach(TorrentSortField.allCases, id: \.self) { field in
                        Text(field.label).tag(field)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("排序 · \(sortField.label)")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Button {
                sortAscending.toggle()
                recomputeDisplayed()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(sortAscending ? "当前升序，点击切换降序" : "当前降序，点击切换升序")
        }
    }

    private var siteFilterText: String {
        selectedSiteIDs.isEmpty ? "全部站点" : "已选 \(selectedSiteIDs.count) 个站点"
    }

    // MARK: - 资源列表与空态

    @ViewBuilder
    private func torrentsSection(displayed: [MPTorrent]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
            .padding(.top, 4)

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
                .liquidGlassCard(cornerRadius: 16)
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
                .liquidGlassCard(cornerRadius: 16)
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
                .liquidGlassCard(cornerRadius: 16)
            }

            // 种子卡片流（懒加载窗口：只物化前 displayLimit 条，触底哨兵续载）
            let window = displayed.prefix(displayLimit)
            ForEach(window) { torrent in
                MoviePilotTorrentGlassCard(
                    torrent: torrent,
                    isAdding: addingDownloadID == torrent.id,
                    onDownload: { addDownload(torrent) }
                )
            }

            if displayed.count > window.count {
                lazyLoadFooter(shown: window.count, total: displayed.count)
            }
        }
    }

    /// 触底续载：哨兵滚进视野就扩一批窗口；文案同时交代剩余量。
    /// 反复滚出/滚回会重复触发，min 钳制保证幂等。
    private func lazyLoadFooter(shown: Int, total: Int) -> some View {
        Text("已展示 \(shown) / \(total) 条，继续下滑加载更多")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .onAppear {
                displayLimit = min(displayLimit + Self.displayPageSize, total)
            }
    }

    private func noticeBanner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .font(.callout)
                .foregroundStyle(isError ? .red : .green)
            Spacer()
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 14)
    }

    // MARK: - 动作

    private func loadSites() async {
        guard sites.isEmpty else { return }
        do {
            sites = try await MoviePilotAPIClient.shared.sites()
            sitesError = nil
        } catch {
            // 站点列表拉不到不挡搜索（默认全部站点），给个提示就行。
            sitesError = "站点列表加载失败（不影响按全部站点搜索）：\((error as? MoviePilotError)?.userMessage ?? "\(error)")"
        }
    }

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
        // 展示序列与懒加载窗口一并打回首页大小。
        displayed = []
        displayLimit = Self.displayPageSize
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
                        keyword: trimmed,
                        sites: selectedSiteIDs.isEmpty ? [] : selectedSiteIDs.sorted()
                    ) { current, progress in
                        continuation.yield(.batch(current, progress))
                    }
                } catch {
                    if generation == searchGeneration, !Task.isCancelled {
                        continuation.yield(.failure((error as? MoviePilotError)?.userMessage ?? "\(error)"))
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
                    torrents = current
                    recomputeDisplayed()
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

    private func addDownload(_ torrent: MPTorrent) {
        addingDownloadID = torrent.id
        notice = nil
        Task {
            do {
                try await MoviePilotAPIClient.shared.addDownload(media: media, torrent: torrent)
                notice = "已添加下载；完成后 MoviePilot 会自动整理入库到 Jellyfin"
                isNoticeError = false
                navigateToDownloads = true
            } catch {
                notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
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

/// 站点多选弹窗：空选 = 全部站点（与 MP 网页端一致的语义）。
private struct MoviePilotSitePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sites: [MPSite]
    @Binding var selection: Set<Int>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("搜索全部站点") {
                        selection = []
                        dismiss()
                    }
                } footer: {
                    Text("不选任何具体站点时，MoviePilot 会在所有启用的站点里搜。")
                }

                Section("按站点筛选") {
                    if sites.isEmpty {
                        Text("站点列表为空或加载失败。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sites) { site in
                            Button {
                                if selection.contains(site.id) {
                                    selection.remove(site.id)
                                } else {
                                    selection.insert(site.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.name ?? "站点 \(site.id)")
                                        if let domain = site.domain {
                                            Text(domain)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if !site.isActive {
                                        Text("已停用")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if selection.contains(site.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("选择站点")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
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
                        glassBadge(site, tint: .blue)
                    }
                    if torrent.isFree {
                        glassBadge("免费", tint: .green)
                    }
                    ForEach(torrent.labels.prefix(2), id: \.self) { label in
                        glassBadge(label, tint: .orange)
                    }

                    Text(torrent.sizeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04), in: Capsule())

                    if let seeders = torrent.seeders {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(seeders)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                        }
                        .foregroundStyle(seeders >= 5 ? Color.green : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((seeders >= 5 ? Color.green : Color.primary).opacity(0.08), in: Capsule())
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func glassBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
    }
}
