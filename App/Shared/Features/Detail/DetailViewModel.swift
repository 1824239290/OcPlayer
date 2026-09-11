import CoreModel
import JellyfinKit
import SwiftUI

/// 详情页的数据面视图模型：详情/季/集/类似的加载、缓存与选中态。
///
/// 从 `DetailView` 抽出（原 19 个 @State + 5 个加载方法摊在视图里）。
/// 视图只留布局与交互编排；所有「拉什么、怎么缓存、默认选哪季哪集」都在这里，
/// 可脱离 SwiftUI 直接测。
///
/// `attach(_:)` 而不是 init 注入 AppModel：SwiftUI 视图的 init 拿不到 @Environment，
/// VM 在 `.task` 里补挂；所有加载方法以 `app?.server` 为守卫，未挂载 = 不请求。
@MainActor
@Observable
final class DetailViewModel {
    let item: MediaItem
    private weak var app: AppModel?

    // MARK: - 数据状态

    var detail: MediaItem?
    var seasons: [MediaItem] = []
    var episodes: [MediaItem] = []
    /// 本次停留期间已经拉过的季 → 集列表。来回切季不重拉、不闪 loading。
    /// `load()`（换条目）时整体清空。
    var episodesBySeason: [String: [MediaItem]] = [:]
    /// 每季各自记住用户选中的那一集：切走再切回来选中项还在。
    var selectedEpisodeBySeason: [String: MediaItem.ID] = [:]
    var similar: [MediaItem] = []
    var selectedSeasonID: String?
    var selectedEpisodeID: MediaItem.ID?
    /// 横向选集箭头滚动的锚点（可与选中集不同：只滚列表不改选中）。
    var episodeScrollFocusID: MediaItem.ID?
    var isLoading = false
    var loadError: String?
    var isLoadingEpisodes = false
    var episodeLoadError: String?
    /// 播放退出后的静默刷新任务：离页时由视图取消。
    var reloadAfterPlaybackTask: Task<Void, Never>?

    var shown: MediaItem { detail ?? item }

    init(item: MediaItem) {
        self.item = item
    }

    func attach(_ app: AppModel) {
        self.app = app
    }

    // MARK: - 选中

    /// 季选择器点选。
    func selectSeason(_ seasonID: String) {
        selectedSeasonID = seasonID
    }

    /// 横向选集点选 / 点播共用：记下选中 + 滚动锚点 + 每季记忆。
    func selectEpisode(_ episode: MediaItem) {
        selectedEpisodeID = episode.id
        episodeScrollFocusID = episode.id
        if let seasonID = selectedSeasonID {
            selectedEpisodeBySeason[seasonID] = episode.id
        }
    }

    var selectedSeasonName: String {
        seasons.first(where: { $0.id == selectedSeasonID })?.name ?? "选择季"
    }

    // MARK: - 加载

    func load() async {
        guard let app, let server = app.server else { return }
        // stale-while-revalidate：有快照先原位渲染（不置 nil、不闪骨架屏），
        // 重拉成功后原位覆盖；失败则静默保留快照内容（SWR 语义，错误条只服务首拉）。
        let snapshot = app.detailSnapshots[item.id]
        if let snapshot {
            detail = snapshot.detail
            seasons = snapshot.seasons
            similar = snapshot.similar
            selectedSeasonID = snapshot.selectedSeasonID
            episodesBySeason = snapshot.episodesBySeason
            if let seasonID = snapshot.selectedSeasonID,
               let cached = snapshot.episodesBySeason[seasonID] {
                episodes = cached
                let restored = selectedEpisodeBySeason[seasonID]
                    .flatMap { id in cached.contains { $0.id == id } ? id : nil }
                    ?? preferredEpisodeID(in: cached, seriesID: snapshot.detail.id)
                selectedEpisodeID = restored
                episodeScrollFocusID = restored
            }
        }

        isLoading = snapshot == nil
        if snapshot == nil {
            loadError = nil
            detail = nil
            seasons = []
            episodes = []
            episodesBySeason = [:]
            selectedEpisodeBySeason = [:]
            selectedSeasonID = nil
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
            episodeLoadError = nil
        }

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
                    selectedSeasonID = preferredSeasonID(in: loadedSeasons, seriesID: loadedDetail.id)
                } catch let e as JellyfinError {
                    if snapshot == nil { loadError = e.errorDescription }
                } catch {
                    if snapshot == nil { loadError = "\(error)" }
                }
            }
        } catch let e as JellyfinError {
            if snapshot == nil { loadError = e.errorDescription }
        } catch {
            if snapshot == nil { loadError = "\(error)" }
        }
        isLoading = false
        similar = (try? await similarItems) ?? similar
        storeSnapshot()
    }

    func loadEpisodes() async {
        guard let server = app?.server, shown.kind == .series, let seasonID = selectedSeasonID else {
            episodes = []
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        // 这一季已经拉过：同步换上，不清空、不转圈、不发请求。
        if let cached = episodesBySeason[seasonID] {
            episodes = cached
            let restored = selectedEpisodeBySeason[seasonID]
                .flatMap { id in cached.contains { $0.id == id } ? id : nil }
                ?? preferredEpisodeID(in: cached, seriesID: shown.id)
            selectedEpisodeID = restored
            episodeScrollFocusID = restored
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        episodes = []
        selectedEpisodeID = nil
        episodeScrollFocusID = nil
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
            episodesBySeason[seasonID] = loaded
            episodes = loaded
            let preferred = preferredEpisodeID(in: loaded, seriesID: shown.id)
            selectedEpisodeID = preferred
            episodeScrollFocusID = preferred
            storeSnapshot()
        } catch let e as JellyfinError {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = e.errorDescription
        } catch is CancellationError {
            // 切季/离页的取消不是错误，别闪错误条。
            return
        } catch {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = "\(error)"
        }
    }

    /// 播放退出/结束回传落库后静默刷新详情与选集（不重置骨架屏、不打断页面浏览）。
    func reloadAfterPlayback() async {
        guard let server = app?.server else { return }
        if let loaded = try? await server.item(item.id) {
            detail = loaded
        }
        if shown.kind == .series {
            // 只回填当前季：其他季的缓存不包含本次播放的那一集，清空整份
            // episodesBySeason 只会让切季时白拉一遍、闪一下 loading。
            if let seasonID = selectedSeasonID {
                if let loaded = try? await server.episodes(seriesID: shown.id, seasonID: seasonID) {
                    episodesBySeason[seasonID] = loaded
                    episodes = loaded
                    if let currentID = selectedEpisodeID, loaded.contains(where: { $0.id == currentID }) {
                        // 保持选中集，其 playState 已经更新为最新的
                    } else {
                        let preferred = preferredEpisodeID(in: loaded, seriesID: shown.id)
                        selectedEpisodeID = preferred
                        episodeScrollFocusID = preferred
                    }
                }
            }
        }
        storeSnapshot()
    }

    /// 写回某条的已看状态：详情 + 当前选集 + 每季缓存三处同步，
    /// 缓存不改的话切走再切回来「已看过」的勾又变回去。
    func applyPlayState(_ state: MediaItem.PlayState, toItemID id: MediaItem.ID) {
        if var current = detail, current.id == id {
            current.playState = state
            detail = current
        }
        if let index = episodes.firstIndex(where: { $0.id == id }) {
            episodes[index].playState = state
        }
        for (seasonID, cached) in episodesBySeason {
            guard let index = cached.firstIndex(where: { $0.id == id }) else { continue }
            episodesBySeason[seasonID]?[index].playState = state
        }
        storeSnapshot()
    }

    /// 把当前内容写进跨进入快照（SWR 的「stale」来源）。
    private func storeSnapshot() {
        guard let app, let detail else { return }
        app.storeDetailSnapshot(
            .init(detail: detail, seasons: seasons, similar: similar,
                  selectedSeasonID: selectedSeasonID, episodesBySeason: episodesBySeason),
            for: item.id)
    }

    // MARK: - 智能默认季 / 集

    /// 首页续播 / 下一集线索：用于默认季与默认选中集。
    private func preferredEpisodeHint(seriesID: MediaItem.ID) -> MediaItem? {
        guard let app else { return nil }
        if let resume = app.home.resume.first(where: {
            $0.seriesID == seriesID
                && !($0.playState?.played ?? false)
                && ($0.playState?.positionSeconds ?? 0) >= 30
        }) {
            return resume
        }
        return app.home.nextUp.first(where: { $0.seriesID == seriesID })
    }

    /// 默认季：有续播/下一集进度的季优先；否则第一部有未看完的常规季（跳过 SP/特典）；
    /// 再否则第一部常规季；最后才落到任意季（含仅有 SP 的片）。
    private func preferredSeasonID(in seasons: [MediaItem], seriesID: MediaItem.ID) -> String? {
        guard !seasons.isEmpty else { return nil }

        if let hint = preferredEpisodeHint(seriesID: seriesID) {
            if let sn = hint.seasonNumber,
               let byNumber = seasons.first(where: { $0.seasonNumber == sn }) {
                return byNumber.id
            }
        }

        let regular = seasons.filter { !isSpecialsSeason($0) }
        let pool = regular.isEmpty ? seasons : regular

        if let unwatched = pool.first(where: { ($0.playState?.unplayedCount ?? 0) > 0 }) {
            return unwatched.id
        }
        return pool.first?.id ?? seasons.first?.id
    }

    /// 特典/SP 季：季号 0，或名称像 Specials / 特别篇 / SP（避免默认一进详情就停在 SP）。
    private func isSpecialsSeason(_ season: MediaItem) -> Bool {
        if let number = season.seasonNumber, number == 0 { return true }
        let name = season.name.lowercased()
        if name.contains("special") { return true }
        if name.contains("特别") || name.contains("特典") || name.contains("番外") { return true }
        let compact = name.filter { !$0.isWhitespace }
        if compact == "sp" || compact.hasPrefix("sp") && compact.count <= 4 { return true }
        return false
    }

    /// 当前季列表内的默认选中集：续播 → nextUp → 第一集未看完 → 第一集。
    private func preferredEpisodeID(in episodes: [MediaItem], seriesID: MediaItem.ID) -> MediaItem.ID? {
        guard !episodes.isEmpty else { return nil }

        if let hint = preferredEpisodeHint(seriesID: seriesID),
           episodes.contains(where: { $0.id == hint.id }) {
            return hint.id
        }

        return episodes.first(where: { !($0.playState?.played ?? false) })?.id
            ?? episodes.first?.id
    }
}
