import CoreModel
import Foundation
import JellyfinKit
import OcPlayerCore

extension RustMediaRepository {
    struct FlowStart<Previous: Encodable>: Encodable {
        var kind: String
        var now: Date
        var previous: Previous? = nil
        var kindHint: MediaItem.Kind? = nil
        var itemID: String? = nil
        var seriesID: String? = nil
        var seasonID: String? = nil
        var descriptor: MediaPageDescriptor? = nil
        var key: PageKey? = nil
        var startIndex: Int? = nil
        var limit: Int? = nil
        var hasStore: Bool? = nil
    }
    struct Empty: Codable {}
    struct WirePage: Codable {
        var items: [MediaItem]
        var startIndex: Int
        var totalRecordCount: Int?
        init(_ page: MediaItemsPage) {
            items = page.items; startIndex = page.startIndex; totalRecordCount = page.totalRecordCount
        }
        var native: MediaItemsPage { .init(items: items, startIndex: startIndex, totalRecordCount: totalRecordCount) }
    }
    struct CachedItemWire: Encodable {
        var item: MediaItem
        var fetchedAt: Date
        init(_ item: CachedItem) { self.item = item.item; fetchedAt = item.fetchedAt }
    }
    struct CachedPageWire: Encodable {
        var items: [MediaItem]
        var totalRecordCount: Int?
        var fetchedAt: Date
        var startIndex: Int
        var limit: Int
        init(_ page: CachedPage) {
            items = page.items; totalRecordCount = page.totalRecordCount
            fetchedAt = page.fetchedAt; startIndex = page.startIndex; limit = page.limit
        }
    }
    struct Part<Value: Sendable & Encodable>: Encodable {
        var value: Value?
        var failure: MediaFailure?
        init(_ part: MediaLoadPart<Value>) { value = part.value; failure = part.failure }
    }
    struct HomeParts: Encodable {
        var libraries: Part<[MediaLibrary]>
        var resume: Part<[MediaItem]>
        var nextUp: Part<[MediaItem]>
        var latest: Part<[MediaItem]>
    }
    struct SeriesParts: Encodable { var item: MediaItem; var seasons: Part<[MediaItem]> }
    struct FlowArguments: Decodable {
        var itemID: String?
        var kindHint: MediaItem.Kind?
        var seriesID: String?
        var seasonID: String?
        var items: [MediaItem]?
        var libraries: [MediaLibrary]?
        var rail: String?
        var requestStartedAt: Date?
        var descriptor: MediaPageDescriptor?
        var key: PageKey?
        var startIndex: Int?
        var limit: Int?
        var home: MediaHomeRefresh?
        var detail: MediaDetailContent?
        var page: WirePage?
        var pageContent: MediaPageContent?
        var homeSnapshot: MediaSnapshot<MediaHomeContent>?
        var itemSnapshot: MediaSnapshot<MediaItem>?
        var detailSnapshot: MediaSnapshot<MediaDetailContent>?
        var pageSnapshot: MediaSnapshot<MediaPageContent>?
        var episodeSnapshot: MediaSnapshot<[MediaItem]>?
    }
    struct FlowStep<Output: Decodable>: Decodable {
        var token: UInt64
        var sequence: UInt64
        var done: Bool
        var effect: String?
        var arguments: FlowArguments?
        var result: Output?
        enum CodingKeys: String, CodingKey { case token, sequence, done, effect, arguments, result }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(UInt64.self, forKey: .token)
            sequence = try c.decode(UInt64.self, forKey: .sequence)
            done = try c.decode(Bool.self, forKey: .done)
            effect = try c.decodeIfPresent(String.self, forKey: .effect)
            arguments = try c.decodeIfPresent(FlowArguments.self, forKey: .arguments)
            result = done ? .some(try c.decode(Output.self, forKey: .result)) : nil
        }
    }
    struct FlowResume: Encodable {
        var token: UInt64
        var sequence: UInt64
        var now: Date
        var responseJSON: String
    }
    struct FlowCancel: Encodable { var token: UInt64 }
    func flow<Input: Encodable, Output: Decodable>(
        _ method: String, _ input: Input, as: Output.Type = Output.self
    ) throws -> Output {
        try decode("flow." + method, ["payloadJSON": Self.flowJSON(input)])
    }
    static func flowJSON<Input: Encodable>(_ value: Input) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func cancelFlow(_ token: UInt64) {
        do { let _: [String: Bool] = try flow("cancel", FlowCancel(token: token)) }
        catch { Self.report(error) }
    }
    static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw OcpCoreError(message: "Missing repository effect argument") }
        return value
    }
}

extension MediaRepository {
    func runRepositoryFlow<Input: Encodable, Output: Decodable>(
        _ rust: RustMediaRepository, _ start: Input, as: Output.Type = Output.self
    ) async throws -> Output {
        var step: RustMediaRepository.FlowStep<Output> = try rust.flow("start", start)
        defer { rust.cancelFlow(step.token) }
        while !step.done {
            let effect = try RustMediaRepository.required(step.effect)
            let args = try RustMediaRepository.required(step.arguments)
            let response = try await executeRepositoryEffect(effect, args)
            step = try rust.flow("resume", RustMediaRepository.FlowResume(
                token: step.token, sequence: step.sequence, now: now(), responseJSON: response))
        }
        return try RustMediaRepository.required(step.result)
    }
    private func executeRepositoryEffect(
        _ effect: String, _ args: RustMediaRepository.FlowArguments
    ) async throws -> String {
        typealias R = RustMediaRepository
        switch effect {
        case "readCachedHome":
            let parts = await read { try await $0.homeSnapshotParts(tenant: tenant) }
            let wire = parts.map { parts in R.DiskHome(
                content: .init(libraries: parts.libraries.map(\.library),
                    resume: parts.rails["resume"]?.items ?? [], nextUp: parts.rails["nextUp"]?.items ?? [],
                    latest: parts.rails["latest"]?.items ?? []),
                railDates: ["resume", "nextUp", "latest"].compactMap { parts.rails[$0]?.fetchedAt },
                libraryDates: parts.libraries.map(\.fetchedAt), now: now()) }
            return try R.flowJSON(wire)
        case "readCachedItem":
            let itemID = try R.required(args.itemID)
            let item = await read { try await $0.item(itemID, tenant: tenant) }
            return try R.flowJSON(item.map(R.CachedItemWire.init))
        case "readCachedSeasons":
            let seriesID = try R.required(args.seriesID)
            return try R.flowJSON(await read { try await $0.seasons(seriesID: seriesID, tenant: tenant) })
        case "readCachedEpisodes", "readDetailCachedEpisodes":
            let seriesID = try R.required(args.seriesID), seasonID = try R.required(args.seasonID)
            return try R.flowJSON(await read { try await $0.episodes(seriesID: seriesID, seasonID: seasonID, tenant: tenant) })
        case "readCachedMembers":
            return try R.flowJSON(await cachedPage(R.required(args.descriptor), limit: R.required(args.limit)))
        case "readCachedPages":
            let key = try R.required(args.key)
            var query = PageQuery(parentID: nil, kinds: nil, sort: nil, watchState: nil, searchTerm: nil)
            query.parentID = key.parentID; query.kinds = key.kinds; query.sortKey = key.sortKey
            query.watchState = key.watchState; query.searchTerm = key.searchTerm
            let matchingQuery = query
            let rows = await read { try await $0.pages(matching: matchingQuery, tenant: tenant) }
            return try R.flowJSON(rows?.map(R.CachedPageWire.init))
        case "commitCachedHome":
            let value = try R.required(args.homeSnapshot)
            homeEntry = .init(value: value.value, fetchedAt: value.fetchedAt)
            rememberItems(try R.required(args.items))
        case "commitCachedItem":
            let value = try R.required(args.itemSnapshot)
            items[try R.required(args.itemID)] = .init(value: value.value, fetchedAt: value.fetchedAt)
        case "commitCachedDetail":
            let value = try R.required(args.detailSnapshot), itemID = try R.required(args.itemID)
            details[itemID] = .init(value: value.value, fetchedAt: value.fetchedAt)
            items[itemID] = .init(value: value.value.item, fetchedAt: value.fetchedAt)
            rememberItems(try R.required(args.items))
        case "commitCachedPage":
            let value = try R.required(args.pageSnapshot)
            pages[try R.required(args.descriptor)] = .init(value: value.value, fetchedAt: value.fetchedAt)
            rememberItems(try R.required(args.items))
        case "commitCachedEpisodes":
            let value = try R.required(args.episodeSnapshot)
            let key = EpisodeKey(seriesID: try R.required(args.seriesID), seasonID: try R.required(args.seasonID))
            episodeLists[key] = .init(value: value.value, fetchedAt: value.fetchedAt)
            rememberItems(try R.required(args.items))
        case "loadPrefetchCache":
            return try R.flowJSON(await cachedDetail(itemID: R.required(args.itemID)))
        case "loadPrefetchDetail":
            _ = try? await refreshDetail(itemID: R.required(args.itemID), kindHint: args.kindHint)
        case "loadHome":
            let limit = try R.required(args.limit)
            async let libraries = mediaLoadPart { try await server.userViews() }
            async let resume = mediaLoadPart { try await server.resumeItems() }
            async let nextUp = mediaLoadPart { try await server.nextUp() }
            async let latest = mediaLoadPart { try await server.latestItems(limit: limit) }
            let parts = await (libraries, resume, nextUp, latest)
            return try R.flowJSON(R.HomeParts(libraries: .init(parts.0), resume: .init(parts.1),
                nextUp: .init(parts.2), latest: .init(parts.3)))
        case "saveLibraries":
            let values = try R.required(args.libraries)
            await persist { try await $0.saveLibraries(values, tenant: tenant) }
        case "saveHome_resume", "saveHome_nextUp", "saveHome_latest", "saveSeasons",
             "savePageItems", "saveItem", "saveEpisodes":
            return try R.flowJSON(await saveIncomingItems(
                try R.required(args.items), rail: args.rail,
                requestStartedAt: try R.required(args.requestStartedAt)))
        case "commitHome":
            let result = try R.required(args.home)
            homeEntry = .init(value: result.snapshot.value, fetchedAt: result.snapshot.fetchedAt)
            rememberItems(result.snapshot.value.resume + result.snapshot.value.nextUp + result.snapshot.value.latest)
        case "loadSeries":
            let itemID = try R.required(args.itemID)
            async let seasons = mediaLoadPart { try await server.seasons(seriesID: itemID) }
            let item = try await refreshItem(itemID: itemID)
            return try R.flowJSON(R.SeriesParts(item: item, seasons: .init(await seasons)))
        case "loadDetailItem":
            return try R.flowJSON(try await refreshItem(itemID: R.required(args.itemID)))
        case "loadDetailEpisodes":
            let seriesID = try R.required(args.seriesID), seasonID = try R.required(args.seasonID)
            let part = await mediaLoadPart { try await self.refreshEpisodes(seriesID: seriesID, seasonID: seasonID) }
            return try R.flowJSON(R.Part(part))
        case "loadMembers":
            let descriptor = try R.required(args.descriptor)
            let startIndex = try R.required(args.startIndex), limit = try R.required(args.limit)
            let part = await mediaLoadPart { try await self.refreshPage(descriptor, startIndex: startIndex, limit: limit) }
            return try R.flowJSON(R.Part(part))
        case "reloadDetail":
            return try R.flowJSON(await cachedDetail(itemID: R.required(args.itemID))?.value)
        case "commitDetail":
            rememberItems(try R.required(args.items))
            details[try R.required(args.itemID)] = .init(value: try R.required(args.detail), fetchedAt: now())
        case "fetchPage":
            let descriptor = try R.required(args.descriptor)
            let page = try await server.itemsPage(parentID: descriptor.parentID, kinds: descriptor.kinds,
                recursive: descriptor.recursive, startIndex: R.required(args.startIndex),
                limit: R.required(args.limit), sort: descriptor.sort,
                watchState: descriptor.watchState, searchTerm: descriptor.searchTerm)
            return try R.flowJSON(R.WirePage(page))
        case "readPreviousPage":
            let descriptor = try R.required(args.descriptor)
            if let entry = pages[descriptor] { return try R.flowJSON(entry.value) }
            return try R.flowJSON(await cachedPage(descriptor, limit: R.required(args.limit))?.value)
        case "publishPage":
            pages[try R.required(args.descriptor)] = .init(value: try R.required(args.pageContent), fetchedAt: now())
            rememberItems(try R.required(args.items))
        case "savePage":
            let page = try R.required(args.page).native, key = try R.required(args.key)
            await persist { try await $0.savePage(page, key: key, tenant: tenant) }
        case "commitPage":
            pages[try R.required(args.descriptor)] = .init(value: try R.required(args.pageContent), fetchedAt: now())
        case "fetchItem":
            return try R.flowJSON(try await server.item(R.required(args.itemID)))
        case "rememberItem":
            rememberItems(try R.required(args.items))
        case "commitItemDetail", "commitEpisodeDetail":
            details[try R.required(args.itemID)] = .init(value: try R.required(args.detail), fetchedAt: now())
        case "fetchEpisodes":
            return try R.flowJSON(try await server.episodes(seriesID: R.required(args.seriesID), seasonID: R.required(args.seasonID)))
        case "publishEpisodes":
            let key = EpisodeKey(seriesID: try R.required(args.seriesID), seasonID: try R.required(args.seasonID))
            let values = try R.required(args.items)
            episodeLists[key] = .init(value: values, fetchedAt: now())
            rememberItems(values)
        default:
            throw OcpCoreError(message: "Unknown repository effect: \(effect)")
        }
        return try R.flowJSON(R.Empty())
    }
    func cachedRepositoryValue<Input: Encodable, Value: Sendable & Codable>(
        _ rust: RustMediaRepository, _ start: Input, as: Value.Type = Value.self
    ) async -> MediaSnapshot<Value>? {
        do { return try await runRepositoryFlow(rust, start, as: MediaSnapshot<Value>?.self) }
        catch { RustMediaRepository.report(error); return nil }
    }
    func performSharedHomeRefresh(_ rust: RustMediaRepository) async -> MediaHomeRefresh {
        let previous = await cachedHome()
        do {
            return try await runRepositoryFlow(rust, RustMediaRepository.FlowStart(
                kind: "home", now: now(), previous: previous))
        } catch {
            RustMediaRepository.report(error)
            return MediaHomeRefresh(snapshot: previous ?? snapshot(MediaHomeContent(), fetchedAt: now(), source: .network),
                failures: ["repository": MediaFailure(error)])
        }
    }
}
