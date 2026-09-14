import AppDesignKit
import BangumiKit
import SwiftUI

/// Bangumi 功能区首页 = 动画进度管理（在看条目 + 展开的章节网格）。
///
/// 与 OcPlayer 设计系统对齐：
/// - 卡片用 `.background.secondary` + `cardRadius` 圆角（同 PosterCard/StillCard）
/// - 间距用 `railSpacing` / `contentLeading`（同 HomeView）
/// - 进度条用共享 `CardProgressTrack`（原与 StillCard 各自一份）
/// - 章节格子是共用组件 `BangumiEpisodeCell`（单击标记，右键切其它状态）
/// - 搜索走 Bangumi 远程（不再本地筛选闪烁）
/// - 在播/搜索两套分页共用 `PagedListLoader`（代次守卫/追加去重收在包里）
struct BangumiHomeView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading

    /// 在播列表分页器。懒建一次；fetch 闭包读的 @State/@AppStorage 都是存储引用，
    /// 排序切换、登录态变化时读到的是当前值。
    @State private var progressLoader: PagedListLoader<BangumiProgressSubject>?
    /// 搜索结果分页器，同上。
    @State private var searchLoader: PagedListLoader<BangumiSlimSubjectDTO>?

    @State private var isRefreshing = false
    /// 标记章节等写操作的失败文案（以前这些错误是全静默的）。
    @State private var actionError: String?
    /// 已经自动触发过首次同步，避免反复重试。
    @State private var didAutoSync = false

    /// 一页的条数。首屏不再一次拉 100 条：每条要额外查一遍章节窗口，
    /// 100 条就是几千行章节 + 上千次 JSON 解码，全在一次 await 里做完。
    private static let pageSize = 30
    /// 章节窗口大小。进度卡要把整季的格子铺出来，所以给得比「窗口」这个词大。
    private static let episodeWindowSize = 50

    /// 排序偏好跨启动保留。
    @AppStorage(SettingsKeys.bangumiProgressSort) private var sortRaw = SortOption.collected.rawValue

    // 搜索：远程搜 Bangumi，支持分类筛选与分页
    @State private var searchKeyword = ""
    @State private var submittedSearchKeyword = ""
    @State private var searchTypeFilter: BangumiSubjectType = .none

    private enum SortOption: String, CaseIterable, Identifiable {
        case collected
        case air

        var id: String { rawValue }

        var title: String {
            switch self {
            case .collected: "按收藏时间"
            case .air: "按放送时间"
            }
        }

        var mode: BangumiProgressSortMode {
            switch self {
            case .collected: .collectedAt
            case .air: .airTime
            }
        }
    }

    private var sortOption: SortOption { SortOption(rawValue: sortRaw) ?? .collected }

    /// 数据加载的触发键：登录态、建库完成、排序变化都要重新取。
    private var loadKey: String {
        "\(bangumi.isAuthenticated)-\(bangumi.isDatabaseReady)-\(sortRaw)"
    }

    var body: some View {
        Group {
            if bangumi.isAuthenticated {
                if let error = bangumi.databaseError {
                    // 建库失败：给重试入口，不再是无尽占位 + 全功能静默失效。
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Bangumi 本地库初始化失败")
                            .font(.headline)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Button("重试") {
                            bangumi.retryDatabaseSetup()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            } else {
                BangumiLoginView()
                    .navigationTitle("Bangumi")
            }
        }
        .task(id: loadKey) { await loadIfReady() }
        .onReceive(NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)) { note in
            guard bangumi.isAuthenticated else { return }
            let mayChangeMembership = (note.userInfo?["mayChangeProgressMembership"] as? Bool) ?? false
            let subjectID = (note.object as? NSNumber)?.intValue
            if mayChangeMembership || subjectID == nil {
                Task { await progressLoader?.loadInitial() }
            } else if let subjectID {
                Task { await reloadSubject(subjectID) }
            }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        Group {
            if !submittedSearchKeyword.isEmpty {
                searchView
            } else {
                progressView
            }
        }
        .searchable(text: $searchKeyword, prompt: "搜索 Bangumi 条目")
        .onSubmit(of: .search) {
            let trimmed = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                exitSearchMode()
                return
            }
            submittedSearchKeyword = trimmed
            Task { await searchLoader?.loadInitial() }
        }
        .onChange(of: searchKeyword) { _, newValue in
            if newValue.isEmpty {
                exitSearchMode()
            }
        }
        .onChange(of: searchTypeFilter) { _, _ in
            let trimmed = submittedSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { await searchLoader?.loadInitial() }
        }
        .navigationTitle("Bangumi")
        #if os(macOS)
        .navigationSubtitle(progressSubtitle)
        #endif
        .toolbar { toolbar }
    }

    @ViewBuilder
    private var progressView: some View {
        if let loader = progressLoader {
            Group {
                if loader.isLoading && loader.items.isEmpty {
                    skeletonView
                } else if let error = loader.loadError, loader.items.isEmpty {
                    EmptyState(failure: error) {
                        Task { await loader.loadInitial() }
                    }
                } else if loader.items.isEmpty {
                    EmptyState(
                        empty: "暂无在看条目",
                        systemImage: "play.rectangle",
                        message: "在 Bangumi 上标记「在看」的动画会出现在这里。\n点右上角刷新同步你的收藏。",
                        actionTitle: "刷新"
                    ) {
                        Task { await refresh(force: true) }
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Metrics.railSpacing) {
                            if let actionError {
                                ErrorNotice(actionError)
                                    .padding(.bottom, 2)
                            }
                            ForEach(loader.items) { item in
                                ProgressCard(
                                    item: item,
                                    reload: { await reloadSubject(item.subject.id) },
                                    reportError: { actionError = $0 }
                                )
                            }
                            LoadMoreFooter(loader: loader)
                        }
                        .padding(.horizontal, contentLeading)
                        .padding(.top, 16)
                        .padding(.bottom, 48)
                    }
                    .refreshable { await refresh(force: false) }
                }
            }
        } else {
            skeletonView
        }
    }

    /// macOS 副标题：在看数或搜索结果数。
    private var progressSubtitle: String {
        if !submittedSearchKeyword.isEmpty {
            if searchLoader?.isLoading == true {
                return "正在搜索…"
            } else if let total = searchLoader?.totalCount, total > 0 {
                return "找到 \(total) 个条目"
            }
            return ""
        }
        guard let loader = progressLoader, let total = loader.totalCount, total > 0 else { return "" }
        if loader.items.count < total {
            return "在看 \(loader.items.count) / \(total)"
        }
        return "在看 \(total)"
    }

    @ViewBuilder
    private var searchView: some View {
        VStack(spacing: 0) {
            searchHeader

            if let loader = searchLoader {
                Group {
                    if loader.isLoading && loader.items.isEmpty {
                        searchSkeletonView
                    } else if let error = loader.loadError, loader.items.isEmpty {
                        ContentUnavailableView {
                            Label(UIStrings.searchFailed, systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            HStack(spacing: 12) {
                                Button(UIStrings.retry) {
                                    Task { await loader.loadInitial() }
                                }
                                .buttonStyle(.borderedProminent)

                                Button("返回在看") {
                                    exitSearchMode()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if loader.items.isEmpty {
                        ContentUnavailableView {
                            Label("未找到相关条目", systemImage: "magnifyingglass")
                        } description: {
                            Text("未找到与「\(submittedSearchKeyword)」相关的 \(searchTypeFilter.description) 条目。\n可以尝试缩短关键词或切换分类。")
                        } actions: {
                            Button("返回在看") {
                                exitSearchMode()
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(loader.items) { subject in
                                    NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id, initialSubject: subject)) {
                                        SearchResultRow(subject: subject)
                                    }
                                    .buttonStyle(.plain)
                                }
                                LoadMoreFooter(loader: loader)
                            }
                            .padding(.horizontal, contentLeading)
                            .padding(.top, 4)
                            .padding(.bottom, 48)
                        }
                    }
                }
            } else {
                searchSkeletonView
            }
        }
    }

    /// 退出搜索模式的统一清理（原先三处各抄一份，字段清单已经漂移）。
    private func exitSearchMode() {
        searchKeyword = ""
        submittedSearchKeyword = ""
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button {
                exitSearchMode()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("返回在看")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.tertiary, in: Capsule())
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("退出搜索并返回在看条目列表")

            Divider()
                .frame(height: 16)

            searchTypePicker
        }
        .padding(.horizontal, contentLeading)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var searchTypePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let types: [BangumiSubjectType] = [.none, .anime, .book, .game, .music, .real]
                ForEach(types) { type in
                    searchFilterChip(type: type)
                }
            }
        }
    }

    private func searchFilterChip(type: BangumiSubjectType) -> some View {
        let isSelected = searchTypeFilter == type
        return Button {
            guard searchTypeFilter != type else { return }
            // 搜索请求统一走 onChange(of: searchTypeFilter)；这里再起 Task 会
            // 和它各搜一份（且用的是未提交的 searchKeyword），双份请求互竞代次。
            searchTypeFilter = type
        } label: {
            HStack(spacing: 5) {
                if type != .none {
                    Image(systemName: type.icon)
                        .font(.system(size: 10))
                }
                Text(type.description)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var searchSkeletonView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 14) {
                        SkeletonBlock(cornerRadius: 8)
                            .frame(width: 58, height: 84)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(cornerRadius: 4).frame(width: 180, height: 16)
                            SkeletonBlock(cornerRadius: 4).frame(width: 120, height: 12)
                            SkeletonBlock(cornerRadius: 4).frame(width: 90, height: 12)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, 4)
        }
        .skeletonShimmer()
    }

    @ViewBuilder
    private var skeletonView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.railSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            SkeletonBlock().frame(width: 56, height: 84)
                            VStack(alignment: .leading, spacing: 6) {
                                SkeletonBlock(cornerRadius: 4).frame(width: 180, height: 16)
                                SkeletonBlock(cornerRadius: 4).frame(width: 120, height: 12)
                            }
                            Spacer()
                        }
                        LazyVGrid(columns: BangumiEpisodeCell.columns, alignment: .leading, spacing: 6) {
                            ForEach(0..<8, id: \.self) { _ in
                                SkeletonBlock(cornerRadius: 6).frame(height: 32)
                            }
                        }
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, 16)
        }
        .skeletonShimmer()
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !bangumi.isDatabaseReady {
                ProgressView().controlSize(.small)
            }
            Button {
                app.path.append(.bangumiCalendar)
            } label: {
                Image(systemName: "calendar")
            }
            .help("每日放送：查看本季度番剧时间表")
            .accessibilityLabel("每日放送")

            Menu {
                Picker("排序", selection: $sortRaw) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("排序方式：\(sortOption.title)")
            .accessibilityLabel("排序方式")
            .accessibilityValue(sortOption.title)

            Button {
                app.path.append(.bangumiProfile)
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .help("个人主页")
            .accessibilityLabel("个人主页")

            Button {
                Task { await refresh(force: true) }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("刷新所有收藏")
            .accessibilityLabel("刷新所有收藏")
            .disabled(isRefreshing || !bangumi.isDatabaseReady)
        }
    }

    // MARK: - 数据

    /// 登录 + 建库都就绪才读；首次（从未同步过）自动拉一次，省得让用户先点刷新。
    private func loadIfReady() async {
        guard bangumi.isAuthenticated, bangumi.isDatabaseReady else {
            return
        }
        if progressLoader == nil {
            progressLoader = makeProgressLoader()
        }
        if searchLoader == nil {
            searchLoader = makeSearchLoader()
        }
        // 打开这一页才校验登录态（App 启动时不发请求）。
        bangumi.revalidateSessionIfNeeded()
        await progressLoader?.loadInitial()
        guard !didAutoSync, progressLoader?.items.isEmpty == true,
              bangumi.context.store.collectionsUpdatedAt == 0
        else { return }
        didAutoSync = true
        await refresh(force: false)
    }

    private func makeProgressLoader() -> PagedListLoader<BangumiProgressSubject> {
        PagedListLoader(pageSize: Self.pageSize) { offset, limit in
            let page = try await bangumi.context.fetchProgressSubjects(
                tab: .anime, sortMode: sortOption.mode, search: "",
                episodeWindowSize: Self.episodeWindowSize,
                limit: limit, offset: offset)
            return .init(items: page.data, total: page.total)
        } errorMessage: { error in
            BangumiDiagnostics.log("进度页加载失败 error=\(error)")
            return (error as? BangumiError)?.userMessage ?? "\(error)"
        }
    }

    private func makeSearchLoader() -> PagedListLoader<BangumiSlimSubjectDTO> {
        PagedListLoader(pageSize: 30) { offset, limit in
            let trimmed = submittedSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let filter = searchTypeFilter == .none ? nil : searchTypeFilter
            let page = try await BangumiSubjectService.search(
                keyword: trimmed,
                filter: filter,
                limit: limit,
                offset: offset
            )
            return .init(items: page.data, total: page.total)
        } errorMessage: { error in
            BangumiDiagnostics.log("搜索条目失败 error=\(error)")
            return (error as? BangumiError)?.userMessage ?? "搜索失败：\(error.localizedDescription)"
        } isCancellation: { error in
            // 请求被新输入取消 / 旧条件作废：不是错误，不占错误位。
            if error is CancellationError { return true }
            if let e = error as? BangumiError, case .ignore = e { return true }
            return (error as NSError).code == NSURLErrorCancelled
        }
    }

    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await bangumi.refreshCollections(force: force)
            actionError = nil
            await progressLoader?.loadInitial()
        } catch let e as BangumiError {
            progressLoader?.reportError(e.userMessage)
            actionError = e.userMessage
            BangumiDiagnostics.log("同步收藏失败 error=\(e)")
        } catch {
            progressLoader?.reportError("\(error)")
            actionError = "\(error)"
            BangumiDiagnostics.log("同步收藏失败 error=\(error)")
        }
    }

    private func reloadSubject(_ subjectID: Int) async {
        if let updated = try? await bangumi.context.fetchProgressSubject(
            subjectId: subjectID, episodeWindowSize: Self.episodeWindowSize) {
            progressLoader?.replace(updated)
        } else {
            // 条目已离开「在看」状态，直接从列表移除
            progressLoader?.remove(id: subjectID)
        }
    }
}

// MARK: - 进度卡片

/// 单条「在看」动画：封面 + 标题 + 进度条 + 展开的章节网格。
private struct ProgressCard: View {
    let item: BangumiProgressSubject
    var reload: () async -> Void
    var reportError: (String?) -> Void

    @Environment(BangumiCoordinator.self) private var bangumi
    @State private var updatingEpisodeID: Int?
    @State private var updatingStatus = false

    private var subject: BangumiSubjectDTO { item.subject }

    /// 本篇 / SP 分组只算一次。`body` 会因为 `updatingEpisodeID` 变化重算，
    /// 而窗口最多 50 集——原来 `mainEpisodes` / `spEpisodes` 是 computed property，
    /// 一次 body 里各被读两遍（判空 + 传给网格），等于每次重算扫四遍数组。
    private var partitioned: (main: [BangumiEpisodeDTO], sp: [BangumiEpisodeDTO]) {
        var main: [BangumiEpisodeDTO] = []
        var sp: [BangumiEpisodeDTO] = []
        for episode in item.episodes {
            switch episode.type {
            case .main: main.append(episode)
            case .sp: sp.append(episode)
            default: break
            }
        }
        return (main, sp)
    }

    var body: some View {
        let episodes = partitioned
        return VStack(alignment: .leading, spacing: 10) {
            header
            if !episodes.main.isEmpty {
                episodeGrid(episodes.main)
            }
            if !episodes.sp.isEmpty {
                Text("SP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                episodeGrid(episodes.sp)
            }
            if !item.hasEpisodeData {
                // 章节还没同步下来：明确说出来，别让空网格看着像「没有剧集」。
                Text("章节尚未同步，下拉或点右上角刷新")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                MediaArtwork(
                    url: coverURL,
                    shape: .poster,
                    width: 56,
                    cornerRadius: 6,
                    maxPixelSize: 300
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if !subject.nameCN.isEmpty, subject.nameCN != subject.name {
                            Text(subject.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
                progressRow
            }
            // 条目（整季）状态放标题区右上角——放集级进度旁边会被误读成集操作。
            statusMenu
        }
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.progressText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                nextAction
            }
            if let fraction = item.progressFraction {
                CardProgressTrack(fraction: Double(fraction))
            }
        }
    }

    /// 条目（整季）收藏状态手动改：卡片右上角徽章式菜单，
    /// 想看/在看/看过/搁置/抛弃，当前状态打勾。切走「在看」后条目
    /// 离开进度列表（membership 失效）。
    private var statusMenu: some View {
        let current = subject.interest?.type ?? .none
        return Menu {
            ForEach(BangumiCollectionType.allTypes()) { type in
                Button {
                    Task { await setSubjectStatus(type) }
                } label: {
                    if type == current {
                        Label(Self.statusLabel(type), systemImage: "checkmark")
                    } else {
                        Text(Self.statusLabel(type))
                    }
                }
            }
        } label: {
            Text(Self.statusLabel(current))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .disabled(updatingStatus)
        .help("更改这部作品的收藏状态")
    }

    private static func statusLabel(_ type: BangumiCollectionType) -> String {
        // 复用 CollectionType.description 的文案源，不再两处各自维护。
        // description(nil) 对 .none 返回「全部」，这里要的是「未收藏」，单独兜。
        type == .none ? "未收藏" : type.description(nil)
    }

    private func setSubjectStatus(_ type: BangumiCollectionType) async {
        updatingStatus = true
        defer { updatingStatus = false }
        do {
            try await bangumi.context.updateSubjectCollection(
                subjectId: subject.id, type: type)
        } catch let e as BangumiError {
            reportError(e.userMessage)
            BangumiDiagnostics.log("手动改条目状态失败 subject=\(subject.id) error=\(e)")
        } catch {
            reportError("状态更新失败：\(error)")
            BangumiDiagnostics.log("手动改条目状态失败 subject=\(subject.id) error=\(error)")
        }
    }

    @ViewBuilder
    private var nextAction: some View {
        if let next = item.nextEpisode {
            Button {
                Task { await perform(.set(.collect), on: next) }
            } label: {
                Label("看完 \(next.sortDisplay)", systemImage: "checkmark.circle")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(!next.aired || updatingEpisodeID != nil)
            .help(next.aired ? "把 EP.\(next.sortDisplay) 标记为看过" : "EP.\(next.sortDisplay) 还没开播")
        } else if item.isFinished {
            Label("已看完", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if item.hasEpisodeData {
            // 有章节但没有「下一集」：剩下的都还没开播。
            Text("等待更新")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private func episodeGrid(_ list: [BangumiEpisodeDTO]) -> some View {
        LazyVGrid(columns: BangumiEpisodeCell.columns, alignment: .leading, spacing: 6) {
            ForEach(list) { episode in
                BangumiEpisodeCell(
                    episode: episode,
                    isBusy: updatingEpisodeID == episode.id
                ) { action in
                    await perform(action, on: episode)
                }
            }
        }
    }

    private func perform(_ action: BangumiEpisodeAction, on episode: BangumiEpisodeDTO) async {
        guard updatingEpisodeID == nil else { return }
        updatingEpisodeID = episode.id
        defer { updatingEpisodeID = nil }
        do {
            switch action {
            case .set(let type):
                try await bangumi.context.updateEpisodeCollection(
                    episodeId: episode.id, type: type)
            case .markUpTo:
                try await bangumi.context.updateEpisodeCollection(
                    episodeId: episode.id, type: .collect, batch: true)
            }
            reportError(nil)
            await reload()
        } catch let e as BangumiError {
            reportError(e.userMessage)
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(e)")
        } catch {
            reportError("\(error)")
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(error)")
        }
    }
}

// MARK: - 搜索结果行

private struct SearchResultRow: View {
    let subject: BangumiSlimSubjectDTO
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MediaArtwork(
                url: coverURL,
                shape: .poster,
                width: 58,
                cornerRadius: 8,
                maxPixelSize: 300,
                bordered: true,
                shadowed: true
            )

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if !subject.nameCN.isEmpty, subject.name != subject.nameCN {
                        Text(subject.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    PillChip(
                        subject.type.description,
                        role: .custom(BangumiStatusColor.subject(subject.type)),
                        outline: .stamp(cornerRadius: 4),
                        font: .system(size: 10).weight(.medium)
                    )

                    if let rating = subject.rating, rating.score > 0 {
                        RatingPill(
                            score: Double(rating.score),
                            rank: subject.rating?.rank,
                            tint: BangumiStatusColor.rating
                        )
                    }

                    if let interest = subject.interest, interest.type != .none {
                        PillChip(
                            interest.type.description(subject.type),
                            role: .accent,
                            font: .system(size: 10).weight(.medium)
                        )
                    }
                }

                if let info = subject.info, !info.isEmpty {
                    Text(info)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(12)
        .hoverRowHighlight(active: isHovered)
        .onHover { isHovered = $0 }
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
}
