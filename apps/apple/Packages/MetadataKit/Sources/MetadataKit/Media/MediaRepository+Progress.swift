import CoreModel
import Foundation

extension MediaRepository {
    func saveIncomingItems(
        _ incoming: [MediaItem], rail: String? = nil, requestStartedAt: Date
    ) async -> [MediaItem] {
        var merged = incoming
        if !isShutdown, let store {
            do {
                merged = try await store.saveItemsAndRail(
                    incoming, rail: rail, tenant: tenant, now: now(), requestStartedAt: requestStartedAt)
            } catch {
                MetadataLog.logger.warning("媒体数据写入失败（保留内存结果）", fields: ["error": .string("\(error)")])
            }
        }
        if let rust {
            do { return try rust.progress("incoming", RustMediaRepository.Incoming(
                incoming: incoming, merged: merged, rail: rail,
                requestStartedAt: requestStartedAt, now: now())) }
            catch { RustMediaRepository.report(error); return merged }
        }
        // await 落库期间也可能刚退出播放；再次合并当前 actor 的末次进度。
        for remote in incoming {
            if let progress = localProgress[remote.id], !progress.protects(requestStartedAt: requestStartedAt) {
                localProgress[remote.id]?.item.playState = remote.playState
            }
            localProgress[remote.id]?.observe(remote, requestStartedAt: requestStartedAt, now: now())
        }
        merged = mergingLocalProgress(merged, requestStartedAt: requestStartedAt)
        if rail == "resume" {
            merged.removeAll { localProgress[$0.id]?.confirmedCompletion == true }
            let ids = Set(merged.map(\.id))
            let missing = localProgress.values.filter {
                $0.protects(requestStartedAt: requestStartedAt) && !ids.contains($0.item.id)
                    && $0.item.playState?.played == false && ($0.item.playState?.positionSeconds ?? 0) > 0
            }.sorted { $0.recordedAt > $1.recordedAt }
            for progress in missing {
                var item = items[progress.item.id]?.value ?? progress.item
                item.playState = progress.item.playState
                merged.append(item)
            }
        }
        return merged
    }

    func mergingLocalProgress(_ items: [MediaItem], requestStartedAt: Date) -> [MediaItem] {
        if let rust {
            do { return try rust.progress("merge", RustMediaRepository.Merge(
                items: items, requestStartedAt: requestStartedAt)) }
            catch { RustMediaRepository.report(error); return items }
        }
        return items.map { item in
            guard let progress = localProgress[item.id], progress.protects(requestStartedAt: requestStartedAt)
            else { return item }
            var updated = item
            updated.playState = progress.item.playState
            return updated
        }
    }
}
