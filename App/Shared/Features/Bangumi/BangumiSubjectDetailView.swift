import AppDesignKit
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
/// - 联动跳转：支持一键在 MoviePilot 中按番名搜索下载资源；在浏览器中打开 Bangumi 原站。
struct BangumiSubjectDetailView: View {
    let subjectID: Int
    var initialSubject: BangumiSlimSubjectDTO? = nil

    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    /// MoviePilot 集成开关（设置页「启用 MoviePilot」，默认开）：
    /// 关闭时头部的「MoviePilot下载」快捷入口一并隐藏。
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true

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

    /// 三个分类一次扫完（`P2-09`）。
    ///
    /// 逻辑落在 `BangumiKit` 的 `Array<BangumiEpisodeDTO>.partitionedByEpisodeType()`，
    /// **连「tab → 列表」的映射一起**（`EpisodePartition.episodes(for:)`）——
    /// 视图只负责把 `selectedEpisodeTab` 传进去。这样映射本身有用例守着，
    /// 不会出现「点 SP 显示本篇」而测试全绿的情况。
    private var partitionedEpisodes: EpisodePartition {
        episodes.partitionedByEpisodeType()
    }

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

    /// 收藏状态胶囊的域色：想看紫 / 在看蓝 / 看过绿 / 搁置橙 / 抛弃灰，
    /// 与日历页、本页收藏统计格用的是同一套 `BangumiStatusColor.collection`。
    private var statusTint: Color {
        BangumiStatusColor.collection(currentInterestType)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.railSpacing) {
                if let actionError {
                    ErrorNotice(actionError)
                        .padding(.horizontal, contentLeading)
                }

                headerBanner
                    .padding(.horizontal, contentLeading)

                if isLoading && subject == nil {
                    ProgressView("正在加载详情…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else if let loadError, subject == nil {
                    EmptyState(failure: loadError) {
                        Task { await load() }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                coverArtwork

                // 信息列：标题 / 徽章 / 全站评分。
                VStack(alignment: .leading, spacing: 8) {
                    titleBlock
                    badgeRow
                    ratingSummary

                    // 常规宽度（macOS / iPad 全屏）信息列够宽，动作就留在信息列里、
                    // 靠底与封面下沿对齐；iPhone 紧凑宽度走封面下方的整宽动作区。
                    if sizeClass != .compact {
                        Spacer(minLength: 4)
                        wideActionRow
                    }
                }
            }

            if sizeClass == .compact {
                compactActionArea
            }
        }
        .padding(16)
        // 2026-10-22：与下载页同一套液态玻璃
        .liquidGlassCard()
    }

    /// 海报封面（iPhone 紧凑宽度略缩，给信息列留宽度）。
    private var coverArtwork: some View {
        RemoteImage(url: coverURL, authHeader: nil, maxPixelSize: 600)
            .aspectRatio(2 / 3, contentMode: .fill)
            .frame(width: sizeClass == .compact ? 100 : 130,
                   height: sizeClass == .compact ? 150 : 195)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    /// 标题区：中文主标题 + 原文副标题。
    private var titleBlock: some View {
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
    }

    /// 标签属性徽章行：iPhone 紧凑宽度下不换行会横向溢出，统一走 FlowLayout 自动换行。
    private var badgeRow: some View {
        FlowLayout(spacing: 6) {
            let type = subject?.type ?? initialSubject?.type ?? .none
            if type != .none {
                PillChip(type.description, systemImage: type.icon)
            }
            if let platform = subject?.platform, !platform.typeCN.isEmpty {
                PillChip(platform.typeCN)
            }
            if let airdate = subject?.airtime.date, !airdate.isEmpty {
                PillChip(airdate)
            }
            if let eps = subject?.eps, eps > 0 {
                PillChip("\(eps) 话")
            }
        }
    }

    /// 全站评分与排名。
    @ViewBuilder
    private var ratingSummary: some View {
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
    }

    /// 常规宽度（macOS / iPad）的动作行：收藏状态 + 我的评分 + 进度 + 下载，一行排开。
    ///
    /// 窗口偏窄时一行放不下（iPhone SE 横屏报 regular、macOS 拖窄 + 大字号），
    /// 进度退到第二行——胶囊依旧 fixedSize，失败模式是换行而不是截字或出界。
    private var wideActionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statusSelectorMenu()
                ratingMenu()
                watchProgressLabel
                Spacer(minLength: 8)
                if moviepilotEnabled {
                    moviePilotButton
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    statusSelectorMenu()
                    ratingMenu()
                    Spacer(minLength: 8)
                    if moviepilotEnabled {
                        moviePilotButton
                    }
                }
                watchProgressLabel
            }
        }
    }

    /// iPhone 紧凑宽度的动作区：**整条铺满卡片宽度**，放在封面/标题下方。
    ///
    /// 线上问题（2026-10-26 截图）：这两个胶囊原先和信息列里的「已看 x/y 话」挤同一行，
    /// 而那句文案还带着 `.frame(maxWidth: .infinity)`。iPhone 上信息列只剩约 200pt
    /// （卡片内宽 ≈ 326pt − 封面 100 − 间距 20），两个胶囊的本征宽度就要 ~190pt，
    /// 于是 HStack 按默认压缩顺序先把 `Text` 截成 0——屏幕上只剩「👁」「☆」两个图标
    /// 和压扁的箭头，用户完全看不出这两个框是什么。现在：
    /// 1. 动作区搬出信息列、铺满卡片（封面下方），可用宽度从 ~200pt 涨到 ~326pt；
    /// 2. 胶囊 `fixedSize`，任何宽度下都不允许压掉文案（见 `actionCapsule`）；
    /// 3. `ViewThatFits` 兜住大字号：一行放不下就把进度换行，再放不下就各占一行。
    ///
    /// 已知行为：三档是结构不同的分支，选中档变化会重建 `Menu` 实例——若恰有弹层
    /// 开着（现实触发链只有 `BangumiProgressInvalidation` → 进度文案变化这一条），
    /// 打开中的弹层会被连带关掉；业务状态都在父视图，不受影响。
    private var compactActionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                // ① 默认：两个胶囊 + 进度（靠右）
                HStack(spacing: 8) {
                    statusSelectorMenu()
                    ratingMenu()
                    Spacer(minLength: 8)
                    watchProgressLabel
                }

                // ② 大字号：进度降到第二行
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        statusSelectorMenu()
                        ratingMenu()
                    }
                    watchProgressLabel
                }

                // ③ 最终兜底（连换行都放不下，如 iPad 1/3 分栏 + 超大字号）：各占一行。
                // 胶囊在这里放行压缩——出省略号也好过画出玻璃卡边界。
                VStack(alignment: .leading, spacing: 8) {
                    statusSelectorMenu(compressible: true)
                    ratingMenu(compressible: true)
                    watchProgressLabel
                }
            }

            if moviepilotEnabled {
                moviePilotButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「已看 x/y 话」。
    ///
    /// 总数未知（连载中 `eps == 0`）时只报已看话数——之前直接除 `subject?.eps ?? 0`
    /// 会渲染出「已看 1/0 话」这种读不通的文案。
    @ViewBuilder
    private var watchProgressLabel: some View {
        if let watchProgressText {
            Text(watchProgressText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var watchProgressText: String? {
        guard bangumi.isAuthenticated,
              let interest = subject?.interest,
              interest.type != .none,
              interest.epStatus > 0
        else { return nil }
        let total = subject?.eps ?? 0
        return total > 0 ? "已看 \(interest.epStatus)/\(total) 话" : "已看 \(interest.epStatus) 话"
    }

    /// 动作胶囊（收藏状态 / 我的评分共用）：图标 + 文案 + 展开箭头。
    ///
    /// 默认 `.fixedSize` 钉住本征宽度：胶囊里是 `Text`，HStack 宽度不够时的默认
    /// 压缩顺序会先把文案截成 0（字号不变、只剩图标）——线上那张截图正是如此。
    /// 钉住之后，放不下由外层 `ViewThatFits` 换行兜底。`compressible` 只给「连换行
    /// 都放不下」的最终兜底档用：此时回到可压缩（出省略号），因为 fixedSize 在那
    /// 一档的失败模式是画出卡片边界，比截字更糟。
    private func actionCapsule<Content: View>(
        tint: Color,
        isActive: Bool,
        compressible: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            content()

            Image(systemName: menuChevronGlyph)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isActive ? AnyShapeStyle(tint.opacity(0.18)) : AnyShapeStyle(.fill.tertiary),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(isActive ? AnyShapeStyle(tint.opacity(0.4)) : AnyShapeStyle(.clear))
        )
        .contentShape(Capsule())
        .fixedSize(horizontal: !compressible, vertical: false)
    }

    /// 下拉箭头：iOS 用单个 `chevron.down`（系统菜单观感），macOS 保留双箭头
    /// （桌面端「上下都能收」的既有观感）。
    private var menuChevronGlyph: String {
        #if os(macOS)
        "chevron.up.chevron.down"
        #else
        "chevron.down"
        #endif
    }

    /// MoviePilot 下载快捷入口（集成停用时整块隐藏）。
    private var moviePilotButton: some View {
        Button {
            let query = subject?.nameCN.isEmpty == false ? (subject?.nameCN ?? "") : (subject?.name ?? "")
            if !query.isEmpty {
                app.pendingMoviePilotQuery = query
                app.switchSection(.moviepilot)
            }
        } label: {
            Label("MoviePilot下载", systemImage: "arrow.down.circle")
                .font(.callout.weight(.medium))
        }
        .buttonStyle(.bordered)
        .help("前往 MoviePilot 搜索本片资源")
    }

    // MARK: - 收藏状态菜单

    private func statusSelectorMenu(compressible: Bool = false) -> some View {
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
            actionCapsule(tint: statusTint, isActive: currentInterestType != .none, compressible: compressible) {
                // 保存中的转圈**叠在图标位上**，而不是把整条 label 换成转圈：
                // 收藏/评分都是真实网络往返（几百 ms ~ 2s），旧写法让胶囊从 ~94–126pt
                // 塌成 ~52pt，旁边的评分胶囊和进度文案跟着平移。`.opacity` 与 `.overlay`
                // 都不参与布局，宽度因此恒定——沿用 `PrimaryActionButton` 的
                // 「标签原地变形、尺寸不变」口径。
                Image(systemName: currentInterestType.icon)
                    .foregroundStyle(currentInterestType == .none ? Color.secondary : statusTint)
                    .opacity(updatingStatus ? 0 : 1)
                    .overlay {
                        if updatingStatus {
                            ProgressView().controlSize(.small)
                        }
                    }

                Text(currentInterestType == .none ? "加入收藏" : currentInterestType.description(subject?.type))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
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

    private func ratingMenu(compressible: Bool = false) -> some View {
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
            actionCapsule(tint: BangumiStatusColor.rating, isActive: currentRating > 0, compressible: compressible) {
                // 同收藏胶囊：转圈叠在星标位上，胶囊宽度不变（见上一条注释）。
                Image(systemName: currentRating > 0 ? "star.fill" : "star")
                    .foregroundStyle(currentRating > 0 ? BangumiStatusColor.rating : Color.secondary)
                    .opacity(updatingRating ? 0 : 1)
                    .overlay {
                        if updatingRating {
                            ProgressView().controlSize(.small)
                        }
                    }

                if currentRating > 0 {
                    Text("\(currentRating)分")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(BangumiStatusColor.rating)
                } else {
                    Text("评分")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
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
withAnimation(reduceMotion ? nil : Motion.standard) {
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
                // 2026-10-22：与下载页同一套液态玻璃
                .liquidGlassCard()
            }
        }
    }

    // MARK: - 章节选集区域

    private var episodesSection: some View {
        // 一次分区；后面所有读取都走 `parts` 的 API（`P2-09`）。
        // 「tab → 列表」的映射也在包里，用例断言得到（见 `EpisodePartitionTests`）。
        let parts = partitionedEpisodes
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("章节列表")
                    .font(.headline)

                if bangumi.isAuthenticated, let interest = subject?.interest, interest.type != .none,
                   sizeClass != .compact {
                    Text("单击标记已看，右键/长按批量标记")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                // 分组 Tab 切换
                if !parts.isEmpty(for: .sp) || !parts.isEmpty(for: .other) {
                    Picker("章节分类", selection: $selectedEpisodeTab) {
                        Text(EpisodeTab.main.title(count: parts.count(for: .main)))
                            .tag(EpisodeTab.main)
                        if !parts.isEmpty(for: .sp) {
                            Text(EpisodeTab.sp.title(count: parts.count(for: .sp)))
                                .tag(EpisodeTab.sp)
                        }
                        if !parts.isEmpty(for: .other) {
                            Text(EpisodeTab.other.title(count: parts.count(for: .other)))
                                .tag(EpisodeTab.other)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            let currentList = parts.episodes(for: selectedEpisodeTab)

            Group {
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
                    // 2026-10-22：与下载页同一套液态玻璃
                    .liquidGlassCard()
                }
            }
            .id(selectedEpisodeTab)
            .transition(.section)
            .motion(Motion.standard, value: selectedEpisodeTab)
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
                        // 2026-10-22：与下载页同一套液态玻璃
                        .liquidGlassCard(cornerRadius: Metrics.glassNestedRadius)
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

            // iPhone 紧凑宽度下 5 张卡挤一行过窄，改自适应网格自动换行
            let statColumns = [GridItem(.adaptive(minimum: 80), spacing: 8)]
            LazyVGrid(columns: statColumns, alignment: .leading, spacing: 8) {
                statCard(title: "想看", count: collection.wish, color: BangumiStatusColor.collection(.wish))
                statCard(title: "在看", count: collection.doing, color: BangumiStatusColor.collection(.doing))
                statCard(title: "看过", count: collection.collect, color: BangumiStatusColor.collection(.collect))
                statCard(title: "搁置", count: collection.onHold, color: BangumiStatusColor.collection(.onHold))
                statCard(title: "抛弃", count: collection.dropped, color: BangumiStatusColor.collection(.dropped))
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
        // 2026-10-22：与下载页同一套液态玻璃
        .liquidGlassCard(cornerRadius: Metrics.glassNestedRadius)
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
                // 只有真读到收藏态才覆盖：`.unknown`（读不到）保持本地，既不拿陈旧
                // 副本覆盖、也不当成「没收藏」——`p1/subjects/{id}` 本就不返回 interest。
                if case .collected(let userInterest) = await bangumi.context.lookupSubjectCollection(subjectID) {
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
        } catch {
            guard loadGeneration == gen else { return }
            loadError = BangumiActionPerformer.loadFailureMessage(
                "加载 Bangumi 详情失败 subject=\(subjectID)", error)
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
        await BangumiActionPerformer.run(
            "更新条目状态失败 subject=\(subjectID)",
            isBusy: updatingStatus,
            setBusy: { updatingStatus = $0 },
            operation: {
                try await bangumi.context.updateSubjectCollection(subjectId: subjectID, type: type)
            },
            onSuccess: {
                actionError = nil
                await readLocal()
            },
            onError: { actionError = $0 }
        )
    }

    private func setRating(_ rate: Int) async {
        guard bangumi.isAuthenticated else { return }
        await BangumiActionPerformer.run(
            "更新条目评分失败 subject=\(subjectID)",
            isBusy: updatingRating,
            setBusy: { updatingRating = $0 },
            operation: {
                try await bangumi.context.updateSubjectRating(subjectId: subjectID, rate: rate)
            },
            onSuccess: {
                actionError = nil
                await readLocal()
            },
            onError: { actionError = $0 }
        )
    }

    private func performEpisodeAction(_ action: BangumiEpisodeAction, on episode: BangumiEpisodeDTO) async {
        guard bangumi.isAuthenticated else { return }
        await BangumiActionPerformer.performEpisodeAction(
            action, on: episode, context: bangumi.context,
            isBusy: updatingEpisodeID != nil,
            setBusy: { updatingEpisodeID = $0 },
            onSuccess: {
                actionError = nil
                await readLocal()
            },
            onError: { actionError = $0 }
        )
    }
}
