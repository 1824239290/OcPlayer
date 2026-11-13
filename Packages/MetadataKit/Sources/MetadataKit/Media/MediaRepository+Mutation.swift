import CoreModel
import Foundation

extension MediaRepository {
    /// 服务端已看标记的写入口：网络成功后才改本地，并让所有投影同步。
    @discardableResult
    public func markPlayed(itemID: MediaItem.ID) async throws -> MediaItem.PlayState {
        guard !isShutdown else { throw CancellationError() }
        let state = try await server.markPlayed(itemID: itemID)
        guard !isShutdown, !Task.isCancelled else { throw CancellationError() }
        await applyPlayState(state, forItemID: itemID, persistToStore: true)
        return state
    }

    @discardableResult
    public func markUnplayed(itemID: MediaItem.ID) async throws -> MediaItem.PlayState {
        guard !isShutdown else { throw CancellationError() }
        let state = try await server.markUnplayed(itemID: itemID)
        guard !isShutdown, !Task.isCancelled else { throw CancellationError() }
        await applyPlayState(state, forItemID: itemID, persistToStore: true)
        return state
    }

    /// 播放结束时的本地进度回写。服务端上报另有协调器；这里保证页面与离线缓存
    /// 看到的是同一个进度，而不是等下一次详情刷新。
    public func recordPlaybackProgress(
        itemID: MediaItem.ID,
        positionSeconds: Double,
        durationSeconds: Double?,
        played: Bool
    ) async {
        if let rust {
            do {
                let state: MediaItem.PlayState = try rust.progress("playbackState", RustMediaRepository.Playback(
                    itemID: itemID, positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds, played: played))
                await applyPlayState(state, forItemID: itemID, persistToStore: true)
            } catch { RustMediaRepository.report(error) }
            return
        }
        let previous = items[itemID]?.value.playState
        let state = MediaItem.PlayState.playbackProgress(
            positionSeconds: positionSeconds, durationSeconds: durationSeconds,
            played: played, previous: previous)
        await applyPlayState(state, forItemID: itemID, persistToStore: true)
    }

    /// 有明确原会话归属的末次进度，允许在 shutdown 之后完成；不开放旧网络请求的写盘闸门。
    public func recordFinalPlaybackProgress(
        item: MediaItem,
        positionSeconds: Double,
        durationSeconds: Double?,
        recordedAt: Date? = nil
    ) async {
        let timestamp = recordedAt ?? now()
        if let rust {
            await recordSharedFinalProgress(rust, item: item, positionSeconds: positionSeconds,
                durationSeconds: durationSeconds, recordedAt: timestamp)
            return
        }
        // 队列等待不改变操作先后：更早捕获的快照不能替换较新的内存事实。
        if let current = localProgress[item.id], current.recordedAt > timestamp { return }
        let previous = items[item.id]?.value.playState
            ?? localProgress[item.id]?.item.playState ?? item.playState
        var localItem = item
        localItem.playState = .playbackProgress(
            positionSeconds: positionSeconds, durationSeconds: durationSeconds,
            played: previous?.played ?? false, previous: previous)
        let progress = LocalPlaybackProgress(item: localItem, recordedAt: timestamp,
                                             completed: LocalPlaybackProgress.isComplete(position: positionSeconds, duration: durationSeconds))
        localProgress[item.id] = progress
        let state: MediaItem.PlayState
        var acceptedProgress = progress
        if let store {
            do {
                let result = try await store.recordPlaybackProgressUpdate(
                    item: item, positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds, tenant: tenant, now: timestamp)
                state = result.state
                // 新会话的操作可能只在磁盘中。沿用它的确认边界，不能重新变成未确认保护。
                if let newer = result.newerRecord { acceptedProgress = newer }
            } catch {
                MetadataLog.logger.warning("播放末次进度写入失败", fields: ["error": .string("\(error)")])
                state = localItem.playState!
            }
        } else {
            state = localItem.playState!
        }
        // await 期间可能已完成显式标记、新的末次写回或远端确认；不能把旧结果重新应用。
        guard localProgress[item.id]?.revision == progress.revision,
              localProgress[item.id]?.confirmedAt == nil else { return }
        localItem.playState = state
        acceptedProgress.item = localItem
        localProgress[item.id] = acceptedProgress
        guard !isShutdown else { return }
        // 缓存未见过的播放条目也必须参与内存合并。
        if items[item.id] == nil { rememberItems([localItem]) }
        await applyPlayState(state, forItemID: item.id, persistToStore: false)
    }

    /// 把一份进度更新到内存里的全部投影，并按需写回 SQLite。
    public func applyPlayState(
        _ state: MediaItem.PlayState,
        forItemID itemID: MediaItem.ID,
        persistToStore: Bool
    ) async {
        guard !isShutdown else { return }
        let timestamp = now()
        if let rust {
            do {
                let result: RustMediaRepository.Applied = try rust.progress("apply", RustMediaRepository.Apply(
                    itemID: itemID, state: state, persistToStore: persistToStore, now: timestamp))
                if result.applied, persistToStore, let fallback = result.fallbackItem {
                    await persist { try await $0.updatePlayState(state, forItemID: itemID,
                        tenant: tenant, now: timestamp, fallbackItem: fallback) }
                }
            } catch { RustMediaRepository.report(error) }
            return
        }
        var progressItem = items[itemID]?.value ?? localProgress[itemID]?.item
            ?? MediaItem(id: itemID, name: itemID, kind: .other)
        progressItem.playState = state
        if persistToStore {
            // 显式操作已获服务端确认，但先发请求仍不能覆盖这份结果。
            // 在第一次 await 之前建立内存边界，数据库写入复用同一时间。
            localProgress[itemID] = LocalPlaybackProgress(
                item: progressItem, recordedAt: timestamp, confirmedAt: timestamp)
        }
        if let entry = items[itemID] {
            var item = entry.value
            item.playState = state
            items[itemID] = MemoryEntry(value: item, fetchedAt: timestamp)
        }

        if let entry = details[itemID] {
            var content = entry.value
            content.item.playState = state
            details[itemID] = MemoryEntry(value: content, fetchedAt: timestamp)
        }
        for (key, entry) in details.allValues {
            var content = entry.value
            guard let episodes = Self.updating(content.episodes, itemID: itemID, state: state) else {
                continue
            }
            content.episodes = episodes
            details[key] = MemoryEntry(value: content, fetchedAt: timestamp)
        }

        for (key, entry) in episodeLists.allValues {
            guard let episodes = Self.updating(entry.value, itemID: itemID, state: state) else { continue }
            episodeLists[key] = MemoryEntry(value: episodes, fetchedAt: timestamp)
        }

        if let entry = homeEntry {
            var content = entry.value
            content.resume = Self.updating(content.resume, itemID: itemID, state: state) ?? content.resume
            content.nextUp = Self.updating(content.nextUp, itemID: itemID, state: state) ?? content.nextUp
            content.latest = Self.updating(content.latest, itemID: itemID, state: state) ?? content.latest
            homeEntry = MemoryEntry(value: content, fetchedAt: timestamp)
        }

        for (descriptor, entry) in pages.allValues {
            guard let items = Self.updating(entry.value.items, itemID: itemID, state: state) else {
                continue
            }
            var content = entry.value
            content.items = items
            pages[descriptor] = MemoryEntry(value: content, fetchedAt: timestamp)
        }

        if persistToStore {
            let fallback = progressItem
            await persist {
                try await $0.updatePlayState(state, forItemID: itemID, tenant: tenant,
                                            now: timestamp, fallbackItem: fallback)
            }
        }
    }

    static func updating(
        _ items: [MediaItem],
        itemID: MediaItem.ID,
        state: MediaItem.PlayState
    ) -> [MediaItem]? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        var copy = items
        copy[index].playState = state
        return copy
    }
}

extension MediaItem.PlayState {
    static func playbackProgress(
        positionSeconds: Double,
        durationSeconds: Double?,
        played: Bool,
        previous: Self?
    ) -> Self {
        let percentage: Double
        if played {
            percentage = 1
        } else if let durationSeconds, durationSeconds > 0 {
            percentage = min(max(positionSeconds / durationSeconds, 0), 1)
        } else {
            percentage = previous?.percentage ?? 0
        }
        return Self(played: played, percentage: percentage, positionSeconds: positionSeconds,
                    unplayedCount: previous?.unplayedCount)
    }
}
