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

    /// 氛围底图预热：与进页后的 `DetailViewModel.prewarmAmbience` 同链。
    private func prewarmDetailBackdrop(for item: MediaItem) {
        guard let server else { return }
        let target = item.imageTarget(server, kind: .backdrop, width: DetailAmbienceImage.urlWidth)
        guard let url = target.url else { return }
        let authHeader = target.authHeader
        Task {
            await DetailAmbienceImage.prewarm(url: url, authHeader: authHeader)
        }
    }
}
