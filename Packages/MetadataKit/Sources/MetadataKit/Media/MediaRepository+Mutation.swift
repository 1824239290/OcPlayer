import CoreModel
import Foundation

extension MediaRepository {
    /// 服务端已看标记的写入口：网络成功后才改本地，并让所有投影同步。
    @discardableResult
    public func markPlayed(itemID: MediaItem.ID) async throws -> MediaItem.PlayState {
        let state = try await server.markPlayed(itemID: itemID)
        await applyPlayState(state, forItemID: itemID, persistToStore: true)
        return state
    }

    @discardableResult
    public func markUnplayed(itemID: MediaItem.ID) async throws -> MediaItem.PlayState {
        let state = try await server.markUnplayed(itemID: itemID)
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
        let previous = items[itemID]?.value.playState
        let percentage: Double
        if played {
            percentage = 1
        } else if let durationSeconds, durationSeconds > 0 {
            percentage = min(max(positionSeconds / durationSeconds, 0), 1)
        } else {
            percentage = previous?.percentage ?? 0
        }
        let state = MediaItem.PlayState(
            played: played,
            percentage: percentage,
            positionSeconds: positionSeconds,
            unplayedCount: previous?.unplayedCount)
        await applyPlayState(state, forItemID: itemID, persistToStore: true)
    }

    /// 把一份进度更新到内存里的全部投影，并按需写回 SQLite。
    public func applyPlayState(
        _ state: MediaItem.PlayState,
        forItemID itemID: MediaItem.ID,
        persistToStore: Bool
    ) async {
        let timestamp = now()
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
            await persist { try await $0.updatePlayState(state, forItemID: itemID, tenant: tenant) }
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
