import AppDesignKit
import CoreModel
import Foundation
import JellyfinKit

/// 详情页**点击预取**：`openDetail` 在 push 转场开始的同时把条目 / 季 / 集请求
/// 交给媒体数据仓储。进页后的 `refreshDetail` 与预取是同一个单飞任务，因此不会
/// 出现「预取一轮、进页再一轮」的重复请求。
extension AppModel {
    /// `openDetail` 的预取钩子。仓储自己按条目去重，并在内存命中时保持零网络。
    /// - Returns: 预取任务（调用方可等待；`openDetail` 不等待）。
    @discardableResult
    func prefetchDetail(for item: MediaItem) -> Task<Void, Never>? {
        let metadata = metadata
        let task = Task {
            await metadata.prefetchDetail(itemID: item.id, kindHint: item.kind)
        }
        prewarmDetailBackdrop(for: item)
        return task
    }

    /// 点击时预取详情实际使用的高分辨率档，来源与详情解析共用同一策略。
    private func prewarmDetailBackdrop(for item: MediaItem) {
        guard let server else { return }
        let policy = tmdbImagePolicy
        Task {
            let overlay = await tmdbOverlay(for: item)
            let target = DetailBackdropSource.resolve(
                item: item, server: server, overlay: overlay, policy: policy,
                width: DetailAmbienceImage.artURLWidth
            )
            guard let url = target.url else { return }
            _ = try? await ImagePipeline.shared.load(
                url, authHeader: target.authHeader, maxPixelSize: DetailAmbienceImage.artDecodePixels
            )
        }
    }
}
