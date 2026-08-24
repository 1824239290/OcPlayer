import BangumiKit
import SwiftUI

/// Bangumi 每日放送（番剧时间表）页面。
///
/// 功能：
/// - 按星期一至星期日展示本季度正在放送的番剧时间表。
/// - 顶部星期切换器：自动识别并定位到「今天」，支持周一至周日及「全部」切换。
/// - 头部信息概览：当前年份与季度（如 2026年夏季番剧）、本周放送总数。
/// - 搜索与过滤：支持在每日放送中实时按日文名 / 中文名 / 简介（summary）搜索番剧。
/// - 条目卡片：海报封面、主标题、原名、放送时间、评分/排名、在看人数、本地收藏状态标识。
/// - 交互跳转：点击卡片直达番剧详情页（BangumiSubjectDetailView）。
/// - 数据加载：骨架屏加载、下拉刷新、异常重试、原站日历跳转。
struct BangumiCalendarView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.openURL) private var openURL

    @State private var days: [BangumiCalendarDayDTO] = []
    @State private var selectedWeekdayID: Int = todayBangumiWeekdayID
    @State private var showAllDays = false
    @State private var searchKeyword = ""
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var localInterests: [Int: BangumiCollectionType] = [:]
    @State private var loadGeneration: UInt64 = 0

    /// 全部天数选项的标识值
    private static let allDaysSelectionID = 0

    /// 当前星期对应的 Bangumi Weekday ID（1=周一 ... 7=周日）
    private static var todayBangumiWeekdayID: Int {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return weekday == 1 ? 7 : (weekday - 1)
    }

    /// 当前季度标签（如：2026年夏季番剧）
    private static var currentSeasonLabel: String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())
        let season: String
        switch month {
        case 1...3: season = "冬季"
        case 4...6: season = "春季"
        case 7...9: season = "夏季"
        default: season = "秋季"
        }
        return "\(year)年\(season)番剧"
    }

    /// 放送中的总条目数
    private var totalItemsCount: Int {
        days.reduce(0) { $0 + $1.items.count }
    }

    /// 搜索过滤后的天数数据
    private var filteredDays: [BangumiCalendarDayDTO] {
        let trimmed = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return days }
        return days.compactMap { day in
            let matched = day.items.filter { item in
                item.name.lowercased().contains(trimmed) ||
                item.nameCN.lowercased().contains(trimmed) ||
                (item.summary?.lowercased().contains(trimmed) ?? false)
            }
            guard !matched.isEmpty else { return nil }
            return BangumiCalendarDayDTO(weekday: day.weekday, items: matched)
        }
    }

    /// 当前选中展示的分组
    private var displayDays: [BangumiCalendarDayDTO] {
        if showAllDays || !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filteredDays
        }
        return filteredDays.filter { $0.weekday.id == selectedWeekdayID }
    }

    var body: some View {
        Group {
            if isLoading && days.isEmpty {
                skeletonView
            } else if let loadError, days.isEmpty {
                ContentUnavailableView {
                    Label(UIStrings.loadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(UIStrings.retry) { Task { await loadCalendar() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if days.isEmpty {
                ContentUnavailableView {
                    Label("暂无放送数据", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("未能获取到本季度的每日放送时间表。")
                } actions: {
                    Button("刷新") { Task { await loadCalendar(force: true) } }
                }
            } else {
                contentView
            }
        }
        .searchable(text: $searchKeyword, prompt: "在每日放送中搜索番剧")
        .navigationTitle("每日放送")
        #if os(macOS)
        .navigationSubtitle(subtitleText)
        #endif
        .toolbar { toolbar }
        .task { await loadCalendar() }
        .onReceive(NotificationCenter.default.publisher(for: BangumiProgressInvalidation.notificationName)) { _ in
            Task { await reloadLocalInterests() }
        }
    }

    // MARK: - 主内容

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if searchKeyword.isEmpty {
                    weekdaySelector
                        .padding(.horizontal, contentLeading)
                        .padding(.top, 8)
                }

                if displayDays.isEmpty {
                    ContentUnavailableView {
                        Label("未找到相关番剧", systemImage: "magnifyingglass")
                    } description: {
                        Text(searchKeyword.isEmpty ? "该星期暂无番剧放送。" : "未找到与「\(searchKeyword)」相关的放送番剧。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(displayDays) { day in
                            daySection(day: day)
                        }
                    }
                    .padding(.horizontal, contentLeading)
                    .padding(.top, searchKeyword.isEmpty ? 4 : 12)
                    .padding(.bottom, 48)
                }
            }
        }
        .refreshable { await loadCalendar(force: true) }
    }

    private var subtitleText: String {
        if totalItemsCount > 0 {
            return "\(Self.currentSeasonLabel) · 本周共 \(totalItemsCount) 部放送中"
        }
        return Self.currentSeasonLabel
    }

    // MARK: - 星期选择器

    private var weekdaySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 今天快捷标签
                let todayID = Self.todayBangumiWeekdayID
                let todayCount = days.first(where: { $0.weekday.id == todayID })?.items.count ?? 0
                weekdayChip(
                    title: "今天",
                    badgeText: "\(todayCount)",
                    isSelected: !showAllDays && selectedWeekdayID == todayID,
                    isToday: true
                ) {
                    showAllDays = false
                    selectedWeekdayID = todayID
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                // 周一 ~ 周日
                ForEach(days) { day in
                    let isSelected = !showAllDays && selectedWeekdayID == day.weekday.id
                    let isToday = day.weekday.id == todayID
                    weekdayChip(
                        title: day.weekday.shortCN,
                        badgeText: "\(day.items.count)",
                        isSelected: isSelected,
                        isToday: isToday
                    ) {
                        showAllDays = false
                        selectedWeekdayID = day.weekday.id
                    }
                }

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                // 全部
                weekdayChip(
                    title: "全部",
                    badgeText: "\(totalItemsCount)",
                    isSelected: showAllDays,
                    isToday: false
                ) {
                    showAllDays = true
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func weekdayChip(
        title: String,
        badgeText: String,
        isSelected: Bool,
        isToday: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isToday && !isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }

                Text(title)
                    .font(.caption.weight(isSelected ? .bold : .medium))

                Text(badgeText)
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 单日分组区块

    @ViewBuilder
    private func daySection(day: BangumiCalendarDayDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showAllDays || !searchKeyword.isEmpty {
                HStack(spacing: 8) {
                    Text(day.weekday.cn)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    if day.weekday.id == Self.todayBangumiWeekdayID {
                        Text("今天")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }

                    Text("(\(day.items.count) 部)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.top, 4)
            }

            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(day.items) { item in
                    NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: item.id, initialSubject: item.toSlimSubject())) {
                        CalendarItemCard(
                            item: item,
                            localInterest: localInterests[item.id]
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 10)]
        #else
        [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 10)]
        #endif
    }

    // MARK: - 骨架屏

    private var skeletonView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部胶囊骨架
                HStack(spacing: 8) {
                    ForEach(0..<8, id: \.self) { _ in
                        SkeletonBlock(cornerRadius: 16)
                            .frame(width: 68, height: 32)
                    }
                }
                .padding(.horizontal, contentLeading)
                .padding(.top, 12)

                // 卡片骨架
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(0..<10, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonBlock(cornerRadius: 6)
                                .frame(width: 68, height: 96)
                            VStack(alignment: .leading, spacing: 8) {
                                SkeletonBlock(cornerRadius: 4).frame(width: 160, height: 16)
                                SkeletonBlock(cornerRadius: 4).frame(width: 110, height: 12)
                                SkeletonBlock(cornerRadius: 4).frame(width: 80, height: 12)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    }
                }
                .padding(.horizontal, contentLeading)
                .padding(.top, 8)
            }
        }
        .skeletonShimmer()
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let url = URL(string: "https://bgm.tv/calendar") {
                    openURL(url)
                }
            } label: {
                Image(systemName: "safari")
            }
            .help("在浏览器中打开 Bangumi 原站每日放送")
            .accessibilityLabel("在浏览器中打开")

            Button {
                Task { await loadCalendar(force: true) }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("刷新每日放送时间表")
            .accessibilityLabel("刷新时间表")
            .disabled(isRefreshing)
        }
    }

    // MARK: - 数据加载

    private func loadCalendar(force: Bool = false) async {
        if force {
            isRefreshing = true
        } else {
            isLoading = true
        }
        loadGeneration &+= 1
        let gen = loadGeneration
        loadError = nil
        defer {
            if loadGeneration == gen {
                isLoading = false
                isRefreshing = false
            }
        }

        do {
            let fetchedDays = try await BangumiCalendarService.getCalendar()
            guard loadGeneration == gen else { return }
            days = fetchedDays
            await reloadLocalInterests()
        } catch let e as BangumiError {
            guard loadGeneration == gen else { return }
            loadError = e.userMessage
            BangumiDiagnostics.log("加载每日放送失败 error=\(e)")
        } catch {
            guard loadGeneration == gen else { return }
            loadError = "加载每日放送失败：\(error.localizedDescription)"
            BangumiDiagnostics.log("加载每日放送失败 error=\(error)")
        }
    }

    private func reloadLocalInterests() async {
        guard bangumi.isAuthenticated, bangumi.isDatabaseReady else { return }
        let ids = Array(Set(days.flatMap { $0.items.map(\.id) }))
        guard !ids.isEmpty else {
            localInterests = [:]
            return
        }
        // 一条 IN 查询取回全部（原来逐条 await 上百次 DB 往返，刷新/翻页卡顿）。
        let stored = (try? await bangumi.context.subjects(ids: ids)) ?? [:]
        var interests: [Int: BangumiCollectionType] = [:]
        for (id, subject) in stored {
            if let interest = subject.interest, interest.type != .none {
                interests[id] = interest.type
            }
        }
        localInterests = interests
    }
}

// MARK: - 每日放送条目卡片

private struct CalendarItemCard: View {
    let item: BangumiCalendarItemDTO
    let localInterest: BangumiCollectionType?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 封面海报
            RemoteImage(url: item.coverURL, authHeader: nil, maxPixelSize: 300)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 68, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            // 信息列
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let interest = localInterest, interest != .none {
                        interestBadge(interest)
                    }
                }

                if let original = item.originalName {
                    Text(original)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                // 评分与排名
                HStack(spacing: 8) {
                    if let rating = item.rating, rating.score > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(String(format: "%.1f", rating.score))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary)
                        }

                        if rating.total > 0 {
                            Text("(\(rating.total)人)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let rank = item.rank, rank > 0 {
                        Text("#\(rank)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    }
                }

                // 放送日期与在看人数
                HStack(spacing: 8) {
                    if let airDate = item.airDate, !airDate.isEmpty {
                        Text(airDate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if item.doingCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "eyes")
                                .font(.system(size: 9))
                            Text("\(item.doingCount) 人在看")
                                .font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .background.secondary,
            in: RoundedRectangle(cornerRadius: Metrics.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private func interestBadge(_ interest: BangumiCollectionType) -> some View {
        Text(interest.description(.anime))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor(for: interest).opacity(0.16), in: Capsule())
            .foregroundStyle(badgeColor(for: interest))
    }

    private func badgeColor(for interest: BangumiCollectionType) -> Color {
        switch interest {
        case .doing: return .blue
        case .wish: return .purple
        case .collect: return .green
        case .onHold: return .orange
        case .dropped: return .gray
        case .none: return .secondary
        }
    }
}
