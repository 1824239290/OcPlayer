import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit

/// TMDb 补全在 App 层的取用口。
///
/// 都挂在 `AppModel` 上而不是塞进 `DetailView`：详情页需要「当前租户」「父剧条目」
/// 「父剧对应」这几样，它们分别来自会话、网络与缓存——只有 `AppModel` 拿得全。
extension AppModel {

    /// 当前租户。**现算**而不是缓存：切服务器/换用户后缓存会读到上一台的数据
    /// （`MetadataCoordinator.hydrator(for:)` 的注释记着同一个坑）。
    var currentTenant: TenantID? {
        guard let profile = server?.profile else { return nil }
        return TenantID(profile: profile)
    }

    /// 当前设置下的图片策略（设置页开关改了立刻生效，故每次现读）。
    var tmdbImagePolicy: TMDbImagePolicy {
        TMDbImagePolicy(replacesExisting: tmdb.replaceImages)
    }

    /// 取一个条目已有的 TMDb 叠加数据（**不发网络**）。
    func tmdbOverlay(for item: MediaItem) async -> TMDbOverlay? {
        guard let tenant = currentTenant else { return nil }
        return await tmdb.overlay(for: item, tenant: tenant)
    }

    /// 确保一个条目的 TMDb 数据可用。
    ///
    /// ## 只处理电影与剧集（这是刻意的，不是漏了）
    ///
    /// 详情页**只会收到 `.movie` 与 `.series`**，三条入口都是：
    /// - 首页续播/接下来看 → `openSeriesDetail(for:)`，分集一律解析到**所属剧集**
    ///   （那里的注释写着「详情入口应落到所属电视剧，而不是单集」）；
    /// - 搜索 → `kinds: [.movie, .series]`；
    /// - 库页 / 相似推荐 → 库里就是剧与电影。
    ///
    /// 所以**季与集没有自己的详情页**，也就没有地方展示它们的 TMDb 数据。
    /// 曾经这里写过一条 `.season/.episode` 分支转 `refreshEpisodeOrSeason`，
    /// 实测**永远走不到**——那种「看起来接好了、其实不可达」的代码比不写更危险，
    /// 所以连那个方法一起删掉了（它后来也被 `refreshSeason` 取代）。
    /// 季数据现在由「打开剧集页」与「库级批量补全」两条路径补齐。
    @discardableResult
    func refreshTMDb(for item: MediaItem) async -> Bool {
        guard let tenant = currentTenant else { return false }
        // 若已有对应则不重新匹配（那是服务端 id 或用户手动定下的事实）。
        let seriesLink: TMDbLink? = nil
        return await tmdb.refresh(item: item, tenant: tenant, seriesLink: seriesLink)
    }

    /// 剧集类条目的 TMDb 对应（只有 `.tv` 键才返回）。季/集数据都靠它定位。
    func tmdbSeriesLink(for item: MediaItem) async -> TMDbLink? {
        guard let link = await tmdbLink(for: item), case .tv = link.entityKey else { return nil }
        return link
    }

    /// 确保**服务端合集**（BoxSet）的 TMDb 合集数据可用。
    ///
    /// - Parameter members: 合集成员。它同时是**定位的输入**（成员的
    ///   `ProviderIds["Tmdb"]` → `/movie/{id}` → `belongs_to_collection`），
    ///   所以必须在成员加载完之后调，否则只能眼睁睁返回 false。
    /// - Returns: `RefreshOutcome`（不是 Bool）：调用方用 `.didFetch` 决定要不要重读
    ///   overlay，用 `.isConclusive` 决定要不要记账「以后不必再试」。
    func refreshTMDbCollection(
        for item: MediaItem,
        members: [MediaItem]
    ) async -> TMDbEnricher.RefreshOutcome {
        guard let tenant = currentTenant else { return .failed }
        return await tmdb.refreshCollection(item: item, members: members, tenant: tenant)
    }

    /// 取某一季的叠加数据（**不发网络**）。
    ///
    /// - Parameters:
    ///   - seriesLink: 父剧的对应（`tmdbSeriesLink(for:)` 得来）。
    ///   - seasonNumber: 季号（Jellyfin 的 `IndexNumber`；特别篇是 0）。
    func tmdbSeasonOverlay(seriesLink: TMDbLink, seasonNumber: Int) async -> TMDbOverlay? {
        await tmdb.seasonOverlay(seriesLink: seriesLink, seasonNumber: seasonNumber)
    }

    /// 确保某一季的数据可用（缺失则拉）。返回是否发起了网络。
    @discardableResult
    func refreshTMDbSeason(seriesLink: TMDbLink, seasonNumber: Int) async -> Bool {
        await tmdb.refreshSeason(seriesLink: seriesLink, seasonNumber: seasonNumber)
    }

    /// 某条目当前的对应关系（详情页图标 / 手动匹配面板 / 设置页展示用）。
    ///
    /// 走 `tmdb.link(itemID:tenant:)`（内部经补全服务读库），**不用调用方传 store**：
    /// 早先那条 `link(for:tenant:store:)` 要求调用方自己把 `MetadataStore` 递进来，
    /// 于是同一个读取有两个入口，其中一个没人用——正是这轮一直在清的那类问题。
    func tmdbLink(for item: MediaItem) async -> TMDbLink? {
        await tmdb.link(itemID: item.id, tenant: currentTenant)
    }

    /// 刷新「已补全 N 部」计数。
    func refreshTMDbLinkCount() async {
        await tmdb.refreshLinkedCount(tenant: currentTenant)
    }

    // MARK: - 库级批量补全

    /// 枚举整库的电影与剧（批量补全的输入）。
    ///
    /// `parentID: nil` + `recursive: true` 让服务端跨所有媒体库返回，不用先逐个
    /// `userViews()` 再分别翻页。
    ///
    /// **必须带 `ProviderIds`**：`MediaServer.items` 底层走 `/Items` 列表接口，
    /// 而它默认不返回 ProviderIds（实测 0/5）。少了 `tmdbID` 的话整库补全就只能
    /// 靠标题搜索匹配——命中率与请求数都会明显变差。这一条已在 `itemsPage` 里
    /// 显式加上 `fields=[.providerIDs]`（见那里的注释）。
    func tmdbBatchCandidates() async -> [MediaItem] {
        guard let server else { return [] }
        return (try? await server.items(parentID: nil, kinds: [.movie, .series],
                                        recursive: true, limit: 200)) ?? []
    }

    /// 启动库级批量补全（设置页按钮）。进度与结果在 `tmdb` 上。
    func enrichTMDbLibrary() {
        tmdb.startBatch(tenant: currentTenant) { [weak self] in
            await self?.tmdbBatchCandidates() ?? []
        }
    }

    // MARK: - 手动匹配

    /// 手动匹配的候选搜索（用户主动发起，失败要让他看到）。
    func tmdbSearchCandidates(query: String, mediaType: TMDbMediaType,
                              year: Int?) async throws -> [TMDbSearchResult] {
        try await tmdb.searchCandidates(query: query, mediaType: mediaType, year: year)
    }

    /// 手动绑定某条目到指定实体，并立刻拉数据。
    @discardableResult
    func tmdbBind(itemID: String, entityKey: TMDbEntityKey) async -> Bool {
        guard let tenant = currentTenant else { return false }
        let ok = await tmdb.bindManually(itemID: itemID, entityKey: entityKey, tenant: tenant)
        await refreshTMDbLinkCount()
        return ok
    }

    /// 解除某条目的 TMDb 对应。
    func tmdbUnbind(itemID: String) async {
        guard let tenant = currentTenant else { return }
        await tmdb.unbind(itemID: itemID, tenant: tenant)
        await refreshTMDbLinkCount()
    }
}
