import AppDesignKit
import CoreModel
import Foundation

/// 详情页**点击预取**：`openDetail` 在 push 转场动画开始的同时就把 item / 季 /
/// 集的请求发出去，落地写进 `detailSnapshots`——进页 `load()` 读到 TTL 内的新快照，
/// 整页零请求秒出。Senplay / Rex 那类客户端「详情页秒开」的手感主要就是这条。
///
/// 与既有机制的关系：
/// - 快照写入复用 `storeDetailSnapshot`（LRU / 会话清空照常生效），`DetailView`
///   的 SWR 路径**零改动**即命中；
/// - 默认季/集的选择与进页后同一套（`AppModel+DetailPrefs`），预取拉的就是
///   进页会停的那一季，不会出现「预取拉了 A 季、进页选 B 季」的白拉；
/// - 预取失败（离线 / 服务端抖动）**一律静默**：进页后 `load()` 的正常路径会重试，
///   预取只是加速，永远不能变成新的失败源。
extension AppModel {

    /// `openDetail` 的预取钩子。in-flight 去重 + 「快照足够新就免了」。
    func prefetchDetail(for item: MediaItem) {
        guard detailPrefetchTasks[item.id] == nil else { return }
        // 已经有 TTL 内的快照（比如刚从这条详情返回）：预取无事可做。
        if let snapshot = detailSnapshots[item.id],
           Date().timeIntervalSince(snapshot.fetchedAt) < Self.detailSnapshotTTL {
            return
        }
        detailPrefetchTasks[item.id] = Task { [weak self] in
            await self?.runDetailPrefetch(for: item)
            self?.detailPrefetchTasks[item.id] = nil
        }
    }

    private func runDetailPrefetch(for item: MediaItem) async {
        guard let server else { return }
        do {
            switch item.kind {
            case .series:
                // item 与季**并行**：seasons 只依赖 seriesID。kind 来自列表条目
                //（Jellyfin/Emby 列表都带 Type），判错的代价只是白拉一次季列表，
                // 无正确性影响——进页 load() 仍以详情响应的 kind 为准。
                async let seasonsRequest = server.seasons(seriesID: item.id)
                let detail = try await server.item(item.id)
                let seasons = try await seasonsRequest
                guard !Task.isCancelled else { return }
                // 默认季与该季的集：进页同一套判断（AppModel+DetailPrefs）。
                // 集请求依赖选出的季，只能串行在后面；前两跳已与转场动画并行。
                let seasonID = preferredSeasonID(in: seasons, seriesID: detail.id)
                var episodesBySeason: [String: [MediaItem]] = [:]
                if let seasonID,
                   let episodes = try? await server.episodes(seriesID: detail.id, seasonID: seasonID) {
                    episodesBySeason[seasonID] = episodes
                }
                storeDetailSnapshot(
                    .init(detail: detail, seasons: seasons, similar: [],
                          selectedSeasonID: seasonID, episodesBySeason: episodesBySeason),
                    for: item.id)
            case .boxSet:
                // 合集：详情 + 第一页成员。成员是详情页成员区与背景兜底的输入。
                let detail = try await server.item(item.id)
                guard !Task.isCancelled else { return }
                let members = try? await server.collectionMembers(of: detail.id)
                storeDetailSnapshot(
                    .init(detail: detail, seasons: [], similar: [], selectedSeasonID: nil,
                          episodesBySeason: [:], collectionMembers: members?.items ?? []),
                    for: item.id)
            default:
                // 电影等单条目：详情一发即完。
                let detail = try await server.item(item.id)
                guard !Task.isCancelled else { return }
                storeDetailSnapshot(
                    .init(detail: detail, seasons: [], similar: [], selectedSeasonID: nil,
                          episodesBySeason: [:]),
                    for: item.id)
            }
        } catch {
            // 静默：取消（离页 / 会话切换）与网络失败都不该有任何表征，
            // 进页后 load() 的正常路径负责重试与报错。
            return
        }
        prewarmDetailBackdrop(for: item)
    }

    /// 氛围底图预热：与 `DetailViewModel.prewarmAmbience` 的服务端一路**同链同参**
    /// （`imageTarget(.backdrop, 800)` + 512 解码），保证进页首帧命中图片缓存。
    /// TMDb 回落那一路（服务端缺背景图时）预取阶段没有 overlay 可判，留给进页
    /// 后的 prewarmAmbience 补——同 URL 时它直接短路，不重复解码。
    private func prewarmDetailBackdrop(for item: MediaItem) {
        guard let server else { return }
        let target = item.imageTarget(server, kind: .backdrop, width: 800)
        guard let url = target.url else { return }
        let authHeader = target.authHeader
        Task {
            _ = try? await ImagePipeline.shared.load(url, authHeader: authHeader, maxPixelSize: 512)
        }
    }
}
