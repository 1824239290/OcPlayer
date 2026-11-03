import CoreModel
import Foundation

extension MediaRepository {
    /// 首页与库列表：内存命中零 I/O，否则一次读事务恢复库列表与三条 rail。
    public func cachedHome() async -> MediaSnapshot<MediaHomeContent>? {
        if let entry = homeEntry {
            return snapshot(entry.value, fetchedAt: entry.fetchedAt, source: .memory)
        }
        guard let parts = await read({ try await $0.homeSnapshotParts(tenant: tenant) }) else {
            return nil
        }
        let content = MediaHomeContent(
            libraries: parts.libraries.map(\.library),
            resume: parts.rails["resume"]?.items ?? [],
            nextUp: deduplicatedNextUp(
                parts.rails["nextUp"]?.items ?? [],
                resume: parts.rails["resume"]?.items ?? []),
            latest: parts.rails["latest"]?.items ?? [])
        guard !content.isEmpty else { return nil }
        let dates = ["resume", "nextUp", "latest"].compactMap { parts.rails[$0]?.fetchedAt }
        let fetchedAt = dates.min() ?? parts.libraries.map(\.fetchedAt).min() ?? now()
        homeEntry = MemoryEntry(value: content, fetchedAt: fetchedAt)
        rememberItems(content.resume + content.nextUp + content.latest)
        return snapshot(content, fetchedAt: fetchedAt, source: .disk)
    }

    /// 四个分区并行刷新，同一时刻只存在一轮首页请求。
    /// 成功分区写穿 SQLite；失败分区沿用缓存，不让一条 rail 的错误清空整页。
    public func refreshHome() async -> MediaHomeRefresh {
        if let homeTask { return await homeTask.value }
        let task = Task { await self.performHomeRefresh() }
        homeTask = task
        defer { homeTask = nil }
        return await task.value
    }

    private func performHomeRefresh() async -> MediaHomeRefresh {
        let previous = await cachedHome()
        async let libraries = mediaLoadPart { try await server.userViews() }
        async let resume = mediaLoadPart { try await server.resumeItems() }
        async let nextUp = mediaLoadPart { try await server.nextUp() }
        async let latest = mediaLoadPart { try await server.latestItems(limit: 24) }
        let (libraryPart, resumePart, nextUpPart, latestPart) = await (libraries, resume, nextUp, latest)

        var content = previous?.value ?? MediaHomeContent()
        var failures: [String: MediaFailure] = [:]
        if let value = libraryPart.value {
            content.libraries = value
            await persist { try await $0.saveLibraries(value, tenant: tenant) }
        }
        failures["libraries"] = libraryPart.failure

        if let value = resumePart.value {
            content.resume = value
            await persist { try await $0.saveItemsAndRail(value, rail: "resume", tenant: tenant) }
        }
        failures["resume"] = resumePart.failure

        if let value = nextUpPart.value {
            content.nextUp = deduplicatedNextUp(value, resume: content.resume)
            await persist { try await $0.saveItemsAndRail(value, rail: "nextUp", tenant: tenant) }
        }
        failures["nextUp"] = nextUpPart.failure

        if let value = latestPart.value {
            content.latest = value
            await persist { try await $0.saveItemsAndRail(value, rail: "latest", tenant: tenant) }
        }
        failures["latest"] = latestPart.failure

        let anySuccess = [libraryPart.value != nil, resumePart.value != nil,
                          nextUpPart.value != nil, latestPart.value != nil].contains(true)
        let fetchedAt = anySuccess ? now() : (previous?.fetchedAt ?? now())
        homeEntry = MemoryEntry(value: content, fetchedAt: fetchedAt)
        rememberItems(content.resume + content.nextUp + content.latest)
        let source: MediaDataSource = anySuccess ? .network : (previous?.source ?? .network)
        return MediaHomeRefresh(
            snapshot: snapshot(content, fetchedAt: fetchedAt, source: source),
            failures: failures)
    }
}
