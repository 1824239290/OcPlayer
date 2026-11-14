import CoreModel
import Foundation
import JellyfinKit

extension MediaRepository {
    public func cachedItem(itemID: MediaItem.ID) async -> MediaSnapshot<MediaItem>? {
        if let rust {
            return await cachedRepositoryValue(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "cachedItem", now: now(), itemID: itemID))
        }
        if let entry = items[itemID] {
            return snapshot(entry.value, fetchedAt: entry.fetchedAt, source: .memory)
        }
        guard let cached = await read({ try await $0.item(itemID, tenant: tenant) }) else { return nil }
        items[itemID] = MemoryEntry(value: cached.item, fetchedAt: cached.fetchedAt)
        return snapshot(cached.item, fetchedAt: cached.fetchedAt, source: .disk)
    }

    public func refreshItem(itemID: MediaItem.ID) async throws -> MediaItem {
        if let rust {
            let claim = try rust.claim("item", key: itemID)
            if !claim.owner {
                guard let task = itemTasks[itemID] else { throw RustMediaRepository.missingTask }
                return try await task.value
            }
            let task = Task { try await self.performItemRefresh(itemID: itemID) }
            itemTasks[itemID] = task
            defer { rust.finish(claim); itemTasks[itemID] = nil }
            return try await task.value
        }
        if let task = itemTasks[itemID] { return try await task.value }
        let task = Task { try await self.performItemRefresh(itemID: itemID) }
        itemTasks[itemID] = task
        defer { itemTasks[itemID] = nil }
        return try await task.value
    }

    private func performItemRefresh(itemID: MediaItem.ID) async throws -> MediaItem {
        if let rust {
            return try await runRepositoryFlow(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "item", now: now(), itemID: itemID))
        }
        let requestStartedAt = now()
        let remote = try await server.item(itemID)
        let item = await saveIncomingItems([remote], requestStartedAt: requestStartedAt)[0]
        rememberItems([item])
        if var detail = details[itemID]?.value {
            detail.item = item
            details[itemID] = MemoryEntry(value: detail, fetchedAt: now())
        }
        return item
    }

    public func cachedDetail(itemID: MediaItem.ID) async -> MediaSnapshot<MediaDetailContent>? {
        if let rust {
            return await cachedRepositoryValue(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "cachedDetail", now: now(), itemID: itemID, hasStore: store != nil))
        }
        if let entry = details[itemID] {
            return snapshot(entry.value, fetchedAt: entry.fetchedAt, source: .memory)
        }
        guard let cachedItem = await read({ try await $0.item(itemID, tenant: tenant) }) else { return nil }
        var seasons: [MediaItem] = []
        var episodes: [MediaItem] = []
        var episodesSeasonID: MediaItem.ID?
        var members: [MediaItem] = []
        var memberTotal: Int?
        if cachedItem.item.kind == .series, let store {
            seasons = (await read { try await $0.seasons(seriesID: itemID, tenant: tenant) }) ?? []
            if let seasonID = Self.defaultSeasonID(in: seasons) {
                episodesSeasonID = seasonID
                episodes = (await read {
                    try await $0.episodes(seriesID: itemID, seasonID: seasonID, tenant: tenant)
                }) ?? []
            }
        } else if cachedItem.item.kind == .boxSet {
            let descriptor = Self.collectionDescriptor(itemID: itemID)
            if let page = await cachedPage(descriptor, limit: Self.collectionPageLimit) {
                members = page.value.items
                memberTotal = page.value.totalCount
            }
        }
        let content = MediaDetailContent(
            item: cachedItem.item, seasons: seasons, episodesSeasonID: episodesSeasonID,
            episodes: episodes, collectionMembers: members,
            collectionMembersTotalCount: memberTotal)
        details[itemID] = MemoryEntry(value: content, fetchedAt: cachedItem.fetchedAt)
        items[itemID] = MemoryEntry(value: cachedItem.item, fetchedAt: cachedItem.fetchedAt)
        rememberItems(seasons + episodes + members)
        return snapshot(content, fetchedAt: cachedItem.fetchedAt, source: .disk)
    }

    /// 条目、季、默认季分集与合集成员的一次完整刷新。
    /// 只有条目本身失败才抛错；附属分区失败随结果返回，页面保留可用内容。
    public func refreshDetail(
        itemID: MediaItem.ID,
        kindHint: MediaItem.Kind? = nil
    ) async throws -> MediaDetailRefresh {
        if let rust {
            let claim = try rust.claim("detail", key: itemID)
            if !claim.owner {
                guard let task = detailTasks[itemID] else { throw RustMediaRepository.missingTask }
                return try await task.value
            }
            let task = Task { try await self.performDetailRefresh(itemID: itemID, kindHint: kindHint) }
            detailTasks[itemID] = task
            defer { rust.finish(claim); detailTasks[itemID] = nil }
            return try await task.value
        }
        if let task = detailTasks[itemID] { return try await task.value }
        let task = Task { try await self.performDetailRefresh(itemID: itemID, kindHint: kindHint) }
        detailTasks[itemID] = task
        defer { detailTasks[itemID] = nil }
        return try await task.value
    }

    private func performDetailRefresh(
        itemID: MediaItem.ID,
        kindHint: MediaItem.Kind?
    ) async throws -> MediaDetailRefresh {
        if let rust {
            let previous = await cachedDetail(itemID: itemID)?.value
            var start = RustMediaRepository.FlowStart(kind: "detail", now: now(), previous: previous, itemID: itemID)
            start.kindHint = kindHint
            return try await runRepositoryFlow(rust, start)
        }
        let previous = await cachedDetail(itemID: itemID)?.value
        var failures: [String: MediaFailure] = [:]
        let kind = kindHint ?? previous?.item.kind
        if kind == .series {
            let requestStartedAt = now()
            async let seasonsPart = mediaLoadPart { try await server.seasons(seriesID: itemID) }
            let item = try await refreshItem(itemID: itemID)
            let seasonsResult = await seasonsPart
            let seasons: [MediaItem]
            if let remote = seasonsResult.value {
                seasons = await saveIncomingItems(remote, requestStartedAt: requestStartedAt)
            } else { seasons = previous?.seasons ?? [] }
            failures["seasons"] = seasonsResult.failure

            let seasonID = try repositoryDefaultSeason(in: seasons)
            var episodes: [MediaItem] = []
            if let seasonID {
                let episodePart = await mediaLoadPart {
                    try await self.refreshEpisodes(seriesID: itemID, seasonID: seasonID)
                }
                episodes = episodePart.value
                    ?? (previous?.episodesSeasonID == seasonID ? previous?.episodes ?? [] : [])
                failures["episodes"] = episodePart.failure
            }
            let content = try repositoryDetail(MediaDetailContent(
                item: item, seasons: seasons, episodesSeasonID: seasonID, episodes: episodes),
                requestStartedAt: requestStartedAt)
            rememberItems(content.seasons + content.episodes)
            details[itemID] = MemoryEntry(value: content, fetchedAt: now())
            return MediaDetailRefresh(
                snapshot: snapshot(content, fetchedAt: now(), source: .network), failures: failures)
        }

        let requestStartedAt = now()
        let item = try await refreshItem(itemID: itemID)
        if item.kind == .boxSet || kind == .boxSet {
            let descriptor = Self.collectionDescriptor(itemID: itemID)
            let memberPart = await mediaLoadPart {
                try await self.refreshPage(
                    descriptor, startIndex: 0, limit: Self.collectionPageLimit)
            }
            let members = memberPart.value?.value.items ?? previous?.collectionMembers ?? []
            let memberTotal = memberPart.value?.value.totalCount
                ?? previous?.collectionMembersTotalCount
            failures["members"] = memberPart.failure
            let content = try repositoryDetail(MediaDetailContent(
                item: item, collectionMembers: members, collectionMembersTotalCount: memberTotal),
                requestStartedAt: requestStartedAt)
            details[itemID] = MemoryEntry(value: content, fetchedAt: now())
            return MediaDetailRefresh(
                snapshot: snapshot(content, fetchedAt: now(), source: .network), failures: failures)
        }

        // 列表 kind 偶发缺失时以完整详情为准补一季列表。
        if item.kind == .series {
            return try await performDetailRefresh(itemID: itemID, kindHint: .series)
        }
        let content = MediaDetailContent(item: item)
        details[itemID] = MemoryEntry(value: content, fetchedAt: now())
        return MediaDetailRefresh(
            snapshot: snapshot(content, fetchedAt: now(), source: .network), failures: failures)
    }

    /// 点击预取与进页刷新共用同一个 `refreshDetail` 单飞任务；预取失败保持静默。
    public func prefetchDetail(itemID: MediaItem.ID, kindHint: MediaItem.Kind?) async {
        if let rust {
            var start = RustMediaRepository.FlowStart<RustMediaRepository.Empty>(kind: "prefetch", now: now(), itemID: itemID)
            start.kindHint = kindHint
            let _: RustMediaRepository.Empty? = try? await runRepositoryFlow(rust, start)
            return
        }
        // 会话内已经确认过的详情直接免了；磁盘来源仍要网络确认。
        if let cached = await cachedDetail(itemID: itemID), cached.source == .memory {
            return
        }
        _ = try? await refreshDetail(itemID: itemID, kindHint: kindHint)
    }

    public func cachedEpisodes(
        seriesID: MediaItem.ID,
        seasonID: MediaItem.ID
    ) async -> MediaSnapshot<[MediaItem]>? {
        if let rust {
            return await cachedRepositoryValue(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "cachedEpisodes", now: now(), seriesID: seriesID, seasonID: seasonID))
        }
        let key = EpisodeKey(seriesID: seriesID, seasonID: seasonID)
        if let entry = episodeLists[key] {
            return snapshot(entry.value, fetchedAt: entry.fetchedAt, source: .memory)
        }
        guard let episodes = await read({
            try await $0.episodes(seriesID: seriesID, seasonID: seasonID, tenant: tenant)
        }), !episodes.isEmpty else { return nil }
        let fetchedAt = now()
        episodeLists[key] = MemoryEntry(value: episodes, fetchedAt: fetchedAt)
        rememberItems(episodes)
        return snapshot(episodes, fetchedAt: fetchedAt, source: .disk)
    }

    public func refreshEpisodes(
        seriesID: MediaItem.ID,
        seasonID: MediaItem.ID
    ) async throws -> [MediaItem] {
        let key = EpisodeKey(seriesID: seriesID, seasonID: seasonID)
        if let rust {
            let claim = try rust.claim("episodes", key: key)
            if !claim.owner {
                guard let task = episodeTasks[key] else { throw RustMediaRepository.missingTask }
                return try await task.value
            }
            let task = Task { try await self.performEpisodeRefresh(key: key) }
            episodeTasks[key] = task
            defer { rust.finish(claim); episodeTasks[key] = nil }
            return try await task.value
        }
        if let task = episodeTasks[key] { return try await task.value }
        let task = Task { try await self.performEpisodeRefresh(key: key) }
        episodeTasks[key] = task
        defer { episodeTasks[key] = nil }
        return try await task.value
    }

    private func performEpisodeRefresh(key: EpisodeKey) async throws -> [MediaItem] {
        if let rust {
            return try await runRepositoryFlow(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "episodes", now: now(), seriesID: key.seriesID, seasonID: key.seasonID))
        }
        let requestStartedAt = now()
        let remote = try await server.episodes(seriesID: key.seriesID, seasonID: key.seasonID)
        let episodes = await saveIncomingItems(remote, requestStartedAt: requestStartedAt)
        episodeLists[key] = MemoryEntry(value: episodes, fetchedAt: now())
        rememberItems(episodes)
        if var detail = details[key.seriesID]?.value, detail.episodesSeasonID == key.seasonID {
            detail.episodes = episodes
            details[key.seriesID] = MemoryEntry(value: detail, fetchedAt: now())
        }
        return episodes
    }

    /// 推荐每次由服务端决定，且不是首屏关键路径；保持直取但不绕过仓储协议。
    public func similar(itemID: MediaItem.ID, limit: Int) async throws -> [MediaItem] {
        try await server.similar(itemID: itemID, limit: limit)
    }

    public func cachedCollectionMembers(
        itemID: MediaItem.ID
    ) async -> MediaSnapshot<MediaPageContent>? {
        if let rust {
            do {
                let descriptor: MediaPageDescriptor = try rust.flow("collectionDescriptor", RustMediaRepository.FlowStart<RustMediaRepository.Empty>(kind: "page", now: now(), itemID: itemID))
                return await cachedPage(descriptor, limit: Self.collectionPageLimit)
            } catch { RustMediaRepository.report(error); return nil }
        }
        return await cachedPage(Self.collectionDescriptor(itemID: itemID), limit: Self.collectionPageLimit)
    }

    public func refreshCollectionMembers(
        itemID: MediaItem.ID,
        startIndex: Int = 0
    ) async throws -> MediaSnapshot<MediaPageContent> {
        let descriptor: MediaPageDescriptor
        if let rust { descriptor = try rust.flow("collectionDescriptor", RustMediaRepository.FlowStart<RustMediaRepository.Empty>(kind: "page", now: now(), itemID: itemID)) }
        else { descriptor = Self.collectionDescriptor(itemID: itemID) }
        return try await refreshPage(descriptor, startIndex: startIndex, limit: Self.collectionPageLimit)
    }

    static var collectionPageLimit: Int { 200 }

    static func collectionDescriptor(itemID: MediaItem.ID) -> MediaPageDescriptor {
        MediaPageDescriptor(
            parentID: itemID, kinds: nil, recursive: false,
            sort: MediaItemsSort(field: .year, ascending: true),
            watchState: nil, searchTerm: nil)
    }

    static func defaultSeasonID(in seasons: [MediaItem]) -> MediaItem.ID? {
        seasons.first { $0.seasonNumber != 0 }?.id ?? seasons.first?.id
    }
}
