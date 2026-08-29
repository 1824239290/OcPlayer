import MoviePilotKit
import SwiftUI

/// 站点资源搜索页（复刻 MP 网页端「资源搜索」逻辑）：
/// 剧集只用来预填标题和回传 media_in——真正的搜索是**按标题**走
/// `/search/title`，可选站点；聚合结果自己挑。下载完成后由 MoviePilot
/// 服务端自动整理入库，这里不做任何入库追踪。
struct MoviePilotResourceView: View {
    @Environment(AppModel.self) private var app

    /// 媒体上下文：标题预填 + 下载时 media_in 回传。
    let media: MPMediaInfo

    @State private var keyword: String
    @State private var sites: [MPSite] = []
    @State private var sitesError: String?
    @State private var selectedSiteIDs: Set<Int> = []
    @State private var showSitePicker = false

    @State private var torrents: [MPTorrent] = []
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

    init(media: MPMediaInfo) {
        self.media = media
        _keyword = State(initialValue: media.title ?? "")
    }

    var body: some View {
        // 全量过滤+排序每次 body 只算一遍：displayedTorrents 在本页被引用 4 处
        // （空态判断 / ForEach / header 计数×2），直接内联会在流式期间一遍事件排 4 次序。
        let displayed = displayedTorrents
        return List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 4)
                searchControls
                    .listRowBackground(Color.clear)
            }

            if !torrents.isEmpty || filters.isActive {
                filterBar
                    .listRowBackground(Color.clear)
            }

            Section {
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progressText ?? "正在搜索各站点资源…")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                            if !torrents.isEmpty {
                                Text("已收到 \(torrents.count) 条，边搜边出——可以直接挑")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption)
                            }
                        }
                    }
                } else if let searchError {
                    Text(searchError)
                        .foregroundStyle(.red)
                        .font(.callout)
                    Button(UIStrings.retry) { search() }
                } else if displayed.isEmpty {
                    Text(hasSearched
                         ? (filters.isActive
                            ? "筛掉了全部 \(torrents.count) 条结果，放宽条件试试。"
                            : "没有搜到资源。换个关键词（比如加 S02 / 第2季）、或调整站点再试。")
                         : "点击「搜索」开始；关键词已按剧名预填，可自行修改。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayed) { torrent in
                        torrentRow(torrent)
                    }
                }
            } header: {
                if !torrents.isEmpty || isSearching || searchError != nil {
                    if filters.isActive, displayed.count != torrents.count {
                        Text("资源 \(displayed.count) / \(torrents.count)")
                    } else {
                        Text("资源 \(torrents.count)")
                    }
                }
            }

            if let notice {
                Section {
                    Label(notice, systemImage: isNoticeError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isNoticeError ? .red : .green)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(media.title ?? "资源搜索")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadSites() }
        .refreshable { await search().value }
        .sheet(isPresented: $showSitePicker) {
            MoviePilotSitePickerSheet(sites: sites, selection: $selectedSiteIDs)
        }
        .sheet(isPresented: $showTorrentFilter) {
            MoviePilotTorrentFilterSheet(
                options: TorrentFilterEngine.options(torrents),
                filters: $filters
            )
        }
        .navigationDestination(isPresented: $navigateToDownloads) {
            MoviePilotDownloadsView()
        }
    }

    // MARK: - 筛选与排序

    private var sortField: TorrentSortField {
        TorrentSortField(rawValue: sortFieldRaw) ?? .defaultOrder
    }

    /// 筛选 + 排序后的展示列表（流式期间也持续应用）。
    private var displayedTorrents: [MPTorrent] {
        TorrentFilterEngine.sorted(
            TorrentFilterEngine.filtered(torrents, filters: filters),
            field: sortField,
            ascending: sortAscending
        )
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    showTorrentFilter = true
                } label: {
                    Label(
                        filters.isActive ? "筛选 · \(filters.activeCount)" : "筛选",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .font(.callout)
                }
                Spacer()
                Menu {
                    Picker("排序", selection: Binding(
                        get: { sortField },
                        set: { sortFieldRaw = $0.rawValue }
                    )) {
                        ForEach(TorrentSortField.allCases, id: \.self) { field in
                            Text(field.label).tag(field)
                        }
                    }
                } label: {
                    Label("排序 · \(sortField.label)", systemImage: "arrow.up.arrow.down")
                        .font(.callout)
                }
                .fixedSize()
                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(sortAscending ? "当前升序，点击切换降序" : "当前降序，点击切换升序")
            }
            if filters.isActive {
                HStack(spacing: 8) {
                    Text(filters.activeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("清除") {
                        filters = TorrentFilters()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            RemoteImage(url: media.posterURL, authHeader: nil, maxPixelSize: 300)
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title ?? "未知条目")
                    .font(.title3.weight(.semibold))
                Text(media.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let overview = media.overview {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - 搜索控件

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("搜索关键词", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit { search() }
                Button("搜索") { search() }
                    .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            Button {
                showSitePicker = true
            } label: {
                HStack(spacing: 6) {
                    Label(siteFilterText, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.callout)
                    Spacer()
                    if !sites.isEmpty {
                        Text("共 \(sites.count) 站")
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if let sitesError {
                Text(sitesError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var siteFilterText: String {
        selectedSiteIDs.isEmpty ? "全部站点" : "已选 \(selectedSiteIDs.count) 个站点"
    }

    // MARK: - 种子行

    private func torrentRow(_ torrent: MPTorrent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(torrent.title ?? "未命名资源")
                    .font(.callout)
                    .lineLimit(2)
                if let description = torrent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let site = torrent.siteName {
                        badge(site, tint: .blue)
                    }
                    if torrent.isFree {
                        badge("免费", tint: .green)
                    }
                    ForEach(torrent.labels.prefix(2), id: \.self) { label in
                        badge(label, tint: .orange)
                    }
                    Text(torrent.sizeText)
                    if let seeders = torrent.seeders {
                        Label("\(seeders)", systemImage: "arrow.up")
                            .foregroundStyle(seeders >= 5 ? .green : .secondary)
                    }
                    if let elapsed = torrent.dateElapsed ?? torrent.pubdate {
                        Text(elapsed)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                addDownload(torrent)
            } label: {
                if addingDownloadID == torrent.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("下载", systemImage: "arrow.down.circle")
                }
            }
            .disabled(addingDownloadID != nil)
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
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
                    progressText = progress.text
                case .failure(let message):
                    searchError = message
                }
            }
            // 消费端退出（被新一代取代/取消）时，把还在跑的旧 SSE 流一并停掉。
            producer.cancel()
            // 排序交给筛选栏的设置（displayedTorrents 持续应用），终态不再重排。
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
