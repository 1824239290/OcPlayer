import CoreModel
import Foundation

extension MediaRepository {
    /// 某个查询已恢复的全部连续页。内存优先，其次一次读事务取回所有页。
    public func cachedPage(
        _ descriptor: MediaPageDescriptor,
        limit: Int
    ) async -> MediaSnapshot<MediaPageContent>? {
        if let rust {
            return await cachedRepositoryValue(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "cachedPage", now: now(), descriptor: descriptor, startIndex: 0, limit: limit))
        }
        if let entry = pages[descriptor] {
            return snapshot(entry.value, fetchedAt: entry.fetchedAt, source: .memory)
        }
        guard let rows = await read({ store in
            try await store.pages(matching: descriptor.query, tenant: tenant)
        }), !rows.isEmpty else { return nil }

        let content = Self.merge(rows: rows)
        guard !content.items.isEmpty else { return nil }
        let fetchedAt = rows.map(\.fetchedAt).min() ?? now()
        pages[descriptor] = MemoryEntry(value: content, fetchedAt: fetchedAt)
        rememberItems(content.items)
        return snapshot(content, fetchedAt: fetchedAt, source: .disk)
    }

    /// 拉取一页并合并进该查询的累计结果。
    ///
    /// 同一个 `(descriptor, startIndex, limit)` 并发调用共享一次网络请求；
    /// 不同窗口各自请求，但都写回同一份内存累计与 SQLite 页表。
    public func refreshPage(
        _ descriptor: MediaPageDescriptor,
        startIndex: Int,
        limit: Int
    ) async throws -> MediaSnapshot<MediaPageContent> {
        let key: PageKey
        if let rust {
            key = try rust.flow("pageKey", RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "page", now: now(), descriptor: descriptor, startIndex: startIndex, limit: limit))
        } else { key = descriptor.key(startIndex: startIndex, limit: limit) }
        if let rust {
            let claim = try rust.claim("page", key: key)
            if !claim.owner {
                guard let task = pageTasks[key] else { throw RustMediaRepository.missingTask }
                return try await task.value
            }
            let task = Task { try await self.performPageRefresh(descriptor, key: key, startIndex: startIndex, limit: limit) }
            pageTasks[key] = task
            defer { rust.finish(claim); pageTasks[key] = nil }
            return try await task.value
        }
        if let task = pageTasks[key] { return try await task.value }
        let task = Task {
            try await self.performPageRefresh(
                descriptor, key: key, startIndex: startIndex, limit: limit)
        }
        pageTasks[key] = task
        defer { pageTasks[key] = nil }
        return try await task.value
    }

    private func performPageRefresh(
        _ descriptor: MediaPageDescriptor,
        key: PageKey,
        startIndex: Int,
        limit: Int
    ) async throws -> MediaSnapshot<MediaPageContent> {
        if let rust {
            return try await runRepositoryFlow(rust, RustMediaRepository.FlowStart<RustMediaRepository.Empty>(
                kind: "page", now: now(), descriptor: descriptor, key: key, startIndex: startIndex, limit: limit))
        }
        let requestStartedAt = now()
        var page = try await server.itemsPage(
            parentID: descriptor.parentID,
            kinds: descriptor.kinds,
            recursive: descriptor.recursive,
            startIndex: startIndex,
            limit: limit,
            sort: descriptor.sort,
            watchState: descriptor.watchState,
            searchTerm: descriptor.searchTerm)

        page.items = await saveIncomingItems(page.items, requestStartedAt: requestStartedAt)
        var content: MediaPageContent
        if startIndex == 0 {
            content = MediaPageContent(
                items: page.items,
                totalCount: page.totalRecordCount,
                nextStartIndex: page.items.count,
                lastPageWasFull: page.items.count >= limit)
        } else {
            let previous: MediaPageContent
            if let entry = pages[descriptor] {
                previous = entry.value
            } else if let cached = await cachedPage(descriptor, limit: limit) {
                previous = cached.value
            } else {
                previous = MediaPageContent()
            }
            var ids = Set(previous.items.map(\.id))
            var items = previous.items
            items.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
            content = MediaPageContent(
                items: items,
                totalCount: page.totalRecordCount ?? previous.totalCount,
                nextStartIndex: max(previous.nextStartIndex, startIndex + page.items.count),
                lastPageWasFull: page.items.count >= limit)
        }

        content.items = mergingLocalProgress(content.items, requestStartedAt: requestStartedAt)
        pages[descriptor] = MemoryEntry(value: content, fetchedAt: now())
        rememberItems(page.items)
        let persistedPage = page
        await persist { try await $0.savePage(persistedPage, key: key, tenant: tenant) }
        content.items = mergingLocalProgress(content.items, requestStartedAt: requestStartedAt)
        pages[descriptor] = MemoryEntry(value: content, fetchedAt: now())
        return snapshot(content, fetchedAt: now(), source: .network)
    }

    /// SQLite 页表 → 一个从 0 开始连续的结果。出现空洞即停，避免把错序页拼上去。
    static func merge(rows: [CachedPage]) -> MediaPageContent {
        var items: [MediaItem] = []
        var ids = Set<MediaItem.ID>()
        var nextStart = 0
        var total: Int?
        var lastWasFull = false
        for row in rows.sorted(by: { $0.startIndex < $1.startIndex }) {
            guard row.startIndex == nextStart else { break }
            for item in row.items where ids.insert(item.id).inserted {
                items.append(item)
            }
            nextStart = row.startIndex + row.items.count
            total = row.totalRecordCount
            lastWasFull = row.limit > 0 && row.items.count >= row.limit
        }
        return MediaPageContent(
            items: items, totalCount: total,
            nextStartIndex: nextStart, lastPageWasFull: lastWasFull)
    }
}
