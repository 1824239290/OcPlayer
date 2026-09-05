import BangumiKit
import CoreModel
import SwiftUI

/// 详情页内嵌的 Bangumi 章节区块。
///
/// - 未关联：显示「关联 Bangumi 条目」按钮（自动匹配 + 手动搜索）
/// - 已关联：显示章节网格（本篇 + SP 分区），单击标记，右键切其它状态
///
/// 标题与「剧集」等 section 同级（`.title3.weight(.bold)` + 同一组 padding），
/// 章节格子与进度页共用 `BangumiEpisodeCell`。
struct BangumiChapterSection: View {
    /// 当前详情页的 Jellyfin 条目。
    let item: MediaItem
    /// 当前选中的季（若当前为剧集且有选季）。
    var selectedSeason: MediaItem? = nil

    @Environment(AppModel.self) private var app
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(\.contentLeading) private var contentLeading

    @State private var linkedSubjectID: Int?
    @State private var subject: BangumiSubjectDTO?
    @State private var episodes: [BangumiEpisodeDTO] = []
    @State private var isLoading = false
    @State private var isMatching = false
    @State private var attemptedAutoMatchIDs: Set<String> = []
    @State private var showLinkPicker = false
    @State private var loadError: String?
    @State private var updatingEpisodeID: Int?
    @State private var loadToken = 0
    /// 本次读取的代次。actor 调用（`bangumi.context.…`）**不会**因为 task 被取消而抛，
    /// 所以光靠 `.task(id:)` 的取消挡不住旧任务继续往下写：重新关联条目
    /// （`loadToken += 1`）时若上一次 load 还在飞，旧条目的数据会压在新条目上面。
    /// 每个写回点都对一次代次——和 DetailView / LibraryView / BangumiHomeView 的做法一致。
    @State private var loadGeneration: UInt64 = 0

    /// 剧集关联有季优先挂季上；单季/电影挂自身或 series。
    private var linkItemID: MediaItem.ID {
        if let selectedSeason {
            return selectedSeason.id
        }
        return item.seriesID ?? item.id
    }

    private var mainEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type == .main } }
    private var spEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type == .sp } }
    private var otherEpisodes: [BangumiEpisodeDTO] {
        episodes.filter { $0.type != .main && $0.type != .sp }
    }

    var body: some View {
        // 没登录就整块不出现，别留一个空标题。
        if bangumi.isAuthenticated {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                sectionBody
            }
            .padding(.horizontal, contentLeading)
            .task(id: "\(linkItemID)-\(loadToken)-\(bangumi.isDatabaseReady)") { await load() }
            .onChange(of: app.detailRefreshGeneration) { _, _ in
                loadToken += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)) { note in
                // 播放结束的自动标记不经过本区块：AppModel 直接 PATCH 后写库再广播失效通知，
                // 而退出播放器触发的 detailRefreshGeneration 重载通常赶在标记落库之前，
                // 不监听这条通知，格子会一直停在旧的已看状态（进度页/条目详情页同款机制）。
                guard let noteSubjectID = (note.object as? NSNumber)?.intValue,
                      noteSubjectID == linkedSubjectID else { return }
                let generation = loadGeneration
                Task { await readLocal(noteSubjectID, generation: generation) }
            }
            .sheet(isPresented: $showLinkPicker) {
                BangumiLinkPicker(item: item, season: selectedSeason) { subjectID in
                    BangumiMatcher.setLinkedSubjectID(subjectID, forJellyfinItemID: linkItemID)
                    if selectedSeason == nil || selectedSeason?.seasonNumber == 1 {
                        let fallbackID = item.seriesID ?? item.id
                        if fallbackID != linkItemID {
                            BangumiMatcher.setLinkedSubjectID(subjectID, forJellyfinItemID: fallbackID)
                        }
                    }
                    linkedSubjectID = subjectID
                    subject = nil
                    episodes = []
                    loadToken += 1
                }
            }
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        if subject != nil {
            episodeContent
        } else if isLoading {
            ProgressView("正在加载 Bangumi 数据…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else if let loadError {
            BangumiNotice(message: loadError) { loadToken += 1 }
                .padding(.bottom, 4)
        } else {
            linkPrompt
        }
    }

    // MARK: - 区块头

    private var header: some View {
        HStack(spacing: 10) {
            Text("Bangumi")
                .font(.title3.weight(.bold))
            if let subject {
                NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                    HStack(spacing: 4) {
                        Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if subject != nil {
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    showLinkPicker = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("重新关联 Bangumi 条目")
                .accessibilityLabel("重新关联 Bangumi 条目")
            }
        }
    }

    // MARK: - 未关联提示

    private var linkPrompt: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("关联 Bangumi 条目")
                    .font(.callout.weight(.medium))
                Text("把这部作品连到 Bangumi，就能在这里标记章节进度、播放结束自动同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await autoMatch() }
            } label: {
                if isMatching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("自动匹配")
                }
            }
            .disabled(isMatching)
            Button("手动选择") { showLinkPicker = true }
                .disabled(isMatching)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    // MARK: - 已关联内容

    @ViewBuilder
    private var episodeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let loadError {
                BangumiNotice(message: loadError) { loadToken += 1 }
            }
            if !mainEpisodes.isEmpty {
                episodeGrid(mainEpisodes)
            }
            if !spEpisodes.isEmpty {
                Text("SP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                episodeGrid(spEpisodes)
            }
            if !otherEpisodes.isEmpty {
                Text("其他")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                episodeGrid(otherEpisodes)
            }
            if episodes.isEmpty, !isLoading {
                Text("该条目暂无章节")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
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

    // MARK: - 数据

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        guard bangumi.isAuthenticated, bangumi.isDatabaseReady else {
            linkedSubjectID = nil
            subject = nil
            episodes = []
            return
        }
        linkedSubjectID = BangumiMatcher.linkedSubjectID(forJellyfinItemID: linkItemID)
        if linkedSubjectID == nil && (selectedSeason == nil || selectedSeason?.seasonNumber == 1) {
            linkedSubjectID = BangumiMatcher.linkedSubjectID(forJellyfinItemID: item.seriesID ?? item.id)
        }

        // 首次打开未关联条目时，主动尝试一次静默自动匹配
        if linkedSubjectID == nil && !attemptedAutoMatchIDs.contains(linkItemID) {
            attemptedAutoMatchIDs.insert(linkItemID)
            isMatching = true
            defer { if loadGeneration == generation { isMatching = false } }
            if let matched = try? await BangumiMatcher.autoMatch(for: item, season: selectedSeason) {
                guard loadGeneration == generation else { return }
                BangumiMatcher.setLinkedSubjectID(matched.id, forJellyfinItemID: linkItemID)
                if selectedSeason == nil || selectedSeason?.seasonNumber == 1 {
                    let fallbackID = item.seriesID ?? item.id
                    if fallbackID != linkItemID {
                        BangumiMatcher.setLinkedSubjectID(matched.id, forJellyfinItemID: fallbackID)
                    }
                }
                linkedSubjectID = matched.id
            }
        }

        guard let subjectID = linkedSubjectID else {
            subject = nil
            episodes = []
            loadError = nil
            return
        }
        isLoading = true
        loadError = nil

        // 先渲染本地缓存，再补远端。
        await readLocal(subjectID, generation: generation)
        do {
            // 条目可能压根没被收藏过（关联是可以指向任意条目的），章节也可能还没拉过，
            // 这一步把两样都补齐；已经齐的不会发请求。
            try await bangumi.context.ensureSubjectLoaded(subjectID)
            guard loadGeneration == generation else { return }
            await readLocal(subjectID, generation: generation)
        } catch let e as BangumiError {
            guard loadGeneration == generation else { return }
            loadError = e.userMessage
            BangumiDiagnostics.log("加载 Bangumi 条目失败 subject=\(subjectID) error=\(e)")
        } catch {
            guard loadGeneration == generation else { return }
            loadError = "\(error)"
            BangumiDiagnostics.log("加载 Bangumi 条目失败 subject=\(subjectID) error=\(error)")
        }
    }

    /// 从本地库读条目与**全量**章节。
    /// 不能用进度窗口（`fetchProgressSubject`）：那个只返回本篇的一个滑动窗口，
    /// 会把 SP 和窗口外的集吃掉。
    private func readLocal(_ subjectID: Int, generation: UInt64) async {
        let cached = try? await bangumi.context.subject(id: subjectID)
        let cachedEpisodes = try? await bangumi.context.fetchEpisodes(subjectId: subjectID)
        guard loadGeneration == generation else { return }
        if let cached { subject = cached }
        if let cachedEpisodes { episodes = cachedEpisodes }
    }

    private func autoMatch() async {
        guard !isMatching else { return }
        isMatching = true
        loadError = nil
        defer { isMatching = false }
        do {
            guard let matched = try await BangumiMatcher.autoMatch(for: item, season: selectedSeason) else {
                loadError = "没找到匹配的 Bangumi 条目，试试手动选择"
                return
            }
            linkedSubjectID = matched.id
            loadToken += 1
        } catch let e as BangumiError {
            loadError = e.userMessage
            BangumiDiagnostics.log("自动匹配失败 item=\(item.id) error=\(e)")
        } catch {
            loadError = "\(error)"
            BangumiDiagnostics.log("自动匹配失败 item=\(item.id) error=\(error)")
        }
    }

    private func perform(_ action: BangumiEpisodeAction, on episode: BangumiEpisodeDTO) async {
        guard let subjectID = linkedSubjectID, updatingEpisodeID == nil else { return }
        let generation = loadGeneration
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
            guard loadGeneration == generation else { return }
            loadError = nil
            await readLocal(subjectID, generation: generation)
        } catch let e as BangumiError {
            guard loadGeneration == generation else { return }
            loadError = e.userMessage
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(e)")
        } catch {
            guard loadGeneration == generation else { return }
            loadError = "\(error)"
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(error)")
        }
    }
}
