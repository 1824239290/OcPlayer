import CoreModel
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
    /// 所以删掉并把结论写在这里。
    ///
    /// `TMDbEnricher.refreshEpisodeOrSeason` **保留**（有用例覆盖）：Phase 3 的批量
    /// 补全会需要季数据，将来若加分集详情页也直接可用。
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

    /// 某条目当前的对应关系（诊断/设置页展示用）。
    func tmdbLink(for item: MediaItem) async -> TMDbLink? {
        guard let tenant = currentTenant else { return nil }
        return await tmdb.link(for: item, tenant: tenant, store: metadata.activeStore)
    }

    /// 刷新「已补全 N 部」计数。
    func refreshTMDbLinkCount() async {
        await tmdb.refreshLinkedCount(tenant: currentTenant)
    }
}
