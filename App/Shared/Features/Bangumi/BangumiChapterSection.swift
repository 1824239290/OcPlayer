import BangumiKit
import CoreModel
import SwiftUI

/// 详情页内嵌的 Bangumi 章节区块。
///
/// - 未关联：显示「关联 Bangumi 条目」按钮（自动匹配 + 手动搜索）。
/// - 已关联：显示章节网格（本篇 + SP 分区），点击标记已看。
struct BangumiChapterSection: View {
    /// 当前详情页的 Jellyfin 条目。
    let item: MediaItem

    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app

    @State private var linkedSubjectID: Int?
    @State private var subject: BangumiSubjectDTO?
    @State private var episodes: [BangumiEpisodeDTO] = []
    @State private var isLoading = false
    @State private var isMatching = false
    @State private var showLinkPicker = false
    @State private var loadToken = 0

    /// 剧集关联挂在 series 上；电影挂自己。
    private var linkItemID: MediaItem.ID {
        item.seriesID ?? item.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let subject {
                content(for: subject)
            } else if isLoading {
                ProgressView("正在加载 Bangumi 数据…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if bangumi.isAuthenticated {
                linkPrompt
            }
        }
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.vertical, 20)
        .task(id: "\(item.id)-\(loadToken)") { await load() }
        .sheet(isPresented: $showLinkPicker) {
            BangumiLinkPicker(item: item) { subjectID in
                BangumiMatcher.setLinkedSubjectID(subjectID, forJellyfinItemID: linkItemID)
                linkedSubjectID = subjectID
                subject = nil
                loadToken += 1
            }
        }
    }

    // MARK: - 区块头

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bangumi")
                .font(.headline)
            if let subject {
                Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if subject != nil {
                Button {
                    showLinkPicker = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("重新关联 Bangumi 条目")
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
            Spacer()
            Button {
                Task { await autoMatch() }
            } label: {
                if isMatching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("自动匹配")
                }
            }
            .disabled(isMatching || !bangumi.isAuthenticated)
            Button("手动选择") { showLinkPicker = true }
                .disabled(!bangumi.isAuthenticated)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 已关联内容

    @ViewBuilder
    private func content(for subject: BangumiSubjectDTO) -> some View {
        let mainEpisodes = episodes.filter { $0.type == .main }
        let spEpisodes = episodes.filter { $0.type == .sp }
        let others = episodes.filter { $0.type != .main && $0.type != .sp }

        VStack(alignment: .leading, spacing: 8) {
            if !mainEpisodes.isEmpty {
                episodeGrid(mainEpisodes)
            } else if !others.isEmpty {
                episodeGrid(others)
            } else if episodes.isEmpty {
                Text("该条目暂无章节")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
            if !spEpisodes.isEmpty {
                Label("SP", systemImage: "star")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                episodeGrid(spEpisodes)
            }
        }
    }

    private func episodeGrid(_ list: [BangumiEpisodeDTO]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 34), spacing: 6)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(list) { episode in
                ChapterBadge(episode: episode) {
                    Task { await markWatched(episode) }
                }
            }
        }
    }

    // MARK: - 数据

    private func load() async {
        guard bangumi.isAuthenticated else {
            linkedSubjectID = nil
            subject = nil
            episodes = []
            return
        }
        linkedSubjectID = BangumiMatcher.linkedSubjectID(forJellyfinItemID: linkItemID)
        guard let subjectID = linkedSubjectID else {
            subject = nil
            episodes = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        // 先读本地缓存立即渲染。
        if let cached = try? await bangumi.context.subject(id: subjectID) {
            subject = cached
        }
        if let cachedEpisodes = try? await bangumi.context.fetchEpisodes(subjectId: subjectID) {
            episodes = cachedEpisodes
        }
        // 远程拉全量章节落库（关联后第一次会拉，缓存过则跳过请求）。
        if let fresh = try? await bangumi.context.fetchProgressSubject(subjectId: subjectID, episodeWindowSize: 100) {
            subject = fresh.subject
            episodes = fresh.episodes
        }
        // 确保全量章节已落库（fetchProgressSubject 只是窗口，远程全量靠 loadEpisodes）。
        if episodes.isEmpty {
            try? await bangumi.context.loadEpisodes(subjectID)
            episodes = (try? await bangumi.context.fetchEpisodes(subjectId: subjectID)) ?? []
        }
    }

    private func autoMatch() async {
        guard !isMatching else { return }
        isMatching = true
        defer { isMatching = false }
        if let matched = try? await BangumiMatcher.autoMatch(for: item) {
            linkedSubjectID = matched.id
            loadToken += 1
        }
    }

    private func markWatched(_ episode: BangumiEpisodeDTO) async {
        guard episode.collectionTypeEnum != .collect else { return }
        do {
            try await bangumi.context.updateEpisodeCollection(
                episodeId: episode.id, type: .collect)
            loadToken += 1
        } catch {
            // 失败静默，诊断日志留痕。
        }
    }
}

/// 章节网格的单格。
private struct ChapterBadge: View {
    let episode: BangumiEpisodeDTO
    var onTap: () async -> Void

    var body: some View {
        Button(action: { Task { await onTap() } }) {
            Text(episode.sortDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border))
        }
        .buttonStyle(.plain)
        .disabled(!episode.aired || episode.collectionTypeEnum == .collect)
        .help("EP.\(episode.sortDisplay) \(episode.nameCN.isEmpty ? episode.name : episode.nameCN)")
    }

    private var foreground: Color {
        if !episode.aired { return .secondary.opacity(0.5) }
        switch episode.collectionTypeEnum {
        case .collect: return .green
        case .dropped: return .secondary
        case .wish: return .pink
        case .none: return .primary
        }
    }

    private var background: Color {
        if !episode.aired { return .secondary.opacity(0.15) }
        switch episode.collectionTypeEnum {
        case .collect: return .green.opacity(0.15)
        case .dropped: return .secondary.opacity(0.15)
        case .wish: return .pink.opacity(0.12)
        case .none: return .secondary.opacity(0.2)
        }
    }

    private var border: Color {
        episode.collectionTypeEnum == .collect ? .green.opacity(0.5) : .secondary.opacity(0.25)
    }
}
