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

    @Environment(BangumiCoordinator.self) private var bangumi

    @State private var linkedSubjectID: Int?
    @State private var subject: BangumiSubjectDTO?
    @State private var episodes: [BangumiEpisodeDTO] = []
    @State private var isLoading = false
    @State private var isMatching = false
    @State private var showLinkPicker = false
    @State private var loadError: String?
    @State private var updatingEpisodeID: Int?
    @State private var loadToken = 0

    /// 剧集关联挂在 series 上；电影挂自己。
    private var linkItemID: MediaItem.ID {
        item.seriesID ?? item.id
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
            .padding(.horizontal, Metrics.contentLeading)
            .task(id: "\(item.id)-\(loadToken)-\(bangumi.isDatabaseReady)") { await load() }
            .sheet(isPresented: $showLinkPicker) {
                BangumiLinkPicker(item: item) { subjectID in
                    BangumiMatcher.setLinkedSubjectID(subjectID, forJellyfinItemID: linkItemID)
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
                Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        guard bangumi.isAuthenticated, bangumi.isDatabaseReady else {
            linkedSubjectID = nil
            subject = nil
            episodes = []
            return
        }
        linkedSubjectID = BangumiMatcher.linkedSubjectID(forJellyfinItemID: linkItemID)
        guard let subjectID = linkedSubjectID else {
            subject = nil
            episodes = []
            loadError = nil
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // 先渲染本地缓存，再补远端。
        await readLocal(subjectID)
        do {
            // 条目可能压根没被收藏过（关联是可以指向任意条目的），章节也可能还没拉过，
            // 这一步把两样都补齐；已经齐的不会发请求。
            try await bangumi.context.ensureSubjectLoaded(subjectID)
            await readLocal(subjectID)
        } catch let e as BangumiError {
            loadError = e.userMessage
            BangumiDiagnostics.log("加载 Bangumi 条目失败 subject=\(subjectID) error=\(e)")
        } catch {
            loadError = "\(error)"
            BangumiDiagnostics.log("加载 Bangumi 条目失败 subject=\(subjectID) error=\(error)")
        }
    }

    /// 从本地库读条目与**全量**章节。
    /// 不能用进度窗口（`fetchProgressSubject`）：那个只返回本篇的一个滑动窗口，
    /// 会把 SP 和窗口外的集吃掉。
    private func readLocal(_ subjectID: Int) async {
        if let cached = try? await bangumi.context.subject(id: subjectID) {
            subject = cached
        }
        if let cachedEpisodes = try? await bangumi.context.fetchEpisodes(subjectId: subjectID) {
            episodes = cachedEpisodes
        }
    }

    private func autoMatch() async {
        guard !isMatching else { return }
        isMatching = true
        loadError = nil
        defer { isMatching = false }
        do {
            guard let matched = try await BangumiMatcher.autoMatch(for: item) else {
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
            loadError = nil
            await readLocal(subjectID)
        } catch let e as BangumiError {
            loadError = e.userMessage
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(e)")
        } catch {
            loadError = "\(error)"
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(error)")
        }
    }
}
