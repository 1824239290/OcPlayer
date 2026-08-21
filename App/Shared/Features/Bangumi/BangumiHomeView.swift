import BangumiKit
import SwiftUI

/// Bangumi 功能区首页 = 进度管理（在看条目 + 近期章节窗口）。
/// 未登录时显示登录引导。
struct BangumiHomeView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: BangumiSubjectType = .none
    @State private var search = ""
    @State private var subjects: [BangumiProgressSubject] = []
    @State private var counts: [BangumiSubjectType: Int] = [:]
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var loadGeneration: UInt64 = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if bangumi.isAuthenticated {
                authenticatedBody
            } else {
                BangumiLoginView()
                    .navigationTitle("Bangumi")
            }
        }
        .onAppear {
            if bangumi.isAuthenticated {
                Task { await initialLoad() }
            }
        }
        .onChange(of: bangumi.isAuthenticated) { _, loggedIn in
            if loggedIn {
                Task { await initialLoad() }
            } else {
                subjects = []
                counts = [:]
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: BangumiAPIClient.authenticationRequiredNotification)
        ) { note in
            guard let generation = (note.object as? NSNumber)?.uint64Value else { return }
            Task { @MainActor in
                await BangumiAuthService.invalidateSession(
                    expectedCredentialGeneration: generation)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)
        ) { note in
            guard bangumi.isAuthenticated else { return }
            let mayChangeMembership = (note.userInfo?["mayChangeProgressMembership"] as? Bool) ?? false
            let subjectID = (note.object as? NSNumber)?.intValue
            if mayChangeMembership || subjectID == nil {
                Task { await reloadAll() }
            } else if let subjectID {
                Task { await reloadSubject(subjectID) }
            }
        }
    }

    // MARK: - 已登录主体

    private var authenticatedBody: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            content
        }
        .searchable(text: $search, prompt: "搜索正在观看的条目")
        .navigationTitle("Bangumi 进度")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !bangumi.isDatabaseReady {
                    ProgressView().controlSize(.small)
                }
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
                .disabled(isRefreshing || !bangumi.isDatabaseReady)
            }
        }
        .onChange(of: tab) { _, _ in
            Task { await load() }
        }
        .onChange(of: search) { _, _ in
            // 防抖：停止输入 300ms 后再查。
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private var tabPicker: some View {
        Picker("类型", selection: $tab) {
            ForEach(BangumiSubjectType.progressTypes) { type in
                Text(tabLabel(type)).tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    private func tabLabel(_ type: BangumiSubjectType) -> String {
        let count = counts[type, default: 0]
        return count == 0 ? type.description : "\(type.description)(\(count))"
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && subjects.isEmpty {
            ProgressView("正在加载进度…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, subjects.isEmpty {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("重试") { Task { await load() } }
            }
        } else if subjects.isEmpty {
            ContentUnavailableView {
                Label("暂无在看条目", systemImage: "play.rectangle")
            } description: {
                Text("在 Bangumi 上标记「在看」的条目会出现在这里。\n点右上角刷新同步你的收藏。")
            } actions: {
                Button("刷新") { Task { await refresh(force: true) } }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(subjects) { item in
                        ProgressRow(item: item, reload: { await reloadSubject(item.subject.id) })
                    }
                }
                .padding(20)
            }
            .refreshable { await refresh(force: false) }
        }
    }

    // MARK: - 数据

    private func initialLoad() async {
        counts = (try? await bangumi.context.fetchProgressCounts()) ?? [:]
        await load()
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        defer {
            if loadGeneration == generation { isLoading = false }
        }
        do {
            let page = try await bangumi.context.fetchProgressSubjects(
                tab: tab, search: search.trimmingCharacters(in: .whitespaces), limit: 100, offset: 0)
            guard loadGeneration == generation else { return }
            subjects = page.data
            counts = (try? await bangumi.context.fetchProgressCounts()) ?? counts
        } catch let error as BangumiError {
            guard loadGeneration == generation else { return }
            loadError = error.userMessage
        } catch {
            guard loadGeneration == generation else { return }
            loadError = "\(error)"
        }
    }

    private func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await bangumi.context.refreshAllCollections(force: force)
            await load()
        } catch let error as BangumiError {
            loadError = error.userMessage
        } catch {
            loadError = "\(error)"
        }
    }

    private func reloadAll() async {
        await load()
    }

    private func reloadSubject(_ subjectID: Int) async {
        if let updated = try? await bangumi.context.fetchProgressSubject(subjectId: subjectID),
           let idx = subjects.firstIndex(where: { $0.subject.id == subjectID }) {
            subjects[idx] = updated
        }
        counts = (try? await bangumi.context.fetchProgressCounts()) ?? counts
    }
}

/// 单条「在看」条目：封面 + 标题 + 近期章节窗口 + 下一集快进。
private struct ProgressRow: View {
    let item: BangumiProgressSubject
    var reload: () async -> Void

    @Environment(BangumiCoordinator.self) private var bangumi
    @State private var updatingEpisodeID: Int?

    private var subject: BangumiSubjectDTO { item.subject }
    private var episodes: [BangumiEpisodeDTO] { item.episodes }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                title
                episodeBadges
                progressAction
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var cover: some View {
        RemoteImage(url: coverURL, authHeader: nil)
            .aspectRatio(2 / 3, contentMode: .fill)
            .frame(width: 56, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                .font(.headline)
                .lineLimit(1)
            if subject.nameCN != subject.name, !subject.nameCN.isEmpty, !subject.name.isEmpty {
                Text(subject.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var episodeBadges: some View {
        HStack(spacing: 4) {
            ForEach(episodes) { episode in
                EpisodeBadge(episode: episode, subject: subject) {
                    await updateEpisode(episode, type: .collect)
                }
            }
        }
    }

    private var progressAction: some View {
        Button {
            if let next = nextEpisode {
                Task { await updateEpisode(next, type: .collect) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.progressText)
                Image(systemName: nextEpisode == nil ? "square.grid.2x2.fill" : "checkmark.circle")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(alignment: .leading) {
                progressFill
            }
            .background(.background.secondary)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .disabled(nextEpisode == nil || updatingEpisodeID != nil)
    }

    /// 下一条未看剧集（nil = 全看完）。
    private var nextEpisode: BangumiEpisodeDTO? {
        episodes.first { $0.collectionTypeEnum == .none }
    }

    private var progressFill: some View {
        GeometryReader { geo in
            if let fraction = item.progressFraction, fraction > 0 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
    }

    private func updateEpisode(_ episode: BangumiEpisodeDTO, type: BangumiEpisodeCollectionType) async {
        guard updatingEpisodeID == nil else { return }
        updatingEpisodeID = episode.id
        defer { updatingEpisodeID = nil }
        do {
            try await bangumi.context.updateEpisodeCollection(episodeId: episode.id, type: type)
            await reload()
        } catch {
            // 失败静默：下次交互会重试，错误留在诊断日志。
        }
    }
}

/// 单集徽章：集号色块，未开播灰显，已看打勾/划线。
private struct EpisodeBadge: View {
    let episode: BangumiEpisodeDTO
    let subject: BangumiSubjectDTO
    var onTap: () async -> Void

    var body: some View {
        Button(action: { Task { await onTap() } }) {
            Text(episode.sortDisplay)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border))
                .overlay(alignment: .topTrailing) {
                    if episode.collectionTypeEnum == .dropped {
                        Image(systemName: "trash")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(2)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!episode.aired || episode.collectionTypeEnum == .collect)
        .help(episodeHelp)
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

    private var episodeHelp: String {
        if !episode.aired { return "EP.\(episode.sortDisplay) 未开播" }
        let status = episode.collectionTypeEnum.description
        return "EP.\(episode.sortDisplay) · \(episode.nameCN.isEmpty ? episode.name : episode.nameCN)（\(status)）"
    }
}
