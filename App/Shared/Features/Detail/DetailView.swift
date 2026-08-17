import CoreModel
import JellyfinKit
import SwiftUI

extension Color {
    /// 页面底色（macOS 窗口底 / iOS 系统底），横幅渐隐要融进它。
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// 详情页：背景横幅 + 元数据 + 播放键 + 简介 + 演员 + 类似推荐；
/// 剧集额外有季选择器和集列表（每集可单独播放、显示进度）。
struct DetailView: View {
    @Environment(AppModel.self) private var app

    /// 列表页带来的初版数据（立即可渲染），网络刷新后覆盖。
    let item: MediaItem

    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var episodes: [MediaItem] = []
    @State private var similar: [MediaItem] = []
    @State private var selectedSeasonID: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isLoadingEpisodes = false
    @State private var episodeLoadError: String?

    private var shown: MediaItem { detail ?? item }

    var body: some View {
        Group {
            if isLoading && detail == nil {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        banner
                        metadata
                        if let loadError {
                            loadErrorNotice(loadError)
                        }
                        if shown.kind == .series {
                            seasonBar
                            episodeList
                        }
                        if !shown.cast.isEmpty { castRail }
                        if !similar.isEmpty { similarRail }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationTitle(shown.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(Color.pageBackground.ignoresSafeArea())
        .task(id: item.id) { await load() }
    }

    // MARK: - 顶部横幅

    private var banner: some View {
        ZStack {
            // 背景层：有图铺图、没图铺灰块，占满横幅。
            let target = shown.imageTarget(app.server, kind: .backdrop, width: 1600)
            Group {
                if let url = target.url {
                    RemoteImage(url: url, authHeader: target.authHeader)
                } else {
                    Rectangle().fill(.quinary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部渐变：把背景图底部压暗，保证白字可读。
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.3), .clear],
                           startPoint: .bottom, endPoint: .top)
        }
        .frame(height: 320)
        // Overlay against the already-sized banner. A bottom-aligned HStack inside
        // the ZStack can use its intrinsic height and fall below the banner, where
        // `.clipped()` cuts off the poster and controls.
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 24) {
                if shown.primaryImageTag != nil {
                    let poster = shown.imageTarget(app.server, kind: .primary, width: 300)
                    RemoteImage(url: poster.url, authHeader: poster.authHeader)
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(shown.name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    metaRow
                    Button {
                        playCurrent()
                    } label: {
                        Label(playButtonLabel, systemImage: "play.fill")
                            .padding(.horizontal, 24).padding(.vertical, 11)
                            .background(playButtonColor, in: Capsule())
                            .foregroundStyle(playButtonInk)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPlayCurrent)
                    .opacity(canPlayCurrent ? 1 : 0.55)
                }
            }
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.bottom, 28)
        }
        .clipped()
    }

    private var metaRow: some View {
        HStack(spacing: 9) {
            ForEach(metaParts, id: \.self) { part in
                if part != metaParts.first {
                    Text("·").foregroundStyle(.white.opacity(0.4))
                }
                Text(part).foregroundStyle(.white.opacity(0.85))
            }
            if let rating = shown.communityRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if let official = shown.officialRating {
                Text(official)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.subheadline)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = shown.year { parts.append(String(year)) }
        if !shown.genres.isEmpty { parts.append(shown.genres.prefix(3).joined(separator: " / ")) }
        if let runtime = shown.runtimeSeconds { parts.append(RuntimeText.format(runtime)) }
        if shown.kind == .series, let count = shown.childCount {
            parts.append("\(count) 季")
        }
        return parts
    }

    private var playButtonLabel: String {
        if let playState = shown.playState, !playState.played,
           playState.percentage > 0.02, playState.percentage < 0.95 {
            return "从 \(RuntimeText.format(playState.positionSeconds).replacingOccurrences(of: " 分钟", with: "分")) 续播"
        }
        return shown.kind == .series ? "播放下一集" : "播放"
    }

    private var canPlayCurrent: Bool {
        shown.kind != .series
            || app.home.nextUp.contains { $0.seriesID == shown.id }
            || !episodes.isEmpty
    }

    private var playButtonColor: Color {
        #if os(macOS)
        .white
        #else
        .primary
        #endif
    }

    private var playButtonInk: Color {
        #if os(macOS)
        .black
        #else
        Color(.systemBackground)
        #endif
    }

    // MARK: - 简介与元信息

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let overview = shown.overview, !overview.isEmpty {
                Text(overview)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            if let playState = shown.playState, playState.percentage > 0.02, playState.percentage < 0.98 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: playState.percentage)
                        .frame(maxWidth: 360)
                    Text("看过 \(Int(playState.percentage * 100))% · 上次到 \(RuntimeText.format(playState.positionSeconds))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 20)
    }

    // MARK: - 剧集：季 + 集

    private var seasonBar: some View {
        HStack(spacing: 14) {
            Text("剧集").font(.title3.weight(.bold))
            Spacer()
            if seasons.count > 1, let selection = Binding($selectedSeasonID) {
                Picker("季", selection: selection) {
                    ForEach(seasons) { season in
                        Text(season.name).tag(Optional(season.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .task(id: selectedSeasonID) { await loadEpisodes() }
    }

    private var episodeList: some View {
        VStack(spacing: 14) {
            if isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let episodeLoadError {
                ContentUnavailableView {
                    Label("集列表加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(episodeLoadError)
                } actions: {
                    Button("重试") { Task { await loadEpisodes() } }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if episodes.isEmpty {
                ContentUnavailableView("本季暂无剧集", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            ForEach(episodes) { episode in
                EpisodeRow(episode: episode, server: app.server) {
                    app.play(episode, resumeSeconds: episode.playState?.positionSeconds)
                }
                // Make the row identity explicit. If the server refreshes a
                // season while a previous row is still on screen, its image
                // state must not be carried to a different episode.
                .id(episode.id)
            }
        }
        .padding(.horizontal, Metrics.contentLeading)
    }

    // MARK: - 演员 / 类似

    private var castRail: some View {
        Rail("演员") {
            ForEach(shown.cast.filter { $0.kind == "Actor" }.prefix(20)) { person in
                VStack(spacing: 8) {
                    let target = personImageTarget(person)
                    RemoteImage(url: target.url, authHeader: target.authHeader)
                        .aspectRatio(1, contentMode: .fill)
                        // 宽高都要定死：RemoteImage 内部占位 Rectangle 会竖向贪婪撑开，
                        // 只给宽度时头像被裁进一条很高的空白里，名字/角色被挤出可视区。
                        .frame(width: 108, height: 108)
                        .clipShape(Circle())
                    Text(person.name).font(.footnote).lineLimit(1).frame(width: 108)
                    if let role = person.role, !role.isEmpty {
                        Text(role).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).frame(width: 108)
                    }
                }
            }
        }
    }

    private var similarRail: some View {
        Rail("类似推荐") {
            ForEach(similar) { item in
                PosterCard(item: item, server: app.server) {
                    app.openDetail(item)
                }
            }
        }
    }

    private func personImageTarget(_ person: MediaItem.Person) -> (url: URL?, authHeader: String?) {
        guard let server = app.server,
              let url = try? server.imageURL(itemID: person.id, type: .primary, maxWidth: 240)
        else { return (nil, nil) }
        return (url, server.authorizationHeader)
    }

    // MARK: - 动作

    /// 电影直接播；剧集播「接下来看」（nextUp 优先，否则第一季第一集）。
    private func playCurrent() {
        switch shown.kind {
        case .series:
            if let next = app.home.nextUp.first(where: { $0.seriesID == shown.id }) {
                app.play(next, resumeSeconds: next.playState?.positionSeconds)
            } else if let first = episodes.first {
                app.play(first, resumeSeconds: first.playState?.positionSeconds)
            }
        default:
            app.play(shown, resumeSeconds: shown.playState?.positionSeconds)
        }
    }

    private func load() async {
        guard let server = app.server else { return }
        isLoading = true
        loadError = nil
        detail = nil
        seasons = []
        episodes = []
        selectedSeasonID = nil
        episodeLoadError = nil

        // Similar recommendations are optional and may be unavailable on
        // servers with that endpoint disabled. Keep the required detail path
        // independent so a recommendation failure cannot blank the page.
        async let similarItems = server.similar(itemID: item.id)
        do {
            let loadedDetail = try await server.item(item.id)
            guard !Task.isCancelled else { return }
            detail = loadedDetail

            if loadedDetail.kind == .series {
                do {
                    let loadedSeasons = try await server.seasons(seriesID: item.id)
                    guard !Task.isCancelled else { return }
                    seasons = loadedSeasons
                    // 默认挑第一个没看完的季，都看完了就用最后一季
                    let firstUnwatched = loadedSeasons.first {
                        ($0.playState?.unplayedCount ?? 0) > 0
                    }
                    selectedSeasonID = (firstUnwatched ?? loadedSeasons.last)?.id
                } catch let e as JellyfinError {
                    loadError = e.errorDescription
                } catch {
                    loadError = "\(error)"
                }
            }
        } catch let e as JellyfinError {
            loadError = e.errorDescription
        } catch {
            loadError = "\(error)"
        }
        isLoading = false
        similar = (try? await similarItems) ?? []
    }

    private func loadEpisodes() async {
        guard let server = app.server, shown.kind == .series, let seasonID = selectedSeasonID else {
            episodes = []
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        episodes = []
        isLoadingEpisodes = true
        episodeLoadError = nil
        defer {
            if selectedSeasonID == seasonID {
                isLoadingEpisodes = false
            }
        }
        do {
            let loaded = try await server.episodes(seriesID: shown.id, seasonID: seasonID)
            guard !Task.isCancelled, selectedSeasonID == seasonID else { return }
            episodes = loaded
        } catch let e as JellyfinError {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = e.errorDescription
        } catch {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = "\(error)"
        }
    }

    private func loadErrorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 14)
    }
}

// MARK: - 集行

private struct EpisodeRow: View {
    let episode: MediaItem
    let server: JellyfinServer?
    var onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    let target = episode.episodeThumbTarget(server, width: 400)
                    RemoteImage(url: target.url, authHeader: target.authHeader)
                    LinearGradient(colors: [.black.opacity(0.5), .clear],
                                   startPoint: .bottom, endPoint: .center)
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .font(.caption)
                        .padding(7)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(8)
                }
                // 缩略图钉死 200×112（16:9）：之前只约束宽不约束高，
                // 图片加载完高度会跳，导致行高不一致、内容被挤动。
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if let label = episode.episodeLabel {
                            Text(label)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        Text(episode.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if episode.playState?.played == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.footnote)
                        }
                    }
                    if let overview = episode.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let runtime = episode.runtimeSeconds {
                            Text(RuntimeText.format(runtime))
                        }
                        if let playState = episode.playState, playState.percentage > 0.02, !playState.played {
                            ProgressView(value: playState.percentage)
                                .frame(width: 90)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
