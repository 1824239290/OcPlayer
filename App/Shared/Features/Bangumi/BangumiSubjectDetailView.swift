import BangumiKit
import CoreModel
import SwiftUI

/// Bangumi 条目（番剧/作品）详情页。
///
/// 功能：
/// - 头部概览：封面大图、中日文标题、条目分类与放送载体标签（TV/OVA/剧场版等）、开播日期、总话数、评分与全站排名。
/// - 收藏管理：支持切换收藏状态（想看/在看/看过/搁置/抛弃/未收藏），展示当前进度（已看 x/y 话）。
/// - 剧集选集与进度管理：本篇/SP/其他分节网格，支持单集标记（看过/未看）、右键/长按「看到此集」批量标记、想看/抛弃等。
/// - 故事简介：多行简介展示与展开/收起。
/// - 作品信息（Infobox）：制作阵容（监督、脚本、原作、动画制作公司、音乐、人物设定等）及官网链接。
/// - 标签（Tags）与全站收藏统计：展示热门标签及各状态收藏人数。
/// - 联动跳转：支持一键在 MoviePilot（找片）中按番名搜索下载资源；在浏览器中打开 Bangumi 原站。
struct BangumiSubjectDetailView: View {
    let subjectID: Int
    var initialSubject: BangumiSlimSubjectDTO? = nil

    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var subject: BangumiSubjectDTO?
    @State private var episodes: [BangumiEpisodeDTO] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var updatingStatus = false
    @State private var updatingRating = false
    @State private var updatingEpisodeID: Int?
    @State private var actionError: String?
    @State private var loadGeneration: UInt64 = 0
    @State private var showFullSummary = false
    @State private var selectedEpisodeTab: EpisodeTab = .main

    private var currentRating: Int { subject?.interest?.rate ?? 0 }

    private enum EpisodeTab: String, CaseIterable, Identifiable {
        case main = "本篇"
        case sp = "SP"
        case other = "其他"

        var id: String { rawValue }
    }

    private var mainEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type == .main } }
    private var spEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type == .sp } }
    private var otherEpisodes: [BangumiEpisodeDTO] { episodes.filter { $0.type != .main && $0.type != .sp } }

    private var displayedSubjectName: String {
        if let sub = subject {
            return sub.nameCN.isEmpty ? sub.name : sub.nameCN
        }
        if let initSub = initialSubject {
            return initSub.nameCN.isEmpty ? initSub.name : initSub.nameCN
        }
        return "条目详情"
    }

    private var originalSubjectName: String? {
        let name = subject?.name ?? initialSubject?.name
        let cn = subject?.nameCN ?? initialSubject?.nameCN
        guard let name, !name.isEmpty, name != cn else { return nil }
        return name
    }

    private var coverURL: URL? {
        let imageStr = subject?.images?.large ?? initialSubject?.images?.large
        guard let imageStr, !imageStr.isEmpty else { return nil }
        return URL(string: BangumiURL.imageURLString(from: imageStr))
    }

    private var rating: BangumiSubjectRating? {
        subject?.rating ?? initialSubject?.rating
    }

    private var currentInterestType: BangumiCollectionType {
        subject?.interest?.type ?? initialSubject?.interest?.type ?? .none
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let actionError {
                    BangumiNotice(message: actionError)
                        .padding(.horizontal, contentLeading)
                }

                headerBanner
                    .padding(.horizontal, contentLeading)

                if isLoading && subject == nil {
                    ProgressView("正在加载详情…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else if let loadError, subject == nil {
                    ContentUnavailableView {
                        Label(UIStrings.loadFailed, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(UIStrings.retry) { Task { await load() } }
                    }
                    .padding(.horizontal, contentLeading)
                } else {
                    summarySection
                        .padding(.horizontal, contentLeading)

                    if !episodes.isEmpty || (subject?.eps ?? 0) > 0 {
                        episodesSection
                            .padding(.horizontal, contentLeading)
                    }

                    if let infobox = subject?.infobox, !infobox.isEmpty {
                        infoboxSection(infobox)
                            .padding(.horizontal, contentLeading)
                    }

                    if let tags = subject?.tags, !tags.isEmpty {
                        tagsSection(tags)
                            .padding(.horizontal, contentLeading)
                    }

                    if let collection = subject?.collection, !collection.isEmpty {
                        collectionStatsSection(collection)
                            .padding(.horizontal, contentLeading)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        .navigationTitle(displayedSubjectName)
        #if os(macOS)
        .navigationSubtitle(originalSubjectName ?? "")
        #endif
        .toolbar { toolbar }
        .task(id: "\(subjectID)-\(bangumi.isAuthenticated)-\(bangumi.isDatabaseReady)") {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)) { note in
            let noteSubjectID = (note.object as? NSNumber)?.intValue
            if noteSubjectID == subjectID {
                Task { await readLocal() }
            }
        }
    }

    // MARK: - 头部区域

    private var headerBanner: some View {
        HStack(alignment: .top, spacing: 20) {
            // 海报封面
            RemoteImage(url: coverURL, authHeader: nil, maxPixelSize: 600)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 130, height: 195)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            // 信息列
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayedSubjectName)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if let original = originalSubjectName {
                        Text(original)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }

                // 标签属性徽章行
                HStack(spacing: 6) {
                    let type = subject?.type ?? initialSubject?.type ?? .none
                    if type != .none {
                        badgeView(text: type.description, icon: type.icon)
                    }
                    if let platform = subject?.platform, !platform.typeCN.isEmpty {
                        badgeView(text: platform.typeCN)
                    }
                    if let airdate = subject?.airtime.date, !airdate.isEmpty {
                        badgeView(text: airdate)
                    }
                    if let eps = subject?.eps, eps > 0 {
                        badgeView(text: "\(eps) 话")
                    }
                }

                // 评分与排名
                if let rating, rating.score > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                            Text(String(format: "%.1f", rating.score))
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                        }

                        if rating.rank > 0 {
                            Text("#\(rating.rank)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.orange)
                        }

                        if rating.total > 0 {
                            Text("(\(rating.total) 人评分)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 4)

                // 操作行：收藏状态 + 我的评分 + 找片
                HStack(spacing: 10) {
                    statusSelectorMenu

                    ratingMenu

                    if bangumi.isAuthenticated, let interest = subject?.interest, interest.type != .none {
                        if interest.epStatus > 0 {
                            Text("已看 \(interest.epStatus)/\(subject?.eps ?? 0) 话")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // MoviePilot 找片快捷入口
                    Button {
                        let query = subject?.nameCN.isEmpty == false ? (subject?.nameCN ?? "") : (subject?.name ?? "")
                        if !query.isEmpty {
                            app.selectedSection = .moviepilot
                        }
                    } label: {
                        Label("找片下载", systemImage: "arrow.down.circle")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .help("前往 MoviePilot 搜索本片资源")
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius + 4))
    }

    private func badgeView(text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .foregroundStyle(.secondary)
    }

    // MARK: - 收藏状态菜单

    private var statusSelectorMenu: some View {
        Menu {
            ForEach(BangumiCollectionType.allTypes()) { type in
                Button {
                    Task { await setSubjectStatus(type) }
                } label: {
                    if type == currentInterestType {
                        Label(type.description(subject?.type), systemImage: "checkmark")
                    } else {
                        Label(type.description(subject?.type), systemImage: type.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if updatingStatus {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: currentInterestType.icon)
                }
                Text(currentInterestType == .none ? "加入收藏" : currentInterestType.description(subject?.type))
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                currentInterestType == .none ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.tint.opacity(0.18)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    currentInterestType == .none ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.tint.opacity(0.4))
                )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(updatingStatus || !bangumi.isAuthenticated)
        .help(bangumi.isAuthenticated ? "更改收藏状态" : "请先登录 Bangumi")
    }

    // MARK: - 评分菜单

    private static let ratingLabels: [(score: Int, text: String)] = [
        (10, "(10) 超神作"),
        (9, "(9) 神作"),
        (8, "(8) 力荐"),
        (7, "(7) 推荐"),
        (6, "(6) 还行"),
        (5, "(5) 不过不失"),
        (4, "(4) 较差"),
        (3, "(3) 差"),
        (2, "(2) 很差"),
        (1, "(1) 不忍直视"),
    ]

    private var ratingMenu: some View {
        Menu {
            Section("我的评分") {
                ForEach(Self.ratingLabels, id: \.score) { item in
                    Button {
                        Task { await setRating(item.score) }
                    } label: {
                        if currentRating == item.score {
                            Label(item.text, systemImage: "checkmark")
                        } else {
                            Text(item.text)
                        }
                    }
                }
            }
            if currentRating > 0 {
                Divider()
                Button(role: .destructive) {
                    Task { await setRating(0) }
                } label: {
                    Label("撤销评分", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 5) {
                if updatingRating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: currentRating > 0 ? "star.fill" : "star")
                        .foregroundStyle(currentRating > 0 ? Color.orange : Color.secondary)
                }

                if currentRating > 0 {
                    Text("\(currentRating)分")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.orange)
                } else {
                    Text("评分")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                currentRating > 0 ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.fill.tertiary),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    currentRating > 0 ? AnyShapeStyle(Color.orange.opacity(0.35)) : AnyShapeStyle(Color.clear)
                )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(updatingRating || !bangumi.isAuthenticated)
        .help(bangumi.isAuthenticated ? "为本条目评分" : "请先登录 Bangumi")
    }

    // MARK: - 简介区域

    @ViewBuilder
    private var summarySection: some View {
        if let summary = subject?.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("剧情简介")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .lineLimit(showFullSummary ? nil : 4)
                        .textSelection(.enabled)

                    if summary.count > 160 {
                        Button(showFullSummary ? "收起简介" : "展开全文") {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                showFullSummary.toggle()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            }
        }
    }

    // MARK: - 章节选集区域

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("章节列表")
                    .font(.headline)

                if bangumi.isAuthenticated, let interest = subject?.interest, interest.type != .none {
                    Text("单击标记已看，右键/长按批量标记")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 分组 Tab 切换
                if !spEpisodes.isEmpty || !otherEpisodes.isEmpty {
                    Picker("章节分类", selection: $selectedEpisodeTab) {
                        Text("本篇 (\(mainEpisodes.count))").tag(EpisodeTab.main)
                        if !spEpisodes.isEmpty {
                            Text("SP (\(spEpisodes.count))").tag(EpisodeTab.sp)
                        }
                        if !otherEpisodes.isEmpty {
                            Text("其他 (\(otherEpisodes.count))").tag(EpisodeTab.other)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            let currentList: [BangumiEpisodeDTO] = {
                switch selectedEpisodeTab {
                case .main: return mainEpisodes
                case .sp: return spEpisodes
                case .other: return otherEpisodes
                }
            }()

            if currentList.isEmpty {
                if isLoading {
                    ProgressView("正在加载章节…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    Text("暂无此分类章节")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                }
            } else {
                LazyVGrid(columns: BangumiEpisodeCell.columns, alignment: .leading, spacing: 6) {
                    ForEach(currentList) { episode in
                        BangumiEpisodeCell(
                            episode: episode,
                            isBusy: updatingEpisodeID == episode.id
                        ) { action in
                            await performEpisodeAction(action, on: episode)
                        }
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            }
        }
    }

    // MARK: - Infobox 制作信息

    @ViewBuilder
    private func infoboxSection(_ infobox: [BangumiInfoboxItem]) -> some View {
        let validItems = infobox.filter { $0.hasValue }
        if !validItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("作品信息")
                    .font(.headline)

                EqualRowHeightGrid(minColumnWidth: 260, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(validItems.indices, id: \.self) { idx in
                        let item = validItems[idx]
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.key)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)

                            Text(item.displayValuesText)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - 标签区域

    private func tagsSection(_ tags: [BangumiTag]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("相关标签")
                .font(.headline)

            FlowLayout(spacing: 6) {
                ForEach(tags.prefix(20), id: \.name) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption)
                        if tag.count > 0 {
                            Text("\(tag.count)")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    // MARK: - 全站收藏统计

    private func collectionStatsSection(_ collection: BangumiSubjectCollection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("全站收藏概况")
                .font(.headline)

            HStack(spacing: 12) {
                statCard(title: "想看", count: collection.wish, color: .purple)
                statCard(title: "在看", count: collection.doing, color: .blue)
                statCard(title: "看过", count: collection.collect, color: .green)
                statCard(title: "搁置", count: collection.onHold, color: .orange)
                statCard(title: "抛弃", count: collection.dropped, color: .gray)
            }
        }
    }

    private func statCard(title: String, count: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let url = URL(string: "https://bgm.tv/subject/\(subjectID)") {
                    openURL(url)
                }
            } label: {
                Image(systemName: "safari")
            }
            .help("在浏览器中打开 Bangumi 原站条目")
            .accessibilityLabel("在浏览器中打开")
        }
    }

    // MARK: - 数据加载与操作

    private func load() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        defer { if loadGeneration == gen { isLoading = false } }

        // 1. 先读本地数据库
        await readLocal()

        // 2. 远端拉取完整条目
        do {
            var fetchedSubject = try await BangumiSubjectService.getSubject(subjectID)
            if bangumi.isAuthenticated {
                if let userInterest = try? await BangumiCollectionService.getSubjectCollection(subjectID) {
                    fetchedSubject.interest = userInterest
                }
            }
            guard loadGeneration == gen else { return }
            subject = fetchedSubject

            // 存入本地库
            if bangumi.isDatabaseReady {
                _ = try? await bangumi.context.database?.saveSubject(fetchedSubject)
            }

            // 3. 远端拉取章节列表并同步本地
            if bangumi.isDatabaseReady {
                try? await bangumi.context.ensureSubjectLoaded(subjectID, refreshEpisodes: true)
                await readLocal()
            } else {
                let epPage = try? await BangumiEpisodeService.getSubjectEpisodes(subjectID, limit: 100, offset: 0)
                if let epData = epPage?.data, loadGeneration == gen {
                    episodes = epData
                }
            }
        } catch let e as BangumiError {
            guard loadGeneration == gen else { return }
            loadError = e.userMessage
            BangumiDiagnostics.log("加载 Bangumi 详情失败 subject=\(subjectID) error=\(e)")
        } catch {
            guard loadGeneration == gen else { return }
            loadError = "\(error)"
            BangumiDiagnostics.log("加载 Bangumi 详情失败 subject=\(subjectID) error=\(error)")
        }
    }

    private func readLocal() async {
        guard bangumi.isDatabaseReady else { return }
        if let cached = try? await bangumi.context.subject(id: subjectID) {
            subject = cached
        }
        if let cachedEpisodes = try? await bangumi.context.fetchEpisodes(subjectId: subjectID) {
            episodes = cachedEpisodes
        }
    }

    private func setSubjectStatus(_ type: BangumiCollectionType) async {
        guard bangumi.isAuthenticated else { return }
        updatingStatus = true
        defer { updatingStatus = false }
        do {
            try await bangumi.context.updateSubjectCollection(subjectId: subjectID, type: type)
            actionError = nil
            await readLocal()
        } catch let e as BangumiError {
            actionError = e.userMessage
            BangumiDiagnostics.log("更新条目状态失败 subject=\(subjectID) error=\(e)")
        } catch {
            actionError = "状态更新失败：\(error)"
            BangumiDiagnostics.log("更新条目状态失败 subject=\(subjectID) error=\(error)")
        }
    }

    private func setRating(_ rate: Int) async {
        guard bangumi.isAuthenticated else { return }
        updatingRating = true
        defer { updatingRating = false }
        do {
            try await bangumi.context.updateSubjectRating(subjectId: subjectID, rate: rate)
            actionError = nil
            await readLocal()
        } catch let e as BangumiError {
            actionError = e.userMessage
            BangumiDiagnostics.log("更新条目评分失败 subject=\(subjectID) error=\(e)")
        } catch {
            actionError = "评分更新失败：\(error)"
            BangumiDiagnostics.log("更新条目评分失败 subject=\(subjectID) error=\(error)")
        }
    }

    private func performEpisodeAction(_ action: BangumiEpisodeAction, on episode: BangumiEpisodeDTO) async {
        guard bangumi.isAuthenticated, updatingEpisodeID == nil else { return }
        updatingEpisodeID = episode.id
        defer { updatingEpisodeID = nil }
        do {
            switch action {
            case .set(let type):
                try await bangumi.context.updateEpisodeCollection(episodeId: episode.id, type: type)
            case .markUpTo:
                try await bangumi.context.updateEpisodeCollection(episodeId: episode.id, type: .collect, batch: true)
            }
            actionError = nil
            await readLocal()
        } catch let e as BangumiError {
            actionError = e.userMessage
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(e)")
        } catch {
            actionError = "章节标记失败：\(error)"
            BangumiDiagnostics.log("标记章节失败 episode=\(episode.id) error=\(error)")
        }
    }
}

// MARK: - 辅助 FlowLayout 视图组件

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - 辅助 EqualRowHeightGrid 同行等高网格布局

private struct EqualRowHeightGrid: Layout {
    var minColumnWidth: CGFloat = 260
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 800
        let columns = max(1, Int((width + horizontalSpacing) / (minColumnWidth + horizontalSpacing)))
        let colWidth = max(0, (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns))

        var totalHeight: CGFloat = 0
        var rowMaxHeight: CGFloat = 0
        var currentCol = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            rowMaxHeight = max(rowMaxHeight, size.height)
            currentCol += 1
            if currentCol >= columns {
                totalHeight += rowMaxHeight + verticalSpacing
                rowMaxHeight = 0
                currentCol = 0
            }
        }
        if currentCol > 0 {
            totalHeight += rowMaxHeight
        } else if totalHeight > 0 {
            totalHeight -= verticalSpacing
        }

        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width
        let columns = max(1, Int((width + horizontalSpacing) / (minColumnWidth + horizontalSpacing)))
        let colWidth = max(0, (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns))

        // 1. 计算每行的最大高度
        var rowHeights: [CGFloat] = []
        var rowMaxHeight: CGFloat = 0
        var currentCol = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            rowMaxHeight = max(rowMaxHeight, size.height)
            currentCol += 1
            if currentCol >= columns {
                rowHeights.append(rowMaxHeight)
                rowMaxHeight = 0
                currentCol = 0
            }
        }
        if currentCol > 0 {
            rowHeights.append(rowMaxHeight)
        }

        // 2. 按行对齐摆放子视图，让同行所有卡片高度统一为该行最大高度
        var y = bounds.minY
        var rowIdx = 0
        currentCol = 0

        for subview in subviews {
            let rowH = rowIdx < rowHeights.count ? rowHeights[rowIdx] : 36
            let x = bounds.minX + CGFloat(currentCol) * (colWidth + horizontalSpacing)
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: colWidth, height: rowH)
            )
            currentCol += 1
            if currentCol >= columns {
                y += rowH + verticalSpacing
                rowIdx += 1
                currentCol = 0
            }
        }
    }
}
