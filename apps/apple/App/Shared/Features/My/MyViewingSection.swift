import AppDesignKit
import Charts
import CoreModel
import JellyfinKit
import SwiftUI

struct MyViewingSection: View {
    let history: ServerViewingHistory?
    var localRecords: [AppPlaybackRecord] = []
    var collectionTiles: [MyViewingCollectionTile] = []
    let isLoading: Bool
    let error: String?
    let sourceName: String
    let retry: () -> Void
    let showAll: () -> Void
    let openItem: (MediaItem) -> Void
    @State private var selectedDay: Date?
    @State private var monthOffset = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("观看记录").font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Text(sourceName).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试", action: retry).buttonStyle(.borderless)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            if history?.syncedAt != nil || !localRecords.isEmpty {
                let history = history ?? ServerViewingHistory(sourceID: localRecords.first { $0.sourceID != AppPlaybackHistoryStore.localSourceID }?.sourceID ?? AppPlaybackHistoryStore.localSourceID, recordedFrom: Date())
                let stats = MyViewingStatistics(history: history, localRecords: localRecords)
                let day = selectedDay ?? stats.today
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), alignment: .top)], alignment: .leading, spacing: 18) {
                    dayCard(stats, day: day)
                    heatmapCard(stats)
                }
                MyViewingSummaryLayout(prefersSingleColumn: dynamicTypeSize.isAccessibilitySize) {
                    if !collectionTiles.isEmpty {
                        MyViewingCollectionTiles(tiles: collectionTiles).viewingCardRole(.collections)
                    }
                    monthCard(stats).viewingCardRole(.month)
                    if stats.total.seconds > 0 { genreCard(stats).viewingCardRole(.genres) }
                    if !stats.genreTrends.isEmpty {
                        let trendLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        trendLayout {
                            ForEach(stats.genreTrends) { trend in MyViewingGenreTrendCard(trend: trend) }
                        }.viewingCardRole(.trends)
                    }
                }
                if !stats.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Button(action: showAll) {
                            HStack {
                                Text("最近观看").font(.headline)
                                Spacer()
                                Text("全部 \(stats.entries.count) 条").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }.buttonStyle(.plain)
                        ForEach(Array(stats.entries.sorted { $0.watchedAt > $1.watchedAt }.prefix(3))) { record in
                            Button { openItem(record.item) } label: {
                                MyViewingRecordRow(record: record)
                            }.buttonStyle(.plain).disabled(record.isLocalFile)
                        }
                    }
                    .padding(18).liquidGlassCard()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("App 实播按实际播放时间记录，未看完也计入时长。暂停、缓冲和跳转不计时；同一条目同一天优先采用 App 实播时间。电影／剧集数量按服务器已看状态统计。")
                    if let syncedAt = history.syncedAt {
                        Text("服务器记录按片长估算 · 从 \(history.recordedFrom.formatted(date: .numeric, time: .omitted)) 起同步 · 更新于 \(syncedAt.formatted(date: .omitted, time: .shortened))")
                    }
                    Text("App 实播记录保存在当前设备，从新版开始累积。")
                    if history.undatedItemCount > 0 {
                        Text("已扫描条目中，\(history.undatedItemCount) 条缺少观看日期，未计入统计。")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                if !collectionTiles.isEmpty {
                    MyViewingCollectionTiles(tiles: collectionTiles).frame(maxWidth: 480, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(isLoading ? "正在同步服务器观看记录…" : "服务器观看记录尚未同步")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).liquidGlassCard()
            }
        }
    }

    private func dayCard(_ stats: MyViewingStatistics, day: Date) -> some View {
        let totals = stats.totals(on: day)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(stats.calendar.isDateInToday(day) ? "今天" : "当天观看").font(.subheadline)
                Spacer()
                Text(day, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
            }
            duration(totals, size: 40)
            HStack(spacing: 22) {
                Label("已看 \(totals.movies) 部电影", systemImage: "film")
                Label("已看 \(totals.episodes) 集剧", systemImage: "tv")
            }.font(.subheadline).foregroundStyle(.secondary)
            if totals.playbackFragments > 0 {
                Text("另有 \(totals.playbackFragments) 条 App 播放片段")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if totals.movies + totals.episodes == 0 && totals.seconds == 0 {
                Text("当天没有已同步的观看记录")
                    .font(.caption).foregroundStyle(.secondary)
            } else if totals.unknownRuntime > 0 {
                Text("\(totals.unknownRuntime) 条缺少片长，未计入时长")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).liquidGlassCard()
        .accessibilityElement(children: .combine)
    }

    private func heatmapCard(_ stats: MyViewingStatistics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("观看活跃度").font(.subheadline)
                Spacer()
                Text("近 15 周").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(stats.heatmapWeeks, id: \.first?.date) { week in
                    VStack(spacing: 4) {
                        ForEach(week) { day in
                            Button { selectedDay = day.date } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(heatmapColor(day))
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        if stats.calendar.isDate(day.date, inSameDayAs: selectedDay ?? stats.today) {
                                            RoundedRectangle(cornerRadius: 3).stroke(.primary.opacity(0.7), lineWidth: 1)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(!day.isCovered)
                            .accessibilityLabel("\(day.date.formatted(date: .numeric, time: .omitted))，\(day.isCovered ? "\(day.totals.movies + day.totals.episodes + day.totals.playbackFragments) 条记录" : "未覆盖")")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text("点击日期查看当天统计")
                Spacer(minLength: 4)
                Text("少")
                ForEach(1...3, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(LaunchStyle.glow.opacity(Double(level) / 3))
                        .frame(width: 9, height: 9)
                }
                Text("多")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18).liquidGlassCard()
    }

    private func heatmapColor(_ day: MyViewingDay) -> Color {
        guard day.isCovered else { return .secondary.opacity(0.06) }
        let count = day.totals.movies + day.totals.episodes + day.totals.playbackFragments
        if count == 0 { return .secondary.opacity(0.18) }
        return LaunchStyle.glow.opacity(min(0.3 + Double(count) * 0.15, 1))
    }

    private func monthCard(_ stats: MyViewingStatistics) -> some View {
        let month = stats.calendar.date(byAdding: .month, value: monthOffset, to: stats.today) ?? stats.today
        let totals = MyViewingTotals(records: stats.records(inMonth: month))
        let days = stats.monthDays(month)
        let monthStart = stats.monthStart(containing: month)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(monthOffset == 0 ? "本月观看" : "每月观看").font(.subheadline)
                Spacer()
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上个月")
                    .disabled(monthStart <= stats.monthStart(containing: stats.recordedFrom))
                Text(month, format: .dateTime.year().month()).font(.subheadline).monospacedDigit()
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下个月").disabled(monthOffset >= 0)
            }.buttonStyle(.borderless)
            duration(totals, size: 40, showsSources: false)
            Text("已看 \(totals.movies) 部电影 · \(totals.episodes) 集剧" + (totals.playbackFragments > 0 ? " · \(totals.playbackFragments) 条播放片段" : ""))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                chartLegend("剧集", color: LaunchStyle.glow)
                chartLegend("电影", color: .indigo)
                if days.contains(where: { stats.records(on: $0.date).contains { $0.item.kind != .episode && $0.item.kind != .movie } }) {
                    chartLegend("本地", color: .teal)
                }
            }
            Chart(days) { day in
                let records = stats.records(on: day.date)
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("观看小时", MyViewingTotals(records: records.filter { $0.item.kind == .episode }).seconds / 3600))
                    .foregroundStyle(by: .value("内容", "剧集"))
                    .cornerRadius(4)
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("观看小时", MyViewingTotals(records: records.filter { $0.item.kind == .movie }).seconds / 3600))
                    .foregroundStyle(by: .value("内容", "电影"))
                    .cornerRadius(4)
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("观看小时", MyViewingTotals(records: records.filter { $0.item.kind != .episode && $0.item.kind != .movie }).seconds / 3600))
                    .foregroundStyle(by: .value("内容", "本地／直连"))
                    .cornerRadius(4)
                if day.totals.seconds == 0 {
                    PointMark(x: .value("日期", day.date, unit: .day), y: .value("观看小时", 0))
                        .symbolSize(12).foregroundStyle(LaunchStyle.glow.opacity(0.55))
                }
            }
            .chartForegroundStyleScale(["剧集": LaunchStyle.glow, "电影": Color.indigo, "本地／直连": Color.teal])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: [days.first?.date, stats.calendar.date(byAdding: .day, value: 14, to: monthStart), days.last?.date].compactMap { $0 }) { value in
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == 2 ? .topTrailing : .top) {
                        if let date = value.as(Date.self) {
                            Text("\(stats.calendar.component(.month, from: date))/\(stats.calendar.component(.day, from: date))")
                                .fixedSize()
                        }
                    }
                }
            }
            .chartXScale(range: .plotDimension(padding: 10))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    AxisValueLabel()
                }
            }
            .chartYScale(domain: 0...max(1, days.map { $0.totals.seconds / 3600 }.max() ?? 0))
            .frame(height: 145).padding(.top, 6)
            if monthStart < stats.recordedFrom {
                Text("本月仅覆盖 \(stats.recordedFrom.formatted(date: .numeric, time: .omitted)) 起的记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if totals.unknownRuntime > 0 {
                Text("\(totals.unknownRuntime) 条缺少片长，未计入图表时长")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let titles = stats.topTitles(inMonth: month)
            if let maximum = titles.first?.seconds, maximum > 0 {
                Text("观看 TOP3").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(titles) { title in
                    HStack(spacing: 12) {
                        Text(title.name).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        MyViewingRankBar(fraction: title.seconds / maximum).frame(maxWidth: .infinity)
                        Text("\((title.seconds / 3600).formatted(.number.precision(.fractionLength(1))))h")
                            .font(.caption).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title.name)，约 \((title.seconds / 3600).formatted(.number.precision(.fractionLength(1)))) 小时")
                }
            }
            if totals.actualSeconds > 0 {
                Text("App 实播 \((totals.actualSeconds / 60).formatted(.number.precision(.fractionLength(1)))) 分钟" +
                     (totals.estimatedSeconds > 0 ? " · 其余为服务器估算" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlassCard()
    }

    private func genreCard(_ stats: MyViewingStatistics) -> some View {
        let genres = stats.genreDistribution
        let palette = Array(([LaunchStyle.glow, .purple, .blue, .gray]).prefix(genres.count))
        let colors = Dictionary(uniqueKeysWithValues: zip(genres.map(\.id), palette))
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("类型分布").font(.subheadline)
                Spacer()
                Text("已同步记录").font(.caption).foregroundStyle(.secondary)
            }
            let detailLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 18))
            detailLayout {
                VStack(alignment: .leading, spacing: 6) {
                    duration(stats.total, size: 36, showsSources: false)
                    Text("\(stats.total.movies) 部电影 · \(stats.total.episodes) 集剧")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    if let dominant = genres.first {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(dominant.name).font(.title3.weight(.semibold)).lineLimit(1)
                            Text(dominant.seconds / stats.total.seconds, format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline).monospacedDigit()
                        }
                    }
                    MyViewingGenreSegments(genres: genres, total: stats.total.seconds, colors: colors)
                    ForEach(genres) { genre in
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(colors[genre.id] ?? .gray).frame(width: 8, height: 8)
                            Text(genre.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(genre.seconds / stats.total.seconds, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }.font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("多类型条目的片长均分到各标签，缺少类型的条目归入未分类。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlassCard()
    }

    private func chartLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func duration(_ totals: MyViewingTotals, size: CGFloat, showsSources: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                let useMinutes = totals.actualSeconds > 0 && totals.seconds < 3600
                Text(totals.unknownRuntime > 0 && totals.seconds == 0 ? "—" :
                     (totals.seconds / (useMinutes ? 60 : 3600)).formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(useMinutes ? "分钟" : "小时").font(.subheadline).foregroundStyle(.secondary)
                if totals.actualSeconds == 0 { Text("估算").font(.caption).foregroundStyle(.secondary) }
            }
            if showsSources && totals.actualSeconds > 0 {
                Text("App 实播 \( (totals.actualSeconds / 60).formatted(.number.precision(.fractionLength(1)))) 分钟" +
                     (totals.estimatedSeconds > 0 ? " · 服务器估算 \( (totals.estimatedSeconds / 60).formatted(.number.precision(.fractionLength(1)))) 分钟" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MyViewingGenreTrendCard: View {
    let trend: MyViewingGenreTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(trend.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if let previous = trend.previousSeconds {
                        let difference = (trend.seconds - previous) / 3600
                        Text("\(difference >= 0 ? "↑" : "↓")\(abs(difference).formatted(.number.precision(.fractionLength(1))))h")
                            .font(.caption2).foregroundStyle(difference > 0 ? .green : difference < 0 ? .red : .secondary)
                            .accessibilityLabel("较前 7 天\(difference >= 0 ? "增加" : "减少") \(abs(difference).formatted(.number.precision(.fractionLength(1)))) 小时")
                    }
                }
                Text("\((trend.seconds / 3600).formatted(.number.precision(.fractionLength(1)))) 小时")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text(trend.previousSeconds == nil ? "近 7 天 · 对比记录尚不足" : "近 7 天")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
            Chart(trend.samples) { sample in
                AreaMark(x: .value("日期", sample.date), y: .value("观看小时", sample.seconds / 3600))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.primary.opacity(0.28), Color.primary.opacity(0.12)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("日期", sample.date), y: .value("观看小时", sample.seconds / 3600))
                    .interpolationMethod(.monotone).foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                if sample.date == trend.samples.last?.date {
                    PointMark(x: .value("日期", sample.date), y: .value("观看小时", sample.seconds / 3600))
                        .symbol {
                            Circle().fill(.background).frame(width: 10, height: 10)
                                .overlay { Circle().stroke(Color.primary, lineWidth: 2) }
                        }
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartXScale(range: .plotDimension(padding: 8))
            .chartYScale(range: .plotDimension(padding: 8))
            .chartYScale(domain: 0...max(1, trend.samples.map { $0.seconds / 3600 }.max() ?? 0))
            .frame(height: 105)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(.rect(cornerRadius: Metrics.glassCardRadius))
        .liquidGlassCard()
    }
}

private struct MyViewingGenreSegments: View {
    let genres: [MyViewingGenre]
    let total: Double
    let colors: [String: Color]
    var body: some View {
        GeometryReader { proxy in
            let available = max(0, proxy.size.width - CGFloat(max(genres.count - 1, 0)) * 3)
            HStack(spacing: 3) {
                ForEach(genres) { genre in
                    RoundedRectangle(cornerRadius: 3).fill(colors[genre.id] ?? .gray)
                        .frame(width: total > 0 ? available * genre.seconds / total : 0)
                }
            }
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }
}

private struct MyViewingRankBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(LaunchStyle.glow)
                .frame(width: proxy.size.width * min(max(fraction, 0), 1))
        }.frame(height: 8).accessibilityHidden(true)
    }
}

struct MyViewingHistoryList: View {
    let history: ServerViewingHistory?
    var localRecords: [AppPlaybackRecord] = []
    let openItem: (MediaItem) -> Void
    @Environment(\.contentLeading) private var contentLeading

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                let stats = MyViewingStatistics(history: history ?? ServerViewingHistory(sourceID: localRecords.first { $0.sourceID != AppPlaybackHistoryStore.localSourceID }?.sourceID ?? AppPlaybackHistoryStore.localSourceID, recordedFrom: Date()), localRecords: localRecords)
                if !stats.entries.isEmpty {
                    ForEach(stats.entries.sorted { $0.watchedAt > $1.watchedAt }) { record in
                        Button { openItem(record.item) } label: {
                            MyViewingRecordRow(record: record).padding(16).liquidGlassCard()
                        }.buttonStyle(.plain).disabled(record.isLocalFile)
                    }
                } else {
                    ContentUnavailableView("暂无观看记录", systemImage: "clock.arrow.circlepath",
                                           description: Text("在 App 中播放一段时间，或连接媒体库同步已看记录。"))
                }
            }
            .padding(.horizontal, contentLeading).padding(.vertical, 20)
            .frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .navigationTitle("观看记录")
    }
}

private struct MyViewingRecordRow: View {
    let record: MyViewingEntry
    var body: some View {
        HStack(spacing: 14) {
            MyViewingPoster(item: record.item)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.item.seriesName ?? record.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if record.item.kind == .episode { Text(record.item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(record.watchedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let seconds = record.seconds {
                Text(record.actualSeconds != nil ? "实播 \((seconds / 60).formatted(.number.precision(.fractionLength(1)))) 分钟" : "约 \(Int(seconds / 60)) 分钟").font(.caption).foregroundStyle(.secondary)
            }
            if !record.isLocalFile { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
